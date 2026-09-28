import Foundation
import OpenBoardKit

/*
 A settings edit reaches the pad without a restart.

 `applyPreferences()` rebuilds everything the key dispatch consults from one pure
 function, `ControlMap.make`. These pin that an edit made through `SettingsEditing`
 changes that map — and that undoing the edit gives back exactly the map from before,
 so nothing from the previous binding survives in the dispatch.
 */
func runLiveApplyTests() {
    let superset = Preferences.supersetBundleID
    let terminal = "com.apple.Terminal"
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    test("live apply: the default map is the clone's layout") {
        let map = ControlMap.make(prefs: .default)
        expectEqual(map.taps["ACT06"], .shortcut)
        expectEqual(map.taps["ACT07"], .approve)
        expectEqual(map.taps["ACT08"], .reject)
        expectEqual(map.taps["ACT09"], .nextSession)
        expectEqual(map.taps["ACT10"], .voiceTalk)
        expect(map.taps["ACT11"] == nil, "NEW ships unassigned")
        expect(map.taps["ACT12"] == nil, "CODEX ships unassigned")
        expectEqual(map.hold("ACT06")?.action, .targetedArm)
        expectEqual(map.hold("ACT07")?.action, .jumpOldestWaiting)
        expectEqual(map.hold("ACT08")?.action, .interruptFocused)
        expect(map.hold("ACT10") == nil, "MIC has no long press")
        expect(!map.longPressKeys.contains("ACT10"), "MIC must fire on the way down")
        expectEqual(map.longPressThreshold, 0.5)
    }

    test("live apply: the app in front picks the profile") {
        let front = ControlMap.make(prefs: .default, frontBundleID: superset)
        let up = try Harness.require(front.joystick[.up])
        expectEqual(up.action, .shortcut)
        expectEqual(up.payloadKey, "JOY.up@\(superset)")
        expectEqual(up.source, .profile(superset))
        expectEqual(front.encoderLong.payloadKey, "ENC.long@\(superset)")
        expectEqual(front.encoderLong.action, .shortcut)
        expectEqual(front.hold("ACT09")?.payloadKey, "ACT09.long@\(superset)")

        let away = ControlMap.make(prefs: .default, frontBundleID: terminal)
        expectEqual(away.joystick[.up]?.action, .arrowUp)
        expectEqual(away.joystick[.up]?.payloadKey, "JOY.up")
        expectEqual(away.encoderLong.action, .settings)
        expectEqual(away, ControlMap.make(prefs: .default, frontBundleID: nil), "no profile: same as no app")
    }

    test("live apply: a hold set in the settings changes the map, and undoing it leaves nothing behind") {
        let before = ControlMap.make(prefs: .default)
        var p = Preferences.default
        SettingsEditing.setAction(.popover, for: .action("ACT10"), gesture: .hold, profile: nil, in: &p)
        let edited = ControlMap.make(prefs: p)
        expectEqual(edited.hold("ACT10")?.action, .popover)
        expect(edited.longPressKeys.contains("ACT10"))

        SettingsEditing.setAction(nil, for: .action("ACT10"), gesture: .hold, profile: nil, in: &p)
        expectEqual(ControlMap.make(prefs: p), before)
    }

    test("live apply: a tap rebind shows up at once, and a cleared tap is really gone") {
        var p = Preferences.default
        SettingsEditing.setAction(.popover, for: .action("ACT12"), gesture: .tap, profile: nil, in: &p)
        expectEqual(ControlMap.make(prefs: p).taps["ACT12"], .popover)
        SettingsEditing.setAction(nil, for: .action("ACT12"), gesture: .tap, profile: nil, in: &p)
        expect(ControlMap.make(prefs: p).taps["ACT12"] == nil)
        expectEqual(ControlMap.make(prefs: p), ControlMap.make(prefs: .default))
    }

    test("live apply: a profile added and removed leaves the map as it was") {
        let bundle = "com.example.editor"
        let before = ControlMap.make(prefs: .default, frontBundleID: bundle)
        var p = Preferences.default
        SettingsEditing.addProfile(bundleID: bundle, in: &p)
        SettingsEditing.setAction(.popover, for: .joystick(.left), gesture: .tap, profile: bundle, in: &p)
        let edited = ControlMap.make(prefs: p, frontBundleID: bundle)
        expectEqual(edited.joystick[.left]?.action, .popover)
        expectEqual(edited.joystick[.left]?.source, .profile(bundle))
        // Another app in front does not see it.
        expectEqual(ControlMap.make(prefs: p, frontBundleID: terminal).joystick[.left]?.action, .tabBack)

        SettingsEditing.removeProfile(bundleID: bundle, in: &p)
        expectEqual(ControlMap.make(prefs: p, frontBundleID: bundle), before)
    }

    test("live apply: the hold threshold follows the slider, and the timer waits past it") {
        var p = Preferences.default
        SettingsEditing.setLongPressMs(800, in: &p)
        let map = ControlMap.make(prefs: p)
        expectEqual(map.longPressThreshold, 0.8)
        // The controller's timer must never poll a hair *before* the tracker's
        // threshold — floating point would then turn a hold into a late tap.
        expect(map.holdPollDelay > map.longPressThreshold)
        expect(map.holdPollDelay < map.longPressThreshold + 0.1)
    }

    test("live apply: configuring the dispatcher replaces every binding and forgets the old debounce") {
        var dispatcher = KeyDispatcher()
        ControlMap.make(prefs: .default).configure(&dispatcher)
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT07", action: .down), now: t0),
            .actionPressed(key: "ACT07")
        )

        // APPR's hold removed: it fires on the way down again, and the press a moment
        // ago does not swallow this one.
        var p = Preferences.default
        SettingsEditing.setAction(nil, for: .action("ACT07"), gesture: .hold, profile: nil, in: &p)
        ControlMap.make(prefs: p).configure(&dispatcher)
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT07", action: .down), now: t0.addingTimeInterval(0.1)),
            .action(.approve, key: "ACT07")
        )
        // MIC never waits for a threshold.
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT10", action: .down), now: t0),
            .action(.voiceTalk, key: "ACT10")
        )
    }

    test("live apply: the app in front changes which caps wait for a hold") {
        var p = Preferences.default
        SettingsEditing.addProfile(bundleID: terminal, in: &p)
        SettingsEditing.setAction(nil, for: .action("ACT09"), gesture: .hold, profile: terminal, in: &p)
        expect(ControlMap.make(prefs: p, frontBundleID: superset).longPressKeys.contains("ACT09"))
        let there = ControlMap.make(prefs: p, frontBundleID: terminal)
        expect(!there.longPressKeys.contains("ACT09"), "unbound in that app: tap on the way down")
        expect(there.hold("ACT09") == nil)
    }
}
