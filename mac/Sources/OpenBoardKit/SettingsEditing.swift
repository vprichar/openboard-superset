import Foundation

/**
 Every edit the settings window makes to the bindings, as pure functions on
 `Preferences`.

 The window's controls call these and then `commands.bindingsChanged`, which saves and
 re-applies — there is no save button. Keeping the mutation here rather than inside a
 SwiftUI `Binding` is what makes it testable without a window, and what keeps the UI and
 the dispatcher reading the same fields: `ProfileResolver.resolve` looks up exactly the
 keys written here.

 ## "Nothing" is written, not removed

 Base bindings and profile overrides follow the rules in `Preferences`:

 - A base binding set to `nil` is stored **present with `nil`** — explicitly
   unassigned. Removing the key instead would read as "inherit the default", and a hold
   you cleared would come back on the next launch.
 - A profile override set to `nil` means "do nothing in this app", which is also
   different from absent. Going back to the base binding is `clearOverride`.

 ## Controls a profile cannot override

 `AppProfile` has fields for the joystick, the dial's hold and the action caps' hold —
 the controls that do different things in different apps. A tap on an action cap and
 the dial's click are the same everywhere, so `setAction` with a profile for those is a
 no-op rather than a silent write into the base bindings.
 */
public enum SettingsEditing {
    /// The range of `actionLongPressMs`, matching `Preferences.merging`.
    public static let longPressRange = 250...1500

    /// Bind `control`'s `gesture` to `action`, in the base bindings (`bundleID == nil`)
    /// or as an override in that app's profile, creating the profile if needed.
    public static func setAction(
        _ action: KeyAction?,
        for control: PadControl,
        gesture: Gesture,
        profile bundleID: String?,
        in p: inout Preferences
    ) {
        guard let bundleID else {
            setBaseAction(action, for: control, gesture: gesture, in: &p)
            return
        }
        guard overridable(control, gesture) else { return }
        var profile = p.profiles[bundleID] ?? Preferences.AppProfile()
        switch (control, gesture) {
        case let (.joystick(direction), .tap):
            profile.joystick[direction] = .some(action)
        case (.encoderLong, _), (.encoderClick, .hold):
            profile.encoderLongPress = .some(action)
        case let (.action(key), .hold):
            profile.actionKeysLong[key] = .some(action)
        default:
            return
        }
        p.profiles[bundleID] = profile
    }

    /// Stop overriding `control` in that app, so it inherits the base binding again.
    /// A profile left with no overrides is kept: it is still a context you chose.
    public static func clearOverride(
        _ control: PadControl,
        gesture: Gesture,
        profile bundleID: String,
        in p: inout Preferences
    ) {
        guard var profile = p.profiles[bundleID] else { return }
        switch (control, gesture) {
        case let (.joystick(direction), .tap):
            profile.joystick.removeValue(forKey: direction)
        case (.encoderLong, _), (.encoderClick, .hold):
            profile.encoderLongPress = nil
        case let (.action(key), .hold):
            profile.actionKeysLong.removeValue(forKey: key)
        default:
            return
        }
        p.profiles[bundleID] = profile
    }

    /// Whether a profile can override this control and gesture at all. The UI uses it
    /// to decide whether to offer "Override".
    public static func overridable(_ control: PadControl, _ gesture: Gesture) -> Bool {
        switch (control, gesture) {
        case (.joystick, .tap), (.encoderLong, _), (.encoderClick, .hold), (.action, .hold):
            true
        default:
            false
        }
    }

    /// The chord a `.shortcut` binding sends, under its payload key (`ACT09`,
    /// `ACT09.long`, `JOY.up@com.superset.desktop`…). `nil` removes it.
    public static func setShortcut(_ shortcut: Shortcut?, payloadKey: String, in p: inout Preferences) {
        let key = payloadKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        if let shortcut {
            p.shortcuts[key] = shortcut
        } else {
            p.shortcuts.removeValue(forKey: key)
        }
    }

    /**
     How many times the chord under this payload key is sent per press (clamped to
     `Shortcut.repeatRange`). Nothing recorded: nothing written. A chord this key only
     inherits (`JOY.up@bundle` falling back to `JOY.up`) is copied under the key first,
     so the change stays with the profile, as recording one does.
     */
    public static func setShortcutRepeat(_ count: Int, payloadKey: String, in p: inout Preferences) {
        guard var chord = ProfileResolver.shortcut(forPayloadKey: payloadKey, prefs: p) else { return }
        chord.repeats = count
        setShortcut(chord, payloadKey: payloadKey, in: &p)
    }

    /// How long an action cap must be held, clamped to what the tracker supports.
    public static func setLongPressMs(_ ms: Int, in p: inout Preferences) {
        p.actionLongPressMs = min(max(ms, longPressRange.lowerBound), longPressRange.upperBound)
    }

    /// Add an empty profile for an app. An existing one is left as it is.
    public static func addProfile(bundleID: String, in p: inout Preferences) {
        let bundle = bundleID.trimmingCharacters(in: .whitespaces)
        guard !bundle.isEmpty, p.profiles[bundle] == nil else { return }
        p.profiles[bundle] = Preferences.AppProfile()
    }

