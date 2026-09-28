import Foundation

/**
 A keyboard chord a pad key replays.

 Recorded in Settings from a real keystroke and stored beside the snippets, keyed by the
 control it belongs to: `ACT08`, `ENC` (the dial's click), `ENC.long` (its hold) and
 `JOY.up` … `JOY.right`. The action itself is just `KeyAction.shortcut`; this is the
 payload, the same split `.snippet` and `snippets` already have.

 `key` is the name shown for the main key ("Space", "Y", "F5") and is captured at record
 time by the app, which is the only place that can ask the keyboard what a key code is
 called. Kept on disk so the label does not depend on a table that may not know the key.

 Pure Foundation, so the file format and the label can be tested without AppKit.
 */
public struct Shortcut: Equatable, Sendable {
    /// In the order macOS prints them: fn first because it is a word, then ⌃ ⌥ ⇧ ⌘.
    public enum Modifier: String, CaseIterable, Sendable {
        case function, control, option, shift, command

        var symbol: String {
            switch self {
            case .function: "fn "
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    /// Tap sends the chord once. Hold keeps it down until the pad key comes back up —
    /// only honoured on the action caps, the one control with a release edge.
    public enum Mode: String, Sendable {
        case tap, hold
    }

    /// macOS virtual key code.
    public var keyCode: Int
    public var modifiers: Set<Modifier>
    public var key: String
    public var mode: Mode
    /**
     How many times one press sends a tapped chord — 2 turns ESC into Claude Code's
     double Esc. Stored as `repeat`; clamped to `repeatRange`. Ignored for `.hold`,
     which keeps the chord down instead.
     */
    public var repeats: Int {
        didSet { repeats = Self.clampRepeats(repeats) }
    }

    public static let repeatRange = 1...5
    /**
     The pause between repeated sends. Fixed, not a setting: short enough that the two
     keys read as one gesture (Claude Code's double Esc wants them close), long enough
     that the terminal sees two separate keystrokes rather than one.
     */
    public static let repeatGap: TimeInterval = 0.06

    public init(keyCode: Int, modifiers: Set<Modifier> = [], key: String, mode: Mode = .tap, repeats: Int = 1) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
        self.mode = mode
        self.repeats = Self.clampRepeats(repeats)
    }

    static func clampRepeats(_ n: Int) -> Int {
        min(max(n, repeatRange.lowerBound), repeatRange.upperBound)
    }

    /**
     When to send, relative to the previous send: the first at once, each repeat
     `repeatGap` later. One entry for a hold, whatever `repeats` says. The controller
     sends exactly this sequence, so its order and count are what the tests pin.
     */
    public var sendDelays: [TimeInterval] {
        let count = mode == .tap ? repeats : 1
        return [0] + Array(repeating: Self.repeatGap, count: count - 1)
    }

    /// What push-to-talk holds: space, no modifiers.
    public static let space = Shortcut(keyCode: 49, key: "Space", mode: .hold)

    /// "⌃⌥Space" — for the button and the log. A chord that is a modifier alone (a
    /// lone right ⌥) has no key name and shows just its symbol.
    public var label: String {
        let symbols = Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined()
        guard key.isEmpty else { return symbols + key }
        return symbols.isEmpty ? "key \(keyCode)" : symbols.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - the file

    /// Nil without a sendable key code — `CGKeyCode` is a `UInt16`, and a hand-edited
    /// value outside its range would trap at the moment the pad key is pressed, not
    /// here. Anything else degrades: an unknown modifier name is skipped, an unknown
    /// mode is a tap.
    public init?(json: [String: Any]) {
        guard let keyCode = json["keyCode"] as? Int, UInt16(exactly: keyCode) != nil
        else { return nil }
        self.keyCode = keyCode
        let names = json["modifiers"] as? [String] ?? []
        modifiers = Set(names.compactMap(Modifier.init(rawValue:)))
        key = json["key"] as? String ?? ""
        mode = (json["mode"] as? String).flatMap(Mode.init(rawValue:)) ?? .tap
        // Only a whole number counts; "2" or 2.7 typed by hand read as once.
        let raw = json["repeat"].flatMap { $0 as? NSNumber }
        let whole = raw.flatMap { CFNumberIsFloatType($0) ? nil : $0.intValue }
        repeats = Self.clampRepeats(whole ?? 1)
    }

    /// Modifiers written in `allCases` order, so a save never reorders the file.
    /// `repeat` only when it is not 1, so existing files are written back unchanged.
    public var json: [String: Any] {
        var fields: [String: Any] = [
            "keyCode": keyCode,
            "modifiers": Modifier.allCases.filter(modifiers.contains).map(\.rawValue),
            "key": key,
            "mode": mode.rawValue,
        ]
        if repeats != 1 { fields["repeat"] = repeats }
        return fields
    }
}
