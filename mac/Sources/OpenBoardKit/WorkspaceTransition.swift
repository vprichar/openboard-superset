import Foundation

/**
 Which ring show may interrupt which.

 Before this, a show arriving while another played was simply ignored. That was
 harmless while every show was a lap earned by a state change; it stops being harmless
 the moment a workspace switch plays a sweep, because a sweep started a moment before
 a prompt arrives would swallow the prompt's lap — the one signal visible from across
 the room, lost to decoration.

 So: **voice > error > question > manual > workspace > completion**. A higher one cuts
 a lower one off; a lower or equal one is ignored, as before. Voice is not a show — it
 is the rainbow `ambientSide` paints while dictation runs — but it outranks them all,
 so no show may start over it.

 `manual` (a show picked in the Colors pane) sits above the sweep because it was asked
 for, and below the laps because a prompt is still more important than a toy.
 */
public enum ShowPriority: Int, Comparable, Sendable {
    case completion
    case workspace
    case manual
    /// The two-step confirmation window (F4), and the "no workspace" blink that answers
    /// a press. Something you just asked for, so above a sweep or a toy; still below a
    /// prompt or a failure, which are someone else asking you.
    case confirm
    case question
    case error
    case voice

    public static func < (a: ShowPriority, b: ShowPriority) -> Bool { a.rawValue < b.rawValue }

    /// The priority a show carries, by name. Anything not fired by the board is a toy.
    public static func of(showNamed name: String) -> ShowPriority {
        switch name {
        case "completion": .completion
        case "workspace": .workspace
        case "confirm", "no-workspace", "targeted", "refused": .confirm
        case "question": .question
        case "error": .error
        default: .manual
        }
    }
}

public enum ShowArbiter {
    public enum Decision: Equatable, Sendable {
        /// The ring is free.
        case start
        /// Cut the running show off and play this one.
        case preempt
        /// Leave the running show alone; this one does not play.
        case ignore
    }

    public static func decide(
        incoming: ShowPriority, running: ShowPriority?, voiceActive: Bool
    ) -> Decision {
        // Dictation owns the ring. A show painted over it would hide the one light
        // saying the machine is listening.
        if voiceActive, incoming < .voice { return .ignore }
        guard let running else { return .start }
        return incoming > running ? .preempt : .ignore
    }
}

/**
 A workspace's color, for the moment it is switched to.

 Chosen by hand if the user pinned one, otherwise from a short palette by a hash of the
 workspace **id** — not the name, so renaming a workspace does not recolor it, and not
 a free hue from the hash, because a hash can land on orange and orange means "a prompt
 is waiting".
 */
public enum WorkspaceColors {
    /// Palette entries closer than this to a state's hue are dropped. The shipped palette
    /// clears it with room to spare (the nearest is 42°); a hand-edited one may not.
    public static let minimumHueDistance: Double = 20

    public static func color(
        for workspaceID: String,
        identity: Preferences.WorkspaceIdentity,
        stateColors: [RGB]
    ) -> RGB {
        if let pinned = identity.colors[workspaceID] { return pinned }
        var palette = usablePalette(identity.palette, stateColors: stateColors)
        if palette.isEmpty {
            palette = usablePalette(Preferences.WorkspaceIdentity.defaultPalette, stateColors: stateColors)
        }
        guard !palette.isEmpty else { return Preferences.WorkspaceIdentity.defaultPalette[0] }
        return palette[Int(fnv1a(workspaceID) % UInt32(palette.count))]
    }

    /**
     The palette minus anything a state already means.

     A color identical to a state's, or a saturated one within `minimumHueDistance` of a
     saturated state's hue, is dropped. Desaturated colors are judged by exact match
     only: a cool white has no meaningful hue, and is told apart from the states by
     saturation instead.
     */
    public static func usablePalette(_ palette: [RGB], stateColors: [RGB]) -> [RGB] {
        palette.filter { candidate in
            !stateColors.contains { state in
                if state.value == candidate.value { return true }
                guard let a = hue(of: candidate), let b = hue(of: state) else { return false }
                let gap = abs(a - b)
                return min(gap, 360 - gap) < minimumHueDistance
            }
        }
    }

