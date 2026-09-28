import Foundation
import OpenBoardKit

/*
 The settings window's edits, without the window.

 Every control writes through `SettingsEditing`, so these pin what each edit leaves in
 `Preferences` — and, through a save-and-load round trip, what the next launch reads.
 */
func runSettingsEditingTests() {
    let superset = Preferences.supersetBundleID

    /// Defaults with ACT07's hold removed, so a test that expects it written cannot pass
    /// on the built-in D7 default alone.
    func blankHold() -> Preferences {
        var p = Preferences.default
        p.actionKeysLong.removeValue(forKey: "ACT07")
        return p
    }

    /// What the next launch reads: saved to JSON and merged back.
    func reloaded(_ p: Preferences) -> Preferences {
        let data = try! JSONSerialization.data(withJSONObject: p.json)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return Preferences.merging(json)
    }

    test("settings editing: holding ACT07 is written to actionKeysLong") {
        var p = blankHold()
        SettingsEditing.setAction(.jumpOldestWaiting, for: .action("ACT07"), gesture: .hold, profile: nil, in: &p)
        expectEqual(p.actionKeysLong["ACT07"], .some(.jumpOldestWaiting))
        // The tap binding is a different field and stays as it was.
        expectEqual(p.actionKeys["ACT07"], Preferences.default.actionKeys["ACT07"])
    }

    test("settings editing: nil clears the hold, and it stays cleared after a reload") {
        var p = Preferences.default
        expectEqual(p.actionKeysLong["ACT07"], .some(.jumpOldestWaiting), "precondition: D7 default")
        SettingsEditing.setAction(nil, for: .action("ACT07"), gesture: .hold, profile: nil, in: &p)
        // Present with nil — explicitly unassigned, not "inherit the default".
        expectEqual(p.actionKeysLong["ACT07"], .some(nil))
        expectEqual(reloaded(p).actionKeysLong["ACT07"], .some(nil), "the default must not come back")
    }

    test("settings editing: tapping an action cap is written to actionKeys") {
        var p = Preferences.default
        SettingsEditing.setAction(.interruptFocused, for: .action("ACT10"), gesture: .tap, profile: nil, in: &p)
        expectEqual(p.actionKeys["ACT10"], .some(.interruptFocused))
        expectEqual(reloaded(p).actionKeys["ACT10"], .some(.interruptFocused))
    }

    test("settings editing: base joystick and dial go to their own fields") {
        var p = Preferences.default
        SettingsEditing.setAction(.targetedArm, for: .joystick(.left), gesture: .tap, profile: nil, in: &p)
        SettingsEditing.setAction(.jumpOldestWaiting, for: .encoderLong, gesture: .hold, profile: nil, in: &p)
        SettingsEditing.setAction(nil, for: .encoderClick, gesture: .tap, profile: nil, in: &p)
        expectEqual(p.joystick.left, .targetedArm)
        expectEqual(p.joystick.up, Preferences.default.joystick.up, "other directions untouched")
        expectEqual(p.encoder.longPress, .jumpOldestWaiting)
        expectEqual(p.encoder.click, nil)
    }

    test("settings editing: a profile override lands in the profile, not the base") {
        var p = Preferences.default
        SettingsEditing.setAction(.targetedArm, for: .joystick(.down), gesture: .tap, profile: superset, in: &p)
        expectEqual(p.profiles[superset]?.joystick[.down], .some(.targetedArm))
        expectEqual(p.joystick.down, Preferences.default.joystick.down, "base unchanged")
        expectEqual(reloaded(p).profiles[superset]?.joystick[.down], .some(.targetedArm))
    }

    test("settings editing: clearOverride goes back to inheriting") {
        var p = Preferences.default
        SettingsEditing.setAction(.jumpOldestWaiting, for: .action("ACT09"), gesture: .hold, profile: superset, in: &p)
        expectEqual(p.profiles[superset]?.actionKeysLong["ACT09"], .some(.jumpOldestWaiting))
        SettingsEditing.clearOverride(.action("ACT09"), gesture: .hold, profile: superset, in: &p)
        expect(p.profiles[superset]?.actionKeysLong["ACT09"] == nil, "absent = inherits the base")
        expect(p.profiles[superset] != nil, "the profile itself stays")

        SettingsEditing.clearOverride(.joystick(.up), gesture: .tap, profile: superset, in: &p)
        expect(p.profiles[superset]?.joystick[.up] == nil)
        expect(p.profiles[superset]?.joystick[.down] != nil, "only the one direction")
        let after = reloaded(p)
        expect(after.profiles[superset]?.joystick[.up] == nil, "the built-in override must not come back")
    }

    test("settings editing: a profile override set to nil is 'nothing here', not inherit") {
        var p = Preferences.default
        SettingsEditing.setAction(nil, for: .encoderLong, gesture: .hold, profile: superset, in: &p)
        expectEqual(p.profiles[superset]?.encoderLongPress, .some(nil))
        SettingsEditing.clearOverride(.encoderLong, gesture: .hold, profile: superset, in: &p)
        expectEqual(p.profiles[superset]?.encoderLongPress, KeyAction??.none)
    }

    test("settings editing: a profile cannot override a tap on an action cap") {
        var p = Preferences.default
        let bundle = "com.apple.Terminal"
        SettingsEditing.setAction(.interruptFocused, for: .action("ACT06"), gesture: .tap, profile: bundle, in: &p)
        expect(p.profiles[bundle] == nil, "no profile conjured for a no-op")
        expectEqual(p.actionKeys["ACT06"], Preferences.default.actionKeys["ACT06"], "and the base is not written")
        expect(!SettingsEditing.overridable(.action("ACT06"), .tap))
        expect(SettingsEditing.overridable(.action("ACT06"), .hold))
        expect(SettingsEditing.overridable(.joystick(.up), .tap))
    }

    test("settings editing: setShortcut keeps the profile payload key") {
        var p = Preferences.default
        let key = "JOY.up@\(superset)"
        let chord = Shortcut(keyCode: 126, modifiers: [.control], key: "↑")
        SettingsEditing.setShortcut(chord, payloadKey: key, in: &p)
        expectEqual(p.shortcuts[key], chord)
        expect(p.shortcuts["JOY.up"] != chord, "the base chord is a different key")
        expectEqual(reloaded(p).shortcuts[key], chord)
        SettingsEditing.setShortcut(nil, payloadKey: key, in: &p)
        expect(p.shortcuts[key] == nil)
    }

    test("settings editing: setLongPressMs clamps to 250…1500") {
        var p = Preferences.default
        SettingsEditing.setLongPressMs(50, in: &p)
        expectEqual(p.actionLongPressMs, 250)
        SettingsEditing.setLongPressMs(9000, in: &p)
        expectEqual(p.actionLongPressMs, 1500)
        SettingsEditing.setLongPressMs(700, in: &p)
        expectEqual(p.actionLongPressMs, 700)
    }

    test("settings editing: adding and removing a profile, chords included") {
        var p = Preferences.default
        let bundle = "com.apple.Terminal"
        SettingsEditing.addProfile(bundleID: bundle, in: &p)
        expectEqual(p.profiles[bundle], Preferences.AppProfile())
        SettingsEditing.setAction(.targetedArm, for: .joystick(.up), gesture: .tap, profile: bundle, in: &p)
        SettingsEditing.addProfile(bundleID: bundle, in: &p)
        expectEqual(p.profiles[bundle]?.joystick[.up], .some(.targetedArm), "adding again keeps it")
        SettingsEditing.addProfile(bundleID: "  ", in: &p)
        expect(p.profiles["  "] == nil && p.profiles[""] == nil, "blank ids are ignored")

        let chord = Shortcut(keyCode: 126, modifiers: [.command], key: "↑")
        SettingsEditing.setShortcut(chord, payloadKey: "JOY.up@\(bundle)", in: &p)
        SettingsEditing.setShortcut(chord, payloadKey: "JOY.up@\(superset)", in: &p)
        SettingsEditing.removeProfile(bundleID: bundle, in: &p)
        expect(p.profiles[bundle] == nil)
        expect(p.shortcuts["JOY.up@\(bundle)"] == nil, "its chords go with it")
        expectEqual(p.shortcuts["JOY.up@\(superset)"], chord, "other profiles' chords stay")

        SettingsEditing.removeProfile(bundleID: superset, in: &p)
        expect(reloaded(p).profiles[superset] == nil, "a removed built-in profile stays removed")
    }

    test("settings editing: setPadScope") {
        var p = Preferences.default
        expectEqual(p.padScope, .focusedWorkspace, "precondition")
        SettingsEditing.setPadScope(.all, in: &p)
        expectEqual(p.padScope, .all)
        expectEqual(reloaded(p).padScope, .all)
    }

    test("settings editing: the repeat count is written to the chord, clamped") {
        var p = Preferences.default
        SettingsEditing.setShortcut(Shortcut(keyCode: 53, key: "⎋"), payloadKey: "ACT12", in: &p)
        SettingsEditing.setShortcutRepeat(2, payloadKey: "ACT12", in: &p)
        expectEqual(p.shortcuts["ACT12"]?.repeats, 2)
        expectEqual(reloaded(p).shortcuts["ACT12"]?.repeats, 2)
        SettingsEditing.setShortcutRepeat(99, payloadKey: "ACT12", in: &p)
        expectEqual(p.shortcuts["ACT12"]?.repeats, 5)
        SettingsEditing.setShortcutRepeat(1, payloadKey: "ACT12", in: &p)
        expectEqual(p.shortcuts["ACT12"]?.repeats, 1)
        // The chord itself is untouched.
        expectEqual(p.shortcuts["ACT12"]?.keyCode, 53)
    }

    test("settings editing: a repeat with no chord recorded writes nothing") {
        var p = Preferences.default
        p.shortcuts.removeValue(forKey: "ACT12")
        SettingsEditing.setShortcutRepeat(2, payloadKey: "ACT12", in: &p)
        expect(p.shortcuts["ACT12"] == nil)
    }

    test("settings editing: a repeat on an inherited per-app chord becomes that app's own") {
        var p = Preferences.default
        let key = "JOY.up@\(superset)"
        p.shortcuts.removeValue(forKey: key)
        p.shortcuts["JOY.up"] = Shortcut(keyCode: 126, key: "↑")
        SettingsEditing.setShortcutRepeat(3, payloadKey: key, in: &p)
        expectEqual(p.shortcuts[key]?.repeats, 3)
        expectEqual(p.shortcuts["JOY.up"]?.repeats, 1, "the base chord is not changed")
    }

    runSettingsPickerTests()
    runSpanishLabelTests()
    runSettingsLiveContractTests()
}

