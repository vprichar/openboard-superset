import Foundation

/**
 A key that changes state shows its new color at once: solid, full brightness, for
 about 350 ms, and then its own look.

 The states themselves change in well under a second, but the shipped looks are slow
 shallow breaths (speed 0.25–0.45), and a breath that is at the bottom of its curve
 when the color changes takes most of a cycle to show it. The flash is the answer to
 "did it change?"; the look that follows is the answer to "what is it doing?".

 Only a change of state *of the same session on the same key* flashes. The first paint
 has nothing to compare with, and a different session on a key is a workspace switch,
 which has its own cascade. A dark key stays dark. Keys that change together share one
 flash — one deadline, one write back — so a burst of hooks is one blink, not several.

 Pure: the controller feeds each paint's looks and states and writes what comes back,
 in the same single batched write as always, and repaints once at `until`.
 */
public struct StateFlash: Sendable {
    public static let defaultDuration: TimeInterval = 0.35

    /// What a key showed at the last paint.
    public struct Key: Equatable, Sendable {
        public var sessionID: String?
        public var state: SessionState?

        public init(_ sessionID: String?, _ state: SessionState?) {
            self.sessionID = sessionID
            self.state = state
        }
    }

    public var duration: TimeInterval
    /// When the flash in progress ends — the controller's cue to repaint. Nil when none is.
    public private(set) var until: Date?
    /// The keys flashing now.
    public private(set) var keys: Set<Int> = []
    private var seen: [Int: Key] = [:]

    public init(duration: TimeInterval = defaultDuration) {
        self.duration = duration
    }

    /**
     The looks to write for this paint.

     - Parameter looks: pad key → its own appearance.
     - Parameter states: pad key → the session on it and its state.
     */
    public mutating func apply(_ looks: [Int: Appearance], states: [Int: Key], now: Date) -> [Int: Appearance] {
        if let until, now >= until {
            self.until = nil
            keys = []
        }

        var changed: Set<Int> = []
        for (key, current) in states {
            if let before = seen[key], before.sessionID != nil, before.sessionID == current.sessionID,
               before.state != current.state {
                changed.insert(key)
            }
            seen[key] = current
        }
        for key in seen.keys where states[key] == nil {
            seen[key] = nil
        }

        if !changed.isEmpty {
            keys.formUnion(changed)
            until = now.addingTimeInterval(duration)
        }

        guard !keys.isEmpty else { return looks }
        var out = looks
        for key in keys {
            guard let look = looks[key], look.effect != .off else { continue }
            out[key] = Appearance(color: look.color, effect: .solid, brightness: 1, speed: 0)
        }
        return out
    }
}

/**
 How fast the lights move: the state effects' speed and the ring's laps.

 A factor applied when painting — the stored appearances are never rewritten, so
 going back to `normal` gives back exactly the configured looks. Effect speed is
 multiplied and clamped to the device's 0…1; a lap is shortened in proportion and its
 snake sped up by the same factor, so it is still one lap (see `Shows.paced`).
 */
public enum AnimationSpeed: String, CaseIterable, Sendable {
    case normal
    case fast
    case veryFast = "very-fast"

    public static let `default`: AnimationSpeed = .fast

    public var factor: Double {
        switch self {
        case .normal: 1
        case .fast: 2
        case .veryFast: 3
        }
    }

    /// The look as painted: same color and brightness, the effect `factor` times faster.
    public func look(_ appearance: Appearance) -> Appearance {
        guard self != .normal else { return appearance }
        var paced = appearance
        paced.speed = min(appearance.speed * factor, 1)
        return paced
    }
}
