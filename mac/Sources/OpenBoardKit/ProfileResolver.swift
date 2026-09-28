import Foundation

// `PadControl` and `Gesture` live in PadControl.swift, shared with the settings editor.

/// What a control means right now, and where that meaning came from.
public struct Resolved: Equatable, Sendable {
    public var action: KeyAction?
    /// The key to look a chord or snippet up by: "JOY.up@com.superset.desktop",
    /// "ACT09.long"… Carries `@<bundle>` whenever the app in front has a profile, so a
    /// per-app chord applies even to a binding the profile inherits.
    public var payloadKey: String
    /// Shown in the settings as "inherited" when it is not `.profile`.
    public var source: Source

    public enum Source: Equatable, Sendable {
        /// Overridden by the profile of this bundle id.
        case profile(String)
        /// Set in the preferences' base bindings.
        case base
        /// Absent from the preferences; taken from the built-in defaults.
        case `default`
    }

    public init(action: KeyAction?, payloadKey: String, source: Source) {
        self.action = action
        self.payloadKey = payloadKey
        self.source = source
    }
}

/**
 Per-app profiles (F2): which action a control runs given the app in front.

 Pure — the front bundle and the preferences are arguments — so the whole table of the
 Plan §2.3 can be tested without an app running. A profile only overrides what it
 names: absent inherits the base binding, present with `nil` unbinds in that app.
 Taps on action caps and the encoder click are never overridden; profiles cover the
 joystick, the encoder's long press and the caps' long presses (`AppProfile`).
 */
public enum ProfileResolver {
    private static let bundleSeparator: Character = "@"

    public static func resolve(
        _ control: PadControl,
        _ gesture: Gesture,
        frontBundleID: String?,
        prefs: Preferences
    ) -> Resolved {
        let bundle = frontBundleID.flatMap { prefs.profiles[$0] != nil ? $0 : nil }
        let profile = bundle.flatMap { prefs.profiles[$0] }

        func key(_ base: String) -> String {
            bundle.map { "\(base)\(bundleSeparator)\($0)" } ?? base
        }

        switch (control, gesture) {
        case let (.joystick(direction), _):
            // The stick has no hold; both gestures mean the push.
            let payload = key("JOY.\(direction.rawValue)")
            if let bundle, let override = profile?.joystick[direction] {
                return Resolved(action: override, payloadKey: payload, source: .profile(bundle))
            }
            return Resolved(action: prefs.joystick.action(for: direction), payloadKey: payload, source: .base)

        case (.encoderLong, _), (.encoderClick, .hold):
            let payload = key("ENC.long")
            if let bundle, let override = profile?.encoderLongPress {
                return Resolved(action: override, payloadKey: payload, source: .profile(bundle))
            }
            return Resolved(action: prefs.encoder.longPress, payloadKey: payload, source: .base)

        case (.encoderClick, .tap):
            return Resolved(action: prefs.encoder.click, payloadKey: key("ENC"), source: .base)

        case let (.action(cap), .tap):
            let payload = key(cap)
            if let bound = prefs.actionKeys[cap] {
                return Resolved(action: bound, payloadKey: payload, source: .base)
            }
            return Resolved(action: KeyAction.defaults[cap], payloadKey: payload, source: .default)

        case let (.action(cap), .hold):
            let payload = key("\(cap).long")
            if let bundle, let override = profile?.actionKeysLong[cap] {
                return Resolved(action: override, payloadKey: payload, source: .profile(bundle))
            }
            if let bound = prefs.actionKeysLong[cap] {
                return Resolved(action: bound, payloadKey: payload, source: .base)
            }
            let fallback = Preferences.default.actionKeysLong[cap] ?? nil
            return Resolved(action: fallback, payloadKey: payload, source: .default)
        }
    }

    /// The chord for a payload key: `<key>@<bundle>` first, then the bare `<key>`.
    public static func shortcut(forPayloadKey key: String, prefs: Preferences) -> Shortcut? {
        lookup(key) { prefs.shortcuts[$0] }
    }

    /// The snippet for a payload key, with the same fallback as `shortcut`.
    public static func snippet(forPayloadKey key: String, prefs: Preferences) -> String? {
        lookup(key) { prefs.snippets[$0] }
    }

    /// The payload key without its `@<bundle>` suffix.
    public static func baseKey(of payloadKey: String) -> String {
        payloadKey.split(separator: bundleSeparator, maxSplits: 1).first.map(String.init) ?? payloadKey
    }

    /**
     The action caps that have a long press with this app in front — what
     `KeyDispatcher.longPressKeys` should hold. Every other cap keeps firing on the way
     down, with no added latency.
     */
    public static func longPressKeys(frontBundleID: String?, prefs: Preferences) -> Set<String> {
        var caps = Set(prefs.actionKeysLong.keys).union(Preferences.default.actionKeysLong.keys)
        if let front = frontBundleID, let profile = prefs.profiles[front] {
            caps.formUnion(profile.actionKeysLong.keys)
        }
        return caps.filter {
            resolve(.action($0), .hold, frontBundleID: frontBundleID, prefs: prefs).action != nil
        }
    }

    private static func lookup<T>(_ key: String, _ find: (String) -> T?) -> T? {
        if let found = find(key) { return found }
        let base = baseKey(of: key)
        return base == key ? nil : find(base)
    }
}
