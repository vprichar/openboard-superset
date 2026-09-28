import AppKit
import Foundation
import OpenBoardKit

/**
 Hold a key down — space for dictation, or any recorded chord — with the safety the
 raw key events do not have.

 ## Why this is its own type

 `keyDown` without a matching `keyUp` is **OS-level state that outlives this process**.
 Miss the release — a dropped HID report, a crash, a quit mid-hold, the pad going out
 of Bluetooth range — and space is logically held down across the entire machine. Every
 keystroke afterwards carries it, and nothing on screen explains why. The user's next
 move is to reboot.

 So the hold is never trusted to end on its own:

 - a **timer** releases it after `maxHoldSeconds` whether or not the release arrives
 - **quitting** releases it, so a crash-adjacent path still cleans up
 - a second `down` while already held is **not** a second hold

 A dictation hold also **repeats**, as a physical key does: Claude Code's hold mode
 reads a held Space from its autorepeat stream, not from key-up (see `HoldRepeat`).
 The repeats stop before every key-up — release, timeout or quit — and never outlive
 the hold.

 The Node version documented this danger and then shipped tap-only, which is the safe
 default and also the reason `voiceTalk` silently behaved like `voiceTap` — a binding
 the picker offered and did not honour.
 */
@MainActor
final class PushToTalk {
    private let log: (String) -> Void
    private var releaseTask: Task<Void, Never>?
    /// What is down, and which pad key put it there. Only that key's release ends it;
    /// otherwise any other key's release would end the dictation.
    private var holding: Shortcut?
    private(set) var heldBy: String?
    /// Whether the current hold is dictation, as opposed to a custom chord. Declared
    /// by the caller at `begin` — inferring it from `heldBy` breaks for the long-press
    /// keys, whose name ("ENC.long") is not the key the actions map knows ("ENC").
    private(set) var isDictation = false
    var isHeld: Bool { holding != nil }
    private var heldSince: Date?
    /// Posts the dictation hold's autorepeats. Cancelled before every key-up.
    private var repeatTask: Task<Void, Never>?
    private var repeatsSent = 0

    /// The backstop. Long enough not to cut off real dictation, short enough that a
    /// missed release is an annoyance rather than a mystery.
    var maxHoldSeconds: Int = 60

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Begin a hold. Idempotent: a repeat `down` extends nothing and starts nothing.
    ///
    /// Dictation holds the key Claude Code has bound to `voice:pushToTalk` — Space by
    /// default, ⌃Y once the voice chord is installed — read afresh on every press so a
    /// changed binding needs no restart. `shortcut` is used as given otherwise.
    func begin(_ shortcut: Shortcut = .space, key: String, dictation: Bool = false) {
        guard !isHeld else {
            log("hold: already held, ignoring a second press")
            return
        }
        let shortcut = dictation ? ClaudeVoiceKey.current() : shortcut
        let result = Actions.hold(shortcut, down: true)
        guard result.ok else {
            log("hold: could not press \(shortcut.label) — \(result.detail)")
            return
        }
        holding = shortcut
        heldBy = key
        isDictation = dictation
        heldSince = Date()
        log("hold: \(shortcut.label) down\(dictation ? " (Claude push-to-talk)" : "")")
        if dictation { startRepeating(shortcut) }

        releaseTask?.cancel()
        releaseTask = Task { [weak self, maxHoldSeconds] in
            try? await Task.sleep(for: .seconds(maxHoldSeconds))
            guard !Task.isCancelled else { return }
            guard let self, self.isHeld else { return }
            // The release never came. Say so loudly: a hold that ends by timeout means
            // an event was lost, and the user needs to know their key is unreliable
            // rather than discovering it through corrupted typing later.
            self.log("hold: NO RELEASE after \(maxHoldSeconds)s — releasing anyway")
            self.end(reason: "timeout")
        }
    }

    /// End a hold. Safe to call when nothing is held.
    func end(reason: String = "released") {
        releaseTask?.cancel()
        releaseTask = nil
        // Before the key-up, always: a repeat after it would press the key again.
        stopRepeating()
        guard let shortcut = holding else { return }
        holding = nil
        heldBy = nil
        isDictation = false

        let result = Actions.hold(shortcut, down: false)
        let duration = heldSince.map { Date().timeIntervalSince($0) } ?? 0
        heldSince = nil
        let repeats = repeatsSent
        repeatsSent = 0
        log(result.ok
            ? String(format: "hold: %@ up after %.1fs (%@), %d repeats", shortcut.label, duration, reason, repeats)
            : "hold: COULD NOT RELEASE \(shortcut.label) — \(result.detail)")
    }

    /// Repeat the held key on the system's own schedule until `stopRepeating`. The
    /// task runs on the main actor, as `end` does, so once `end` has cancelled it no
    /// repeat can land between the cancel and the key-up.
    private func startRepeating(_ shortcut: Shortcut) {
        stopRepeating()
        let initial = HoldRepeat(
            delay: NSEvent.keyRepeatDelay,
            interval: NSEvent.keyRepeatInterval,
            cap: TimeInterval(maxHoldSeconds)
        )
        let clock = ContinuousClock()
        let start = clock.now
        repeatTask = Task { [weak self] in
            var schedule = initial
            while let due = schedule.nextDue {
                try? await Task.sleep(until: start + .seconds(due), clock: clock)
                guard !Task.isCancelled, let self, self.holding == shortcut else { return }
                let elapsed = start.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                guard schedule.fire(at: seconds) else {
                    // Past the cap the backstop is releasing: stop, never spin.
                    if seconds >= schedule.cap { return }
                    continue
                }
                let result = Actions.hold(shortcut, down: true, autorepeat: true)
                guard result.ok else {
                    self.log("hold: repeat failed — \(result.detail)")
                    return
                }
                self.repeatsSent += 1
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    /// Called on quit. The whole point of the type.
    func releaseIfHeld() {
        guard isHeld else { return }
        end(reason: "app quitting")
    }
}