    /// Remove an app's profile and the chords recorded for it (`…@bundle`), so they do
    /// not linger unreachable in the file.
    public static func removeProfile(bundleID: String, in p: inout Preferences) {
        p.profiles.removeValue(forKey: bundleID)
        let suffix = "@" + bundleID
        for key in p.shortcuts.keys where key.hasSuffix(suffix) {
            p.shortcuts.removeValue(forKey: key)
        }
    }

    public static func setPadScope(_ scope: PadScope, in p: inout Preferences) {
        p.padScope = scope
    }

    // MARK: - Base bindings

    private static func setBaseAction(
        _ action: KeyAction?,
        for control: PadControl,
        gesture: Gesture,
        in p: inout Preferences
    ) {
        switch (control, gesture) {
        case let (.action(key), .tap):
            p.actionKeys[key] = .some(action)
        case let (.action(key), .hold):
            p.actionKeysLong[key] = .some(action)
        case let (.joystick(direction), .tap):
            switch direction {
            case .up: p.joystick.up = action
            case .down: p.joystick.down = action
            case .left: p.joystick.left = action
            case .right: p.joystick.right = action
            }
        case (.encoderClick, .tap):
            p.encoder.click = action
        case (.encoderLong, _), (.encoderClick, .hold):
            p.encoder.longPress = action
        case (.joystick, .hold):
            // The stick has no hold: a push repeats instead.
            return
        }
    }
}

// MARK: - What the Board pane shows

extension SettingsEditing {
    /// One header in an action picker.
    public struct PickerSection: Equatable, Sendable {
        public let category: KeyAction.Category
        public let title: String
        public let actions: [KeyAction]
    }

    /// `actions` grouped by category, in `Category.allCases` order, empty groups
    /// dropped. Order inside a group is the order given.
    public static func pickerSections(_ actions: [KeyAction] = KeyAction.allCases) -> [PickerSection] {
        KeyAction.Category.allCases.compactMap { category in
            let members = actions.filter { $0.category == category }
            return members.isEmpty ? nil : PickerSection(category: category, title: categoryTitle(category), actions: members)
        }
    }

    public static func categoryTitle(_ category: KeyAction.Category) -> String {
        switch category {
        case .board: tr("Tablero")
        case .navigation: tr("Navegación")
        case .superset: tr("Superset")
        case .typing: tr("Escritura")
        case .voice: tr("Voz")
        case .cmux: tr("cmux")
        case .fun: tr("Diversión")
        }
    }

    /// What stands between a press and its effect, as the picker labels it.
    public static func badges(for action: KeyAction) -> [String] {
        var out: [String] = []
        if action.requiresSuperset { out.append(tr("requiere Superset")) }
        switch action.safeguard {
        case .none: break
        case .debounce: out.append(tr("antirrebote"))
        case .twoStep: out.append(tr("confirmación en dos pasos"))
        case .snapshotFirst: out.append(tr("lee la pantalla antes"))
        }
        return out
    }

    /// Tap/Hold is a choice only on the action caps: agent keys always jump, and the
    /// dial and stick have their own hold (or none).
    public static func offersHold(_ cell: BoardCell) -> Bool { cell.isAction }

    /// Whether this app's profile names this control — "Inherit again" rather than
    /// "Override" in the inspector.
    public static func isOverridden(
        _ control: PadControl,
        gesture: Gesture,
        profile bundleID: String,
        in p: Preferences
    ) -> Bool {
        guard overridable(control, gesture), let profile = p.profiles[bundleID] else { return false }
        switch (control, gesture) {
        case let (.joystick(direction), _): return profile.joystick[direction] != nil
        case (.encoderLong, _), (.encoderClick, .hold): return profile.encoderLongPress != nil
        case let (.action(key), .hold): return profile.actionKeysLong[key] != nil
        default: return false
        }
    }

    /// The cells to mark with the profile badge: every control the profile names.
    public static func overriddenCells(profile bundleID: String, in p: Preferences) -> Set<String> {
        guard let profile = p.profiles[bundleID] else { return [] }
        var cells = Set(profile.actionKeysLong.keys)
        if !profile.joystick.isEmpty { cells.insert("JOY") }
        if profile.encoderLongPress != nil { cells.insert("ENC") }
        return cells
    }

    /// The context chips: the shipped Superset profile first, then by bundle id.
    public static func profileOrder(_ p: Preferences) -> [String] {
        p.profiles.keys.sorted { a, b in
            if a == Preferences.supersetBundleID { return b != a }
            if b == Preferences.supersetBundleID { return false }
            return a < b
        }
    }

    public static func setAllowDangerousSnippets(_ on: Bool, in p: inout Preferences) {
        p.snippetsAllowDangerous = on
    }

    /// The agent key's Remote block: how a send is aimed at it (D10).
    public static func remoteGesture(for mode: Preferences.Targeted.Mode) -> String {
        switch mode {
        case .armed:
            tr("Mantén FAST para preparar el envío, pulsa REJ si prefieres interrumpir y luego pulsa esta tecla. Envía sin saltar a ella.")
        case .chord:
            tr("Mantén esta tecla y pulsa FAST para enviar o REJ para interrumpir. Así, todos los saltos ocurren al soltar.")
        }
    }
}