/*
 What the Board pane shows, computed where it can be tested: the grouped picker, the
 badges, which cells get Tap/Hold, which a profile overrides, the dangerous-snippet
 switch, the Remote block's wording and the keycaps that can be chosen.
 */
private func runSettingsPickerTests() {
    let superset = Preferences.supersetBundleID

    test("settings picker: every action is in exactly one section, sections in category order") {
        let sections = SettingsEditing.pickerSections()
        let flat = sections.flatMap(\.actions)
        expectEqual(flat.count, KeyAction.allCases.count, "no action missing or repeated")
        expectEqual(Set(flat), Set(KeyAction.allCases))
        let order = sections.map(\.category)
        expectEqual(order, KeyAction.Category.allCases.filter { c in order.contains(c) }, "category order")
        for section in sections {
            expect(section.actions.allSatisfy { $0.category == section.category }, "\(section.category) mixes categories")
            expect(!section.title.isEmpty)
        }
        expect(sections.first { $0.category == .superset }?.actions.contains(.supersetHandoff) == true)
    }

    test("settings picker: a subset keeps only its non-empty sections") {
        let sections = SettingsEditing.pickerSections(KeyAction.forJoystick)
        expect(!sections.contains { $0.category == .superset }, "no Superset header for the stick")
        expectEqual(Set(sections.flatMap(\.actions)), Set(KeyAction.forJoystick))
    }

    test("settings picker: badges follow requiresSuperset and safeguard") {
        expectEqual(SettingsEditing.badges(for: .supersetHandoff), ["requiere Superset", "confirmación en dos pasos"])
        expectEqual(SettingsEditing.badges(for: .supersetNewAgent), ["requiere Superset", "antirrebote"])
        expectEqual(SettingsEditing.badges(for: .interruptFocused), ["requiere Superset", "lee la pantalla antes"])
        expectEqual(SettingsEditing.badges(for: .jumpOldestWaiting), [], "works without the host-service")
        expectEqual(SettingsEditing.badges(for: .approve), [])
    }

    test("settings picker: Tap/Hold is offered to action cells only") {
        for cell in BoardLayout.cells {
            expectEqual(SettingsEditing.offersHold(cell), cell.isAction, "\(cell.id)")
        }
    }

    test("settings picker: isOverridden and the S badge cells follow the profile") {
        var p = Preferences.default
        // The shipped Superset profile overrides the stick and the dial's hold.
        expect(SettingsEditing.isOverridden(.joystick(.up), gesture: .tap, profile: superset, in: p))
        expect(SettingsEditing.isOverridden(.encoderLong, gesture: .hold, profile: superset, in: p))
        expect(!SettingsEditing.isOverridden(.action("ACT07"), gesture: .hold, profile: superset, in: p))
        expect(!SettingsEditing.isOverridden(.action("ACT07"), gesture: .tap, profile: superset, in: p), "never for a tap")
        expectEqual(SettingsEditing.overriddenCells(profile: superset, in: p), ["JOY", "ENC"])

        SettingsEditing.setAction(.targetedArm, for: .action("ACT09"), gesture: .hold, profile: superset, in: &p)
        SettingsEditing.clearOverride(.encoderLong, gesture: .hold, profile: superset, in: &p)
        expectEqual(SettingsEditing.overriddenCells(profile: superset, in: p), ["JOY", "ACT09"])
        expectEqual(SettingsEditing.overriddenCells(profile: "com.apple.Terminal", in: p), [])
    }

    test("settings picker: profiles are listed Superset first, then by bundle id") {
        var p = Preferences.default
        SettingsEditing.addProfile(bundleID: "com.zed.Zed", in: &p)
        SettingsEditing.addProfile(bundleID: "com.apple.Terminal", in: &p)
        expectEqual(SettingsEditing.profileOrder(p), [superset, "com.apple.Terminal", "com.zed.Zed"])
        SettingsEditing.removeProfile(bundleID: superset, in: &p)
        expectEqual(SettingsEditing.profileOrder(p), ["com.apple.Terminal", "com.zed.Zed"])
    }

    test("settings picker: the dangerous-snippet switch writes snippetsAllowDangerous") {
        var p = Preferences.default
        expect(!p.snippetsAllowDangerous, "precondition: off by default")
        SettingsEditing.setAllowDangerousSnippets(true, in: &p)
        expect(p.snippetsAllowDangerous)
        expect(SnippetGuard.check("/clear", allowDangerous: p.snippetsAllowDangerous) == .allow)
        SettingsEditing.setAllowDangerousSnippets(false, in: &p)
        expect(!p.snippetsAllowDangerous)
    }

    test("settings picker: the Remote block describes the configured gesture") {
        let armed = SettingsEditing.remoteGesture(for: .armed)
        let chord = SettingsEditing.remoteGesture(for: .chord)
        expect(armed.contains("FAST") && armed.contains("REJ"), armed)
        expect(chord.contains("Mantén esta tecla"), chord)
        expect(armed != chord)
    }

    test("keycap catalog: BRANCH draws the split arrows the physical cap carries") {
        // The clone's BRANCH cap is a line forking up-right and down-right, not the
        // three-dot git branch — photo and line drawing of the pad agree.
        expectEqual(KeycapCatalog.cap(id: "BRANCH")?.icon, "worktree")
        expect(KeycapCatalog.icon(forCap: "BRANCH") != nil)
    }

    test("keycap picker: no empty caps, every drawable cap offered") {
        let selectable = KeycapCatalog.selectable
        expect(selectable.allSatisfy { KeycapCatalog.icon(forCap: $0.id) != nil }, "a cap without a glyph is offered")
        let drawable = KeycapCatalog.caps.filter { KeycapCatalog.icon(forCap: $0.id) != nil }
        expectEqual(selectable.map(\.id), drawable.map(\.id))
        expect(selectable.count < KeycapCatalog.caps.count, "precondition: the catalog has empty caps")
    }
}