    /// Hue in degrees, or nil for a color too grey or too dark for hue to mean anything.
    public static func hue(of color: RGB) -> Double? {
        let (r, g, b) = (color.red, color.green, color.blue)
        let high = max(r, g, b), low = min(r, g, b)
        let chroma = high - low
        guard high > 0.05, chroma / high >= 0.35 else { return nil }
        var hue: Double
        switch high {
        case r: hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / chroma + 2
        default: hue = (r - g) / chroma + 4
        }
        hue *= 60
        return hue < 0 ? hue + 360 : hue
    }

    /// FNV-1a, 32-bit: stable across launches and builds, unlike `hashValue`, which is
    /// seeded per process and would recolor every workspace on each restart.
    public static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}

/**
 How the borrowed key looks.

 The state's color — urgency is never disguised — but **still**, where every local key
 breathes. On this board breathing means "here": `viewing` and the focus pulse are both
 motion. A still key is the one that is not from here.
 */
public enum OverflowLook {
    public static func appearance(
        _ stateAppearance: Appearance, settings: Preferences.Overflow
    ) -> Appearance {
        guard settings.enabled, stateAppearance.brightness > 0 else { return stateAppearance }
        return Appearance(
            color: stateAppearance.color, effect: settings.effect,
            brightness: settings.brightness, speed: settings.effect.isAnimated ? stateAppearance.speed : 0
        )
    }

    /// The brief flash of the origin workspace's color: where the prompt lives.
    public static func wink(origin: RGB, settings: Preferences.Overflow) -> Appearance {
        Appearance(color: origin, effect: settings.effect, brightness: settings.brightness, speed: 0)
    }

    /// Off with Reduce Motion: a still key already says enough.
    public static func winkAllowed(
        settings: Preferences.Overflow,
        transition: Preferences.WorkspaceTransition,
        reduceMotion: Bool
    ) -> Bool {
        settings.enabled && settings.winkOriginColor
            && !(transition.respectReduceMotion && reduceMotion)
    }
}

/**
 What a workspace switch writes, and when. Pure: the controller only sleeps and writes
 what this says, so every timing rule is checkable without a pad.

 ## "Barrido + recuento"

 | t (ms) | |
 |---|---|
 | 0 | one thstatus: keys needing a human already final, every other key dark; ring sweep starts |
 | 80, 150, 220… | each remaining session key, one write each, in key order |
 | last + 150 | the borrowed key, if it was not lit at 0 |

 then a full repaint, which is the source of truth — the cascade only decides the order
 things appear in, never what they end up showing.

 **Attention is never dark.** A key in `awaiting`, `stalled` or `error` — local or
 borrowed — is lit in its final look from the first frame. It is not part of the count
 and it does not fade in; a prompt hidden for half a second is still a prompt hidden.
 */
public struct TransitionPlan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// One write, the final board.
        case direct
        case cascade
    }

    public enum Ring: Equatable, Sendable {
        case none
        case sweep
        case cut
    }

    public enum Look: Equatable, Sendable {
        /// What `paint` would show.
        case final
        case dark
    }

    public struct Frame: Equatable, Sendable {
        public let atMs: Int
        /// Pad key → look. One frame is one thstatus.
        public let keys: [Int: Look]

        public init(atMs: Int, keys: [Int: Look]) {
            self.atMs = atMs
            self.keys = keys
        }
    }

    public let kind: Kind
    public let ring: Ring
    public let frames: [Frame]

    public init(kind: Kind, ring: Ring, frames: [Frame]) {
        self.kind = kind
        self.ring = ring
        self.frames = frames
    }
}

