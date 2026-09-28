import Foundation
import OpenBoardKit

/**
 The belief, corroborated — and dark until it is.

 `VoiceSignal` is where a keypress belief meets the microphone's actual running
 state, and the mic is the half that paints: a tap alone never lights the ring,
 because a tap with text in the chat input types a space and starts nothing. The
 clock is injected throughout, so the cases that used to need a stopwatch — grace
 expiry, the 180-second backstop — are plain assertions.
 */
func runVoiceSignalTests() {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    test("a fresh belief is dark — a request is not a recording") {
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.isActive(now: t0), false)
        expect(signal.isAwaitingMic(now: t0))
    }

    test("the mic starting is what lights it") {
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.micChanged(running: true, now: t0.addingTimeInterval(1)), "mic started")
        expect(signal.isActive(now: t0.addingTimeInterval(1)))
        expect(signal.isActive(now: t0.addingTimeInterval(60)))
    }

    test("no mic within grace and the belief is judged a typed space") {
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.isAwaitingMic(now: t0.addingTimeInterval(3)), false)
        expectEqual(signal.isActive(now: t0.addingTimeInterval(3)), false)
    }

    test("a mic stop ends a confirmed belief, whoever stopped it") {
        // Second tap, Escape, submit — none of them report back, all of them stop
        // the mic.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        _ = signal.micChanged(running: true, now: t0.addingTimeInterval(1))
        expectEqual(signal.micChanged(running: false, now: t0.addingTimeInterval(30)), "mic stopped")
        expectEqual(signal.isActive(now: t0.addingTimeInterval(30)), false)
    }

    test("a mic stop before confirmation is someone else's, and ignored") {
        // Another app releasing the mic during our grace window says nothing about
        // dictation — the window stays open for the real start.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.micChanged(running: false, now: t0.addingTimeInterval(1)), nil)
        expect(signal.isAwaitingMic(now: t0.addingTimeInterval(2)))
        expectEqual(signal.micChanged(running: true, now: t0.addingTimeInterval(2)), "mic started")
        expect(signal.isActive(now: t0.addingTimeInterval(2)))
    }

    test("a mic start after grace expiry does not light a dead tap") {
        // A call starting minutes after a failed tap must not light the ring.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.micChanged(running: true, now: t0.addingTimeInterval(30)), nil)
        expectEqual(signal.micConfirmed, false)
        expectEqual(signal.isActive(now: t0.addingTimeInterval(30)), false)
    }

    test("the limit still bounds a confirmed belief") {
        // The degraded case: a call holds the mic open past dictation's end, so a
        // stop is never observed. The old absolute backstop applies unchanged.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        _ = signal.micChanged(running: true, now: t0.addingTimeInterval(1))
        expect(signal.isActive(now: t0.addingTimeInterval(179)))
        expectEqual(signal.isActive(now: t0.addingTimeInterval(180)), false)
    }

    test("mic events with no belief say nothing") {
        var signal = VoiceSignal()
        expectEqual(signal.micChanged(running: true, now: t0), nil)
        expectEqual(signal.micChanged(running: false, now: t0), nil)
        expectEqual(signal.isActive(now: t0), false)
        expectEqual(signal.isAwaitingMic(now: t0), false)
    }

    test("a new belief starts unconfirmed, whatever the last one saw") {
        var signal = VoiceSignal()
        signal.begin(now: t0)
        _ = signal.micChanged(running: true, now: t0.addingTimeInterval(1))
        signal.end()
        signal.begin(now: t0.addingTimeInterval(10))
        expectEqual(signal.micConfirmed, false)
        expectEqual(signal.isActive(now: t0.addingTimeInterval(10)), false)
        expect(signal.isAwaitingMic(now: t0.addingTimeInterval(10)))
    }

    // MARK: - HoldRepeat: the autorepeat a held pad key must fake

    /// Drive a schedule the way `PushToTalk` does: wake at each due repeat, fire it,
    /// and stop at the release. Returns the offsets that actually fired.
    func drive(_ schedule: HoldRepeat, releasedAt release: TimeInterval) -> [TimeInterval] {
        var schedule = schedule
        var fired: [TimeInterval] = []
        while let due = schedule.nextDue, due < release {
            guard schedule.fire(at: due) else { break }
            fired.append(due)
        }
        schedule.stop()
        return fired
    }

    test("hold repeat: the first repeat waits the delay, then one per interval") {
        // Claude Code's hold mode starts only after five spaces less than 120 ms
        // apart — the rhythm of a held key's autorepeat, which a synthetic keyDown
        // never produces on its own.
        let schedule = HoldRepeat(delay: 0.5, interval: 0.0625, cap: 60)
        expectEqual(drive(schedule, releasedAt: 0.7), [0.5, 0.5625, 0.625, 0.6875])
        var early = schedule
        expectEqual(early.fire(at: 0.49), false)
    }

    test("hold repeat: nothing fires after the release") {
        var schedule = HoldRepeat(delay: 0.5, interval: 0.0625, cap: 60)
        expect(schedule.fire(at: 0.5))
        schedule.stop()
        expectEqual(schedule.nextDue, nil)
        expectEqual(schedule.fire(at: 0.625), false)
        expectEqual(schedule.fire(at: 30), false)
    }

    test("hold repeat: nothing fires at or after the timeout") {
        // The backstop releases the key; a repeat after it would press it again.
        var schedule = HoldRepeat(delay: 0.5, interval: 0.0625, cap: 0.75)
        expectEqual(drive(schedule, releasedAt: 100), [0.5, 0.5625, 0.625, 0.6875])
        for _ in 0..<4 { _ = schedule.fire(at: schedule.nextDue ?? 0) }
        expectEqual(schedule.nextDue, nil)
        expectEqual(schedule.fire(at: 0.75), false)
        expectEqual(schedule.fire(at: 5), false)
    }

    test("hold repeat: a zero-second hold repeats nothing") {
        expectEqual(drive(HoldRepeat(delay: 0.5, interval: 0.0625, cap: 60), releasedAt: 0), [])
        expectEqual(drive(HoldRepeat(delay: 0, interval: 0.0625, cap: 60), releasedAt: 0), [])
        expectEqual(HoldRepeat(delay: 0.5, interval: 0.0625, cap: 0).nextDue, nil)
    }

    test("hold repeat: a late wake-up fires once, not a catch-up burst") {
        // A burst would type spaces rather than extend the hold.
        var schedule = HoldRepeat(delay: 0.5, interval: 0.0625, cap: 60)
        expect(schedule.fire(at: 0.7))
        expectEqual(schedule.fire(at: 0.7), false)
        expectEqual(schedule.nextDue, 0.75)
    }

    test("hold repeat: defaults are macOS's, and a slow repeat is capped under Claude's window") {
        expectEqual(HoldRepeat.defaultDelay, 0.5)
        expectEqual(HoldRepeat.defaultInterval, 1.0 / 12)
        expect(HoldRepeat.maxInterval < 0.12)
        expectEqual(HoldRepeat(cap: 60).interval, 1.0 / 12)
        expectEqual(HoldRepeat(delay: 0.5, interval: 0.5, cap: 60).interval, HoldRepeat.maxInterval)
        expectEqual(HoldRepeat(delay: -1, interval: 0.1, cap: 60).delay, 0)
    }

    // MARK: - ClaudeVoiceKey: the key Claude Code actually listens to

    func keybindings(_ text: String) -> Data { Data(text.utf8) }

    test("claude voice key: ctrl+y bound to push-to-talk holds ⌃Y") {
        let key = ClaudeVoiceKey.resolve(data: keybindings(
            #"{"bindings":[{"context":"Chat","bindings":{"ctrl+y":"voice:pushToTalk"}}]}"#
        ))
        expectEqual(key.keyCode, 16)
        expectEqual(key.modifiers, [.control])
        expectEqual(key.mode, .hold)
        expectEqual(key.label, "⌃Y")
    }

    test("claude voice key: space bound explicitly is Space") {
        let key = ClaudeVoiceKey.resolve(data: keybindings(
            #"{"bindings":[{"context":"Chat","bindings":{"space":"voice:pushToTalk"}}]}"#
        ))
        expectEqual(key, .space)
    }

    test("claude voice key: no binding, no file or bad JSON fall back to Space") {
        // Space is Claude Code's own default for voice:pushToTalk.
        expectEqual(ClaudeVoiceKey.resolve(data: nil), .space)
        expectEqual(ClaudeVoiceKey.resolve(data: keybindings("{ not json")), .space)
        expectEqual(ClaudeVoiceKey.resolve(data: keybindings(#"{"bindings":[]}"#)), .space)
        expectEqual(ClaudeVoiceKey.resolve(data: keybindings(
            #"{"bindings":[{"context":"Global","bindings":{"ctrl+y":"voice:pushToTalk"}}]}"#
        )), .space)
        expectEqual(ClaudeVoiceKey.resolve(data: keybindings(
            #"{"bindings":[{"context":"Chat","bindings":{"ctrl+y":"chat:submit"}}]}"#
        )), .space)
    }

    test("claude voice key: a later Chat block rebinding the chord takes it back") {
        let key = ClaudeVoiceKey.resolve(data: keybindings(#"""
            {"bindings":[
              {"context":"Chat","bindings":{"ctrl+y":"voice:pushToTalk"}},
              {"context":"Chat","bindings":{"ctrl+y":"chat:undo"}}
            ]}
            """#))
        expectEqual(key, .space)
    }

    test("claude voice key: chords parse to key codes and modifiers") {
        expectEqual(ClaudeVoiceKey.shortcut(chord: "ctrl+shift+k")?.keyCode, 40)
        expectEqual(ClaudeVoiceKey.shortcut(chord: "ctrl+shift+k")?.modifiers, [.control, .shift])
        expectEqual(ClaudeVoiceKey.shortcut(chord: "alt+v")?.modifiers, [.option])
        expectEqual(ClaudeVoiceKey.shortcut(chord: "meta+v")?.modifiers, [.option])
        expectEqual(ClaudeVoiceKey.shortcut(chord: "Ctrl+Y")?.label, "⌃Y")
        expectEqual(ClaudeVoiceKey.shortcut(chord: "space"), .space)
        // Unholdable: a two-step chord, an unknown key, a modifier alone.
        expectEqual(ClaudeVoiceKey.shortcut(chord: "ctrl+x ctrl+k"), nil)
        expectEqual(ClaudeVoiceKey.shortcut(chord: "ctrl+hyper"), nil)
        expectEqual(ClaudeVoiceKey.shortcut(chord: "ctrl"), nil)
    }

    test("claude voice key: an unholdable binding falls back to Space") {
        expectEqual(ClaudeVoiceKey.resolve(data: keybindings(
            #"{"bindings":[{"context":"Chat","bindings":{"ctrl+x ctrl+k":"voice:pushToTalk"}}]}"#
        )), .space)
    }
}