/*
 The live contract: the window and the dispatcher read the same source.

 After every edit, `ProfileResolver.resolve` over the *same* `Preferences` must answer
 with the new action. This is the checkable half of "changes apply without a restart"
 (the other half, `bindingsChanged` re-reading `model.preferences`, is the
 integrator's `LiveApplyTests`).

 */
private func runSettingsLiveContractTests() {
    let superset = Preferences.supersetBundleID

    test("settings live contract: every edit is what the resolver answers") {
        var p = Preferences.default
        p.actionKeysLong.removeValue(forKey: "ACT07")

        SettingsEditing.setAction(.jumpOldestWaiting, for: .action("ACT07"), gesture: .hold, profile: nil, in: &p)
        expectEqual(ProfileResolver.resolve(.action("ACT07"), .hold, frontBundleID: nil, prefs: p).action, .jumpOldestWaiting)

        SettingsEditing.setAction(nil, for: .action("ACT07"), gesture: .hold, profile: nil, in: &p)
        expectEqual(ProfileResolver.resolve(.action("ACT07"), .hold, frontBundleID: nil, prefs: p).action, nil)

        SettingsEditing.setAction(.interruptFocused, for: .action("ACT10"), gesture: .tap, profile: nil, in: &p)
        expectEqual(ProfileResolver.resolve(.action("ACT10"), .tap, frontBundleID: nil, prefs: p).action, .interruptFocused)

        SettingsEditing.setAction(.targetedArm, for: .joystick(.left), gesture: .tap, profile: nil, in: &p)
        expectEqual(ProfileResolver.resolve(.joystick(.left), .tap, frontBundleID: "com.apple.Terminal", prefs: p).action, .targetedArm)
    }

    test("settings live contract: a profile override resolves in that app only, and clearOverride inherits") {
        var p = Preferences.default
        SettingsEditing.setAction(.targetedArm, for: .joystick(.down), gesture: .tap, profile: superset, in: &p)
        let inSuperset = ProfileResolver.resolve(.joystick(.down), .tap, frontBundleID: superset, prefs: p)
        expectEqual(inSuperset.action, .targetedArm)
        expectEqual(inSuperset.source, .profile(superset))
        let elsewhere = ProfileResolver.resolve(.joystick(.down), .tap, frontBundleID: "com.apple.Terminal", prefs: p)
        expectEqual(elsewhere.action, p.joystick.down)

        SettingsEditing.clearOverride(.joystick(.down), gesture: .tap, profile: superset, in: &p)
        let inherited = ProfileResolver.resolve(.joystick(.down), .tap, frontBundleID: superset, prefs: p)
        expectEqual(inherited.action, p.joystick.down)
        expect(inherited.source != .profile(superset), "back to the base binding")
    }

    test("settings live contract: the chord saved under a payload key is the one resolved") {
        var p = Preferences.default
        SettingsEditing.setAction(.shortcut, for: .joystick(.up), gesture: .tap, profile: superset, in: &p)
        let resolved = ProfileResolver.resolve(.joystick(.up), .tap, frontBundleID: superset, prefs: p)
        let chord = Shortcut(keyCode: 126, modifiers: [.control, .shift], key: "↑")
        SettingsEditing.setShortcut(chord, payloadKey: resolved.payloadKey, in: &p)
        expectEqual(ProfileResolver.shortcut(forPayloadKey: resolved.payloadKey, prefs: p), chord)
    }

}