public enum TransitionPlanner {
    /// What a key holds, as far as the transition cares.
    public enum KeyRole: Equatable, Sendable {
        case empty
        case session
        /// Needs a human. Lit from the first frame, never counted.
        case attention
    }

    public static func role(of state: SessionState?) -> KeyRole {
        switch state {
        case nil, .ended?: .empty
        case .awaiting?, .stalled?, .error?: .attention
        default: .session
        }
    }

    public static func direct(capacity: Int = BoardLayout.slotCount) -> TransitionPlan {
        TransitionPlan(
            kind: .direct, ring: .none,
            frames: [.init(atMs: 0, keys: Dictionary(uniqueKeysWithValues: (1...capacity).map { ($0, .final) }))]
        )
    }

    public static func cascade(
        roles: [Int: KeyRole],
        overflowKey: Int?,
        settings: Preferences.WorkspaceTransition,
        capacity: Int = BoardLayout.slotCount
    ) -> [TransitionPlan.Frame] {
        var first: [Int: TransitionPlan.Look] = [:]
        for key in 1...capacity {
            first[key] = roles[key] == .attention ? .final : .dark
        }
        var frames = [TransitionPlan.Frame(atMs: 0, keys: first)]

        var at = settings.firstKeyDelayMs
        var last: Int?
        for key in 1...capacity where key != overflowKey && roles[key] == .session {
            frames.append(.init(atMs: at, keys: [key: .final]))
            last = at
            at += settings.keyStaggerMs
        }
        // Last and set apart: it is not one of this workspace's sessions.
        if let overflowKey, roles[overflowKey] == .session {
            frames.append(.init(atMs: (last ?? 0) + settings.overflowDelayMs, keys: [overflowKey: .final]))
        }
        return frames
    }

    /**
     Whether the ring is free for the sweep, apart from a running show — which
     `ShowArbiter` decides when the sweep is played.

     Not with dictation running, not in a mode that never laps, and not in `aggregate`
     while the ring is holding `awaiting` or `error`: that color is the urgency, and a
     second and a half of decoration over it is a second and a half of it missing.
     */
    public static func ringFree(
        mode: Ambient.Mode,
        ringStates: [SessionState?],
        appearances: [SessionState: Appearance],
        voiceActive: Bool
    ) -> Bool {
        guard !voiceActive, Ambient.lapsAllowed(in: mode) else { return false }
        if mode == .aggregate,
           let held = Ambient.resolve(states: ringStates, mode: mode, appearances: appearances)?.state,
           held == .awaiting || held == .error {
            return false
        }
        return true
    }
}

/**
 The state a transition carries between switches: which one is current, and when the
 last one played.

 A switch gets a **generation**. Anything that supersedes it — another switch, or a
 session suddenly needing a human — bumps the generation, and the running cascade finds
 out before its next write. The same shape as `runningShow` in `play`.
 */
public struct TransitionTracker: Sendable {
    public private(set) var generation = 0
    private var lastStart: Date?
    private var lastSweep: Date?
    private var settled = false

    public init() {}

    /// A switch happened. Returns its generation.
    public mutating func contextChanged() -> Int {
        generation += 1
        return generation
    }

    /// Something more important than the animation arrived. The running cascade stops
    /// and the board is painted whole.
    public mutating func interrupt() {
        generation += 1
    }

