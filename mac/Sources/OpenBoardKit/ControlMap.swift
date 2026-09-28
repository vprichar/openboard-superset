import Foundation

/**
 Everything the key dispatch consults, built in one place from the preferences and the
 app in front.

 `BoardController.applyPreferences()` calls `make` and nothing else, so a settings edit
 reaches the pad without a restart, and there is no second copy of a binding that an
 edit could forget to update. Pure: the same preferences and front app always give the
 same map, and a map carries nothing over from the one before it — undoing an edit
 gives back exactly the previous map.

 Taps are never per-app (see `ProfileResolver`); the joystick, the encoder's long
 press and the caps' long presses are. `questionMode` turns the joystick into bare
 arrows while a visible session waits on a prompt, and touches nothing else.
 */
public struct ControlMap: Equatable, Sendable {
    /// What each action cap does on a tap, plus `ENC`. Unassigned caps are absent.
    public var taps: [String: KeyAction]
    /// The dial's click.
    public var encoderClick: KeyAction?
    /// The dial held past its threshold.
    public var encoderLong: Resolved
    /// Each push of the stick.
    public var joystick: [Joystick.Direction: Resolved]
    /// The caps' long presses. Only caps that have one are present.
    public var holds: [String: Resolved]
    /// Caps that wait to tell a tap from a hold — `KeyDispatcher.longPressKeys`.
    public var longPressKeys: Set<String>
    /// `actionLongPressMs`, in seconds.
    public var longPressThreshold: TimeInterval
    public var scrollLines: Int
    public var clockwiseScrollsUp: Bool

    /**
     How long after a press the controller's timer asks the tracker for the hold.

     A little past the threshold, never at it: a sleep of exactly the threshold can
     wake a hair early, the tracker then answers "not yet", and the hold only fires
     when the key comes up — which is the "nothing happens until I let go" feel the
     long press exists to avoid.
     */
    public var holdPollDelay: TimeInterval { longPressThreshold + Self.holdPollMargin }
    public static let holdPollMargin: TimeInterval = 0.03

    public init(
        taps: [String: KeyAction],
        encoderClick: KeyAction?,
        encoderLong: Resolved,
        joystick: [Joystick.Direction: Resolved],
        holds: [String: Resolved],
        longPressKeys: Set<String>,
        longPressThreshold: TimeInterval,
        scrollLines: Int,
        clockwiseScrollsUp: Bool
    ) {
        self.taps = taps
        self.encoderClick = encoderClick
        self.encoderLong = encoderLong
        self.joystick = joystick
        self.holds = holds
        self.longPressKeys = longPressKeys
        self.longPressThreshold = longPressThreshold
        self.scrollLines = scrollLines
        self.clockwiseScrollsUp = clockwiseScrollsUp
    }

    public static func make(
        prefs: Preferences, frontBundleID: String? = nil, questionMode: Bool = false
    ) -> ControlMap {
        let caps = BoardLayout.cells.filter(\.isAction).map(\.id)

        var taps: [String: KeyAction] = [:]
        for cap in caps {
            taps[cap] = ProfileResolver.resolve(.action(cap), .tap, frontBundleID: frontBundleID, prefs: prefs).action
        }
        // The dial's own entry in `actionKeys`, as the dispatcher has always read it.
        taps["ENC"] = prefs.keyActions["ENC"]

        let longPressKeys = ProfileResolver.longPressKeys(frontBundleID: frontBundleID, prefs: prefs)
        var holds: [String: Resolved] = [:]
        for cap in longPressKeys {
            holds[cap] = ProfileResolver.resolve(.action(cap), .hold, frontBundleID: frontBundleID, prefs: prefs)
        }

        var joystick: [Joystick.Direction: Resolved] = [:]
        for direction in Joystick.Direction.allCases {
            joystick[direction] = ProfileResolver.resolve(
                .joystick(direction), .tap, frontBundleID: frontBundleID, prefs: prefs,
                questionMode: questionMode
            )
        }

        return ControlMap(
            taps: taps,
            encoderClick: ProfileResolver.resolve(.encoderClick, .tap, frontBundleID: frontBundleID, prefs: prefs).action,
            encoderLong: ProfileResolver.resolve(.encoderLong, .hold, frontBundleID: frontBundleID, prefs: prefs),
            joystick: joystick,
            holds: holds,
            longPressKeys: longPressKeys,
            longPressThreshold: Double(prefs.actionLongPressMs) / 1000,
            scrollLines: prefs.scrollLines,
            clockwiseScrollsUp: prefs.encoder.clockwiseScrollsUp
        )
    }

    /// The long press of this cap, if it has one with this app in front.
    public func hold(_ cap: String) -> Resolved? {
        guard let resolved = holds[cap], resolved.action != nil else { return nil }
        return resolved
    }

    /**
     Hand the dispatcher its bindings. Its debounce history is cleared, so a rebind is
     not swallowed by the previous binding's window.
     */
    public func configure(_ dispatcher: inout KeyDispatcher) {
        dispatcher.actions = taps
        dispatcher.encoderClick = taps["ENC"]
        dispatcher.longPressKeys = longPressKeys
        dispatcher.scrollLines = scrollLines
        dispatcher.clockwiseScrollsUp = clockwiseScrollsUp
        dispatcher.reset()
    }
}