/*
 The interface is in Spanish (by default). Every label the window, the popover
 and the pad show for an action, a state, an effect or a badge is checked against a
 list of English words that would give away an untranslated string. Proper names
 (Superset, Terminal, cmux, Codex) and key glyphs are not words and pass.
 */
private func runSpanishLabelTests() {
    // Spanish is the default; pinned so a stored choice cannot change what is checked.
    let savedLanguage = UIStrings.override
    UIStrings.override = .es
    defer { UIStrings.override = savedLanguage }
    let english: Set<String> = [
        "the", "open", "session", "sessions", "key", "keys", "new", "tab", "send", "arrow",
        "up", "down", "left", "right", "next", "previous", "hold", "tap", "reject", "approve",
        "pending", "prompt", "running", "waiting", "finished", "failed", "closed", "idle",
        "viewing", "working", "awaiting", "stalled", "done", "ended", "requires", "reads",
        "screen", "first", "debounced", "confirm", "board", "navigation", "typing", "voice",
        "fun", "mode", "nothing", "menu", "settings", "repaint", "forget", "all", "off",
        "type", "custom", "shortcut", "agent", "interrupt", "remote", "oldest", "longest",
        "focused", "workspace", "dictate", "toggle", "and", "or", "to", "of", "in", "with",
        "is", "then", "press", "this", "every", "only", "stopped", "solid", "breath",
        "shallow", "rainbow", "snake", "gradient", "step", "two",
    ]
    func englishWords(_ text: String) -> [String] {
        // Config keys (`voice.mode=hold`) are quoted, not translated.
        text.replacingOccurrences(of: #"[A-Za-z]+\.[A-Za-z]+=\w+"#, with: "", options: .regularExpression)
            .lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { english.contains($0) }
    }
    func check(_ what: String, _ text: String) {
        let found = englishWords(text)
        expect(found.isEmpty, "\(what) is still English (\(found.joined(separator: ", "))): \(text)")
    }

    test("spanish: no visible KeyAction label is left in English") {
        for action in KeyAction.allCases {
            check("\(action.rawValue).short", action.short)
            check("\(action.rawValue).long", action.long)
            for badge in SettingsEditing.badges(for: action) { check("badge of \(action.rawValue)", badge) }
        }
        for category in KeyAction.Category.allCases {
            check("category \(category.rawValue)", SettingsEditing.categoryTitle(category))
        }
        check("remote armed", SettingsEditing.remoteGesture(for: .armed))
        check("remote chord", SettingsEditing.remoteGesture(for: .chord))
    }

    test("spanish: no visible SessionState or LED effect label is left in English") {
        for state in SessionState.allCases {
            check("\(state.rawValue).label", state.label)
            check("\(state.rawValue).means", state.means)
        }
        for effect in LEDEffect.allCases {
            check("effect \(effect.rawValue)", effect.displayName)
        }
    }

    test("spanish: the check notices English") {
        expect(!englishWords("approve pending prompt").isEmpty, "the word list matches nothing")
        expect(englishWords("aprobar la solicitud pendiente (⏎) · Superset · cmux").isEmpty)
    }
}