    public func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /**
     Decide what a switch plays, once its debounce has passed.

     - Returns: nil when the switch was superseded meanwhile — nothing to do, the newer
       one will paint.
     */
    public mutating func plan(
        generation: Int,
        now: Date,
        to next: BoardContext,
        roles: [Int: TransitionPlanner.KeyRole],
        overflowKey: Int?,
        settings: Preferences.WorkspaceTransition,
        reduceMotion: Bool,
        ringFree: Bool,
        capacity: Int = BoardLayout.slotCount
    ) -> TransitionPlan? {
        guard isCurrent(generation) else { return nil }
        let direct = TransitionPlanner.direct(capacity: capacity)

        // The first context after launch is the board arriving, not a switch.
        guard settled else {
            settled = true
            return direct
        }
        // Leaving Superset for a terminal: no workspace, so no identity to show.
        guard case .superset = next else { return direct }
        if settings.style == .off || (settings.respectReduceMotion && reduceMotion) {
            return direct
        }
        // Switching fast: respond at once and do not flicker. The sweep already
        // playing is left to finish its fade.
        if let lastStart, now.timeIntervalSince(lastStart) * 1000 < Double(settings.rapidWindowMs) {
            return direct
        }
        lastStart = now

        switch settings.style {
        case .off:
            return direct
        case .cut:
            return TransitionPlan(kind: .direct, ring: ringFree ? .cut : .none, frames: direct.frames)
        case .sweepCascade:
            let sweepRested = lastSweep.map {
                now.timeIntervalSince($0) * 1000 >= Double(settings.minSweepIntervalMs)
            } ?? true
            let sweep = ringFree && settings.ringSweep && sweepRested
            if sweep { lastSweep = now }
            return TransitionPlan(
                kind: .cascade, ring: sweep ? .sweep : .none,
                frames: TransitionPlanner.cascade(
                    roles: roles, overflowKey: overflowKey, settings: settings, capacity: capacity
                )
            )
        }
    }
}

/**
 Walks a plan one action at a time, checking before every write that it is still
 wanted. The controller sleeps and writes; this decides.
 */
public struct TransitionPlayback: Sendable {
    public enum Action: Equatable, Sendable {
        /// Sleep until this many ms after the transition started.
        case wait(untilMs: Int)
        case write(TransitionPlan.Frame)
        /// Played out. Repaint the board whole — the source of truth.
        case finish
        /// Superseded. Repaint the board whole, now: the animation is lost, never the
        /// signal that interrupted it.
        case abort
        /// Nothing left; `finish` or `abort` was already returned.
        case done
    }

    private let frames: [TransitionPlan.Frame]
    private var index = 0
    private var waited = false
    private var ended = false

    public init(_ plan: TransitionPlan) {
        frames = plan.frames
    }

    public mutating func next(isCurrent: Bool) -> Action {
        guard !ended else { return .done }
        guard isCurrent else {
            ended = true
            return .abort
        }
        guard index < frames.count else {
            ended = true
            return .finish
        }
        let frame = frames[index]
        if !waited, frame.atMs > 0 {
            waited = true
            return .wait(untilMs: frame.atMs)
        }
        waited = false
        index += 1
        return .write(frame)
    }
}

/**
 Six keys, one call.

 `v.oai.thstatus` takes an array. A repaint used to send one call per key, and each
 call waits for its acknowledgement before the next — roughly 200ms a board. One call
 is one round trip, and the transition's first frame lands as one picture instead of
 six in a row.
 */
public enum PadPaint {
    /// - Parameter looks: pad key → what to show. A key the calibration does not cover
    ///   is skipped, never guessed.
    /// - Returns: the batch to write — empty when there is nothing to write.
    public static func keyBatch(
        _ looks: [Int: Appearance],
        calibration: Calibration,
        transport: PadTransport
    ) -> (batch: [[Data]], written: Int, skipped: Int) {
        var threads: [CodexProtocol.ThreadState] = []
        var skipped = 0
        for key in looks.keys.sorted() {
            guard let look = looks[key],
                  let physical = calibration.physicalSlot(for: key),
                  let thread = try? CodexProtocol.ThreadState(
                      physicalSlot: physical,
                      color: look.color,
                      brightness: look.brightness,
                      effect: CodexProtocol.Effect(rawValue: look.effect.deviceCode) ?? .solid,
                      speed: look.speed
                  )
            else {
                skipped += 1
                continue
            }
            threads.append(thread)
        }
        guard !threads.isEmpty else { return ([], 0, skipped) }
        return ([transport.prepare(threads: threads)], threads.count, skipped)
    }
}
