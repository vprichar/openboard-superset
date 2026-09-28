import Foundation
import OpenBoardKit

/**
 Per-app profiles (F2): the same control means different things depending on the app
 in front, and a profile only overrides what it names. Everything is pure — the front
 bundle and the preferences are arguments, so no app has to be running.
 */
func runProfileResolutionTests() {
    let superset = Preferences.supersetBundleID
    let terminal = "com.apple.Terminal"
    let prefs = Preferences.default

    test("with Superset in front, joystick up is its workspace chord") {
        let r = ProfileResolver.resolve(.joystick(.up), .tap, frontBundleID: superset, prefs: prefs)
        expectEqual(r.action, .shortcut)
        expectEqual(r.payloadKey, "JOY.up@\(superset)")
        expectEqual(r.source, .profile(superset))
        let chord = ProfileResolver.shortcut(forPayloadKey: r.payloadKey, prefs: prefs)
        expectEqual(chord?.keyCode, 126)
        expectEqual(chord?.modifiers, [.command, .option])
    }

    test("every joystick direction maps to Superset's ⌘⌥ arrows") {
        let codes: [Joystick.Direction: Int] = [.up: 126, .down: 125, .left: 123, .right: 124]
        for (direction, code) in codes {
            let r = ProfileResolver.resolve(.joystick(direction), .tap, frontBundleID: superset, prefs: prefs)
            let chord = ProfileResolver.shortcut(forPayloadKey: r.payloadKey, prefs: prefs)
            expectEqual(chord?.keyCode, code, "\(direction)")
            expectEqual(chord?.modifiers, [.command, .option], "\(direction)")
        }
    }

    test("with Terminal in front, joystick up is still an arrow") {
        let r = ProfileResolver.resolve(.joystick(.up), .tap, frontBundleID: terminal, prefs: prefs)
        expectEqual(r.action, .arrowUp)
        expectEqual(r.action?.rawValue, "arrow-up")
        expectEqual(r.payloadKey, "JOY.up")
        expectEqual(r.source, .base)
    }

    test("no app in front resolves the base binding") {
        let r = ProfileResolver.resolve(.joystick(.left), .tap, frontBundleID: nil, prefs: prefs)
        expectEqual(r.action, .tabBack)
        expectEqual(r.payloadKey, "JOY.left")
        expectEqual(r.source, .base)
    }

    test("a chord missing its @bundle key falls back to the base key") {
        var p = prefs
        let base = Shortcut(keyCode: 126, modifiers: [.control], key: "↑")
        p.shortcuts["JOY.up@\(superset)"] = nil
        p.shortcuts["JOY.up"] = base
        expectEqual(ProfileResolver.shortcut(forPayloadKey: "JOY.up@\(superset)", prefs: p), base)
        expectEqual(ProfileResolver.shortcut(forPayloadKey: "JOY.up", prefs: p), base)
    }

    test("the @bundle chord wins over the base one") {
        var p = prefs
        p.shortcuts["JOY.up"] = Shortcut(keyCode: 126, modifiers: [.control], key: "↑")
        let chord = ProfileResolver.shortcut(forPayloadKey: "JOY.up@\(superset)", prefs: p)
        expectEqual(chord?.modifiers, [.command, .option])
    }

    test("no chord anywhere is nil") {
        var p = prefs
        p.shortcuts = [:]
        expect(ProfileResolver.shortcut(forPayloadKey: "JOY.up@\(superset)", prefs: p) == nil)
        expect(ProfileResolver.shortcut(forPayloadKey: "JOY.up", prefs: p) == nil)
    }

    test("encoder long press opens Superset's palette, settings elsewhere") {
        let s = ProfileResolver.resolve(.encoderLong, .hold, frontBundleID: superset, prefs: prefs)
        expectEqual(s.action, .shortcut)
        expectEqual(s.payloadKey, "ENC.long@\(superset)")
        expectEqual(s.source, .profile(superset))
        let chord = ProfileResolver.shortcut(forPayloadKey: s.payloadKey, prefs: prefs)
        expectEqual(chord?.keyCode, 40)
        expectEqual(chord?.modifiers, [.command, .shift])

        let t = ProfileResolver.resolve(.encoderLong, .hold, frontBundleID: terminal, prefs: prefs)
        expectEqual(t.action?.rawValue, "ui")
        expectEqual(t.payloadKey, "ENC.long")
        expectEqual(t.source, .base)
    }

    test("holding the encoder click is the encoder long press") {
        let a = ProfileResolver.resolve(.encoderClick, .hold, frontBundleID: superset, prefs: prefs)
        let b = ProfileResolver.resolve(.encoderLong, .hold, frontBundleID: superset, prefs: prefs)
        expectEqual(a, b)
    }

    test("encoder click is not overridden by a profile") {
        let r = ProfileResolver.resolve(.encoderClick, .tap, frontBundleID: superset, prefs: prefs)
        expectEqual(r.action, .popover)
        expectEqual(r.source, .base)
    }

    test("a profile's explicit nil unbinds, absent inherits") {
        var p = prefs
        p.profiles[superset] = Preferences.AppProfile(joystick: [.up: KeyAction?.none])
        let up = ProfileResolver.resolve(.joystick(.up), .tap, frontBundleID: superset, prefs: p)
        expect(up.action == nil)
        expectEqual(up.source, .profile(superset))
        let down = ProfileResolver.resolve(.joystick(.down), .tap, frontBundleID: superset, prefs: p)
        expectEqual(down.action, .arrowDown)
        expectEqual(down.source, .base)
        // The chord key still carries the bundle, so a per-app chord applies to an
        // inherited `.shortcut` binding too.
        expectEqual(down.payloadKey, "JOY.down@\(superset)")
    }

    test("an app without a profile does not tag its payload key") {
        var p = prefs
        p.shortcuts["JOY.up@\(terminal)"] = Shortcut(keyCode: 1, key: "s")
        let r = ProfileResolver.resolve(.joystick(.up), .tap, frontBundleID: terminal, prefs: p)
        expectEqual(r.payloadKey, "JOY.up")
    }

    test("action taps come from the base map, holds from actionKeysLong") {
        let tap = ProfileResolver.resolve(.action("ACT07"), .tap, frontBundleID: superset, prefs: prefs)
        expectEqual(tap.action, prefs.keyActions["ACT07"])
        expectEqual(tap.source, .base)
        let hold = ProfileResolver.resolve(.action("ACT07"), .hold, frontBundleID: terminal, prefs: prefs)
        expectEqual(hold.action, .jumpOldestWaiting)
        expectEqual(hold.payloadKey, "ACT07.long")
        expectEqual(hold.source, .base)
    }

    test("BRANCH and NEW held open Superset's diff and quick create") {
        let branch = ProfileResolver.resolve(.action("ACT09"), .hold, frontBundleID: superset, prefs: prefs)
        expectEqual(branch.action, .shortcut)
        expectEqual(branch.payloadKey, "ACT09.long@\(superset)")
        expectEqual(ProfileResolver.shortcut(forPayloadKey: branch.payloadKey, prefs: prefs)?.keyCode, 37)
        let new = ProfileResolver.resolve(.action("ACT11"), .hold, frontBundleID: superset, prefs: prefs)
        expectEqual(ProfileResolver.shortcut(forPayloadKey: new.payloadKey, prefs: prefs)?.keyCode, 45)
        // Outside Superset there is no chord, so the held key does nothing.
        let elsewhere = ProfileResolver.resolve(.action("ACT09"), .hold, frontBundleID: terminal, prefs: prefs)
        expect(ProfileResolver.shortcut(forPayloadKey: elsewhere.payloadKey, prefs: prefs) == nil)
    }

    test("a profile's long press overrides the base one") {
        var p = prefs
        p.profiles[superset] = Preferences.AppProfile(actionKeysLong: ["ACT07": .settings, "ACT08": KeyAction?.none])
        let appr = ProfileResolver.resolve(.action("ACT07"), .hold, frontBundleID: superset, prefs: p)
        expectEqual(appr.action, .settings)
        expectEqual(appr.source, .profile(superset))
        let rej = ProfileResolver.resolve(.action("ACT08"), .hold, frontBundleID: superset, prefs: p)
        expect(rej.action == nil)
        expectEqual(rej.source, .profile(superset))
    }

    test("a binding absent from the preferences comes from the defaults") {
        var p = prefs
        p.actionKeysLong["ACT07"] = nil          // removes the key: absent, not unbound
        let r = ProfileResolver.resolve(.action("ACT07"), .hold, frontBundleID: nil, prefs: p)
        expectEqual(r.action, .jumpOldestWaiting)
        expectEqual(r.source, .default)
        p.actionKeys.removeValue(forKey: "ACT06")
        let tap = ProfileResolver.resolve(.action("ACT06"), .tap, frontBundleID: nil, prefs: p)
        expectEqual(tap.action, KeyAction.defaults["ACT06"])
        expectEqual(tap.source, .default)
    }

    test("an explicitly unassigned key stays unassigned, not defaulted") {
        // D1: NEW ships as null. It must not fall back to KeyAction.defaults.
        let r = ProfileResolver.resolve(.action("ACT11"), .tap, frontBundleID: nil, prefs: prefs)
        expect(r.action == nil)
        expectEqual(r.source, .base)
    }

    test("long-press keys follow the app in front") {
        expectEqual(
            ProfileResolver.longPressKeys(frontBundleID: superset, prefs: prefs),
            ["ACT06", "ACT07", "ACT08", "ACT09", "ACT11", "ACT12"]
        )
        var p = prefs
        p.profiles[superset] = Preferences.AppProfile(actionKeysLong: ["ACT09": KeyAction?.none, "ACT10": .settings])
        expectEqual(
            ProfileResolver.longPressKeys(frontBundleID: superset, prefs: p),
            ["ACT06", "ACT07", "ACT08", "ACT10", "ACT11", "ACT12"]
        )
        expectEqual(
            ProfileResolver.longPressKeys(frontBundleID: terminal, prefs: p),
            ["ACT06", "ACT07", "ACT08", "ACT09", "ACT11", "ACT12"]
        )
    }

    test("FAST held arms targeting by default, and its tap stays ⇧⇥") {
        // D4/D10: holding FAST arms the targeted mode; the ⇧⇥ tap is kept, and now
        // fires on the way up because the cap waits to tell a tap from a hold.
        for front in [superset, terminal] {
            expect(ProfileResolver.longPressKeys(frontBundleID: front, prefs: prefs).contains("ACT06"), front)
            expectEqual(ProfileResolver.resolve(.action("ACT06"), .hold, frontBundleID: front, prefs: prefs).action, .targetedArm)
            expectEqual(ProfileResolver.resolve(.action("ACT06"), .tap, frontBundleID: front, prefs: prefs).action, .shortcut)
        }
    }
}

/**
 Long press on the action caps. Time is injected; the one rule that matters most is
 that a key with no long binding fires on the way down, exactly as before — APPR and
 REJ must not get slower because holding them can now mean something.
 */
func runLongPressTests() {
    let t0 = Date()
    func at(_ ms: Int) -> Date { t0.addingTimeInterval(Double(ms) / 1000) }

    test("held 600 ms emits only the hold") {
        var tracker = ActionPressTracker(threshold: 0.5)
        expect(tracker.press("ACT07", hasLongBinding: true, now: t0) == nil)
        expect(tracker.poll(now: at(300)) == nil)
        expectEqual(tracker.poll(now: at(600)), .hold("ACT07"))
        expect(tracker.release("ACT07", now: at(650)) == nil, "no tap after a hold")
    }

    test("held 200 ms emits only the tap, on release") {
        var tracker = ActionPressTracker(threshold: 0.5)
        expect(tracker.press("ACT07", hasLongBinding: true, now: t0) == nil)
        expect(tracker.poll(now: at(200)) == nil)
        expectEqual(tracker.release("ACT07", now: at(200)), .tap("ACT07"))
        expect(tracker.poll(now: at(900)) == nil, "no hold after the release")
    }

    test("a key without a long binding taps on press, with no latency") {
        var tracker = ActionPressTracker(threshold: 0.5)
        expectEqual(tracker.press("ACT06", hasLongBinding: false, now: t0), .tap("ACT06"))
        expect(tracker.poll(now: at(2000)) == nil)
        expect(tracker.release("ACT06", now: at(2000)) == nil, "the tap is not repeated")
    }

    test("a release without a press is ignored") {
        var tracker = ActionPressTracker(threshold: 0.5)
        expect(tracker.release("ACT07", now: t0) == nil)
        expect(tracker.poll(now: at(1000)) == nil)
    }

    test("the hold is emitted once") {
        var tracker = ActionPressTracker(threshold: 0.5)
        _ = tracker.press("ACT08", hasLongBinding: true, now: t0)
        expectEqual(tracker.poll(now: at(500)), .hold("ACT08"))
        expect(tracker.poll(now: at(700)) == nil)
        expect(tracker.poll(now: at(3000)) == nil)
        expect(tracker.release("ACT08", now: at(3000)) == nil)
    }

    test("a release past the threshold that polling missed is the hold") {
        // A late poll must not turn a long press into a short one.
        var tracker = ActionPressTracker(threshold: 0.5)
        _ = tracker.press("ACT09", hasLongBinding: true, now: t0)
        expectEqual(tracker.release("ACT09", now: at(800)), .hold("ACT09"))
    }

    test("two keys held together are timed separately") {
        var tracker = ActionPressTracker(threshold: 0.5)
        _ = tracker.press("ACT07", hasLongBinding: true, now: t0)
        _ = tracker.press("ACT09", hasLongBinding: true, now: at(300))
        expectEqual(tracker.poll(now: at(550)), .hold("ACT07"))
        expect(tracker.poll(now: at(550)) == nil)
        expectEqual(tracker.release("ACT09", now: at(600)), .tap("ACT09"))
    }

    test("the next press starts a fresh timing") {
        var tracker = ActionPressTracker(threshold: 0.5)
        _ = tracker.press("ACT07", hasLongBinding: true, now: t0)
        _ = tracker.poll(now: at(600))
        _ = tracker.release("ACT07", now: at(700))
        _ = tracker.press("ACT07", hasLongBinding: true, now: at(1000))
        expectEqual(tracker.release("ACT07", now: at(1100)), .tap("ACT07"))
    }

    test("the threshold comes from actionLongPressMs") {
        var p = Preferences.default
        p.actionLongPressMs = 800
        var tracker = ActionPressTracker(prefs: p)
        _ = tracker.press("ACT07", hasLongBinding: true, now: t0)
        expect(tracker.poll(now: at(600)) == nil)
        expectEqual(tracker.poll(now: at(850)), .hold("ACT07"))
    }
}
