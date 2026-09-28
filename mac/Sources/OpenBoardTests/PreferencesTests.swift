import Foundation
import OpenBoardKit

/**
 The configuration file.

 It controls everything, so the failure modes matter more than the happy path: a
 *partial* document must merge rather than replace, an existing Node-era file must be
 picked up unchanged, and a hand edit must never be silently discarded.

 The fixture below is this machine's actual `config.json` — a rewrite reading a
 different path or schema would have ignored every setting in it.
 */
func runPreferencesTests() {
    test("preferences: customThemes default to none, and survive a save and load") {
        expect(Preferences.default.customThemes.isEmpty)
        expect(Preferences.merging([:]).customThemes.isEmpty, "absent means []")
        var p = Preferences.default
        let mine = CustomTheme(from: .claude, id: "custom-1", name: "Mío")
        p.customThemes = [mine]
        let data = try! JSONSerialization.data(withJSONObject: p.json)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        expectEqual(Preferences.merging(json).customThemes, [mine])
        // A broken entry is dropped; the good one survives.
        var raw = json
        raw["customThemes"] = [["id": "custom-x", "name": "roto"]] + (json["customThemes"] as! [Any])
        expectEqual(Preferences.merging(raw).customThemes, [mine])
    }

    func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-config-\(UUID().uuidString).json")
    }

    test("the file lives where the Node version put it") {
        // Anything else silently abandons every existing installation's settings.
        expectEqual(PreferencesStore.url(env: ["OPENBOARD_HOME": "/tmp/ob"]).path, "/tmp/ob/config.json")
    }

    test("defaults cover every state, action key and notification") {
        let defaults = Preferences.default
        for state in SessionState.allCases {
            expectEqual(defaults.appearance(for: state), state.defaultAppearance)
        }
        expectEqual(defaults.keyActions["ACT06"], .shortcut)
        expectEqual(defaults.notificationStates["permission_prompt"], .awaiting)
        // Means "sitting idle", not "needs you" — mapping it lights the attention
        // color with nothing to act on.
        expect(defaults.notificationStates["idle_prompt"] == nil)
        expectEqual(defaults.encoder.cw, "scroll-up")
        expectEqual(defaults.ambient.mode, "events")
        expectEqual(defaults.countdown.leadMs, 70)
        expectEqual(defaults.maxHoldSeconds, 60)
    }

    test("this machine's real config.json loads exactly as written") {
        let real = """
        {"notifications":{"idle_prompt":"idle"},
         "states":{"ended":{"effect":"off"},
                   "idle":{"color":16777215,"brightness":0.2,"effect":"solid","speed":0},
                   "working":{"effect":"shallow-breath"},
                   "awaiting":{"effect":"shallow-breath"}},
         "actionKeys":{"ACT08":"snippet","ACT09":"newtab","ACT10":"voice-tap","ACT11":null},
         "snippets":{"ACT08":"/start-ticket"},
         "encoder":{"cc":"scroll-down","cw":"scroll-up","click":"ui"},
         "ambient":{"mode":"events","completionLap":true,"questionLap":true},
         "countdown":{"leadMs":70,"introFlashSec":13.2,"introFlashColor":16723349}}
        """
        let json = try Harness.require(
            (try? JSONSerialization.jsonObject(with: Data(real.utf8))) as? [String: Any]
        )
        let prefs = Preferences.merging(json)

        // Colors are numbers on disk. 16777215 is white.
        expectEqual(prefs.appearance(for: .idle).color.hex, "#FFFFFF")
        expectEqual(prefs.appearance(for: .idle).brightness, 0.2)
        expectEqual(prefs.appearance(for: .working).effect, .shallowBreath)
        expectEqual(prefs.notificationStates["idle_prompt"], .idle)
        expectEqual(prefs.encoder.click, .settings)
        expectEqual(prefs.countdown.introFlashColor.hex, "#FF2D95")
    }

    test("a state override merges field by field, not wholesale") {
        // `{"working":{"effect":"shallow-breath"}}` must keep working's color and
        // brightness. Replacing the object instead turns a one-line override into a
        // half-configured state.
        let prefs = Preferences.merging(["states": ["working": ["effect": "shallow-breath"]]])
        let working = prefs.appearance(for: .working)
        expectEqual(working.effect, .shallowBreath)
        expectEqual(working.color.hex, "#0C47E9", "color must survive")
        expectEqual(working.brightness, 0.75, "brightness must survive")
        expectEqual(working.speed, 0.45, "speed must survive")
        // A state the document never mentions is untouched.
        expectEqual(prefs.appearance(for: .awaiting), SessionState.awaiting.defaultAppearance)
    }

    test("an explicitly unassigned key stays unassigned") {
        // `"ACT11": null` is a decision. Dropping it lets the key revert to its default
        // on the next launch, so clearing a binding would silently undo itself.
        let prefs = Preferences.merging(["actionKeys": ["ACT11": NSNull()]])
        expect(prefs.keyActions["ACT11"] == nil)
        expect(prefs.actionKeys["ACT11"] != nil, "the decision itself is recorded")
    }

    test("a shortcut without a key code is skipped, not fatal") {
        let prefs = Preferences.merging(["shortcuts": [
            "ACT08": ["keyCode": 49, "modifiers": ["control"], "key": "Space", "mode": "hold"],
            "ENC": ["modifiers": ["command"]],
        ]])
        expectEqual(
            prefs.shortcuts["ACT08"],
            Shortcut(keyCode: 49, modifiers: [.control], key: "Space", mode: .hold)
        )
        expect(prefs.shortcuts["ENC"] == nil, "an entry with nothing to send was kept")
    }

    test("a color may be a number or a hex string") {
        // Numbers are what Node wrote; hex is what a person types.
        expectEqual(
            Preferences.merging(["states": ["idle": ["color": 16711680]]])
                .appearance(for: .idle).color.hex, "#FF0000"
        )
        expectEqual(
            Preferences.merging(["states": ["idle": ["color": "#00FF00"]]])
                .appearance(for: .idle).color.hex, "#00FF00"
        )
        // Nonsense leaves the default rather than blanking the key.
        expectEqual(
            Preferences.merging(["states": ["idle": ["color": "puce"]]])
                .appearance(for: .idle).color.hex, "#2E4A6B"
        )
    }

    test("an empty or unknown document is still valid") {
        expectEqual(Preferences.merging([:]), Preferences.default)
        expectEqual(Preferences.merging(["somethingNew": 42]), Preferences.default)
        // A state name this version does not know is skipped, not fatal.
        expectEqual(
            Preferences.merging(["states": ["frobnicated": ["effect": "solid"]]]),
            Preferences.default
        )
    }

    test("a document round-trips through disk unchanged") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore()

        var prefs = store.load(url: url)
        prefs.setAppearance(
            Appearance(color: RGB(0x7B2FF7), effect: .breath, brightness: 0.42, speed: 0.3),
            for: .working
        )
        prefs.actionKeys["ACT06"] = KeyAction?.none
        prefs.events["Stop"] = false
        prefs.notifications["idle_prompt"] = SessionState.awaiting
        store.save(prefs, url: url, immediately: true)

        let reloaded = PreferencesStore().load(url: url)
        let working = reloaded.appearance(for: .working)
        expectEqual(working.color.hex, "#7B2FF7")
        expectEqual(working.effect, .breath)
        expectEqual(working.brightness, 0.42)
        expect(reloaded.keyActions["ACT06"] == nil, "unassigned did not survive")
        expectEqual(reloaded.events["Stop"], false)
        expectEqual(reloaded.notificationStates["idle_prompt"], .awaiting)
    }

    test("every single setting survives a save and reload") {
        /*
         The exhaustive one.

         The round trip above checks a handful of fields, which is the shape of test
         that passes while a whole section is missing from `json` or from `merging` —
         and a setting that does not round-trip is a control that appears to work and
         forgets. So this moves *every* field off its default, writes, reloads, and
         compares the whole document.

         Values are chosen inside the clamps the reader applies (gain 0.25–4,
         longPressMs 150–2000, threshold 0.1–0.95, brightness and speed 0–1). A value
         outside them would come back legitimately different and this would be
         asserting the clamp instead of the round trip.
         */
        var prefs = Preferences.default

        for state in SessionState.allCases {
            prefs.setAppearance(
                Appearance(color: RGB(0x123456), effect: .breath, brightness: 0.41, speed: 0.29),
                for: state
            )
        }
        prefs.actionKeys["ACT06"] = KeyAction?.none          // explicitly unassigned
        prefs.actionKeys["ACT07"] = .snippet
        prefs.snippets["ACT07"] = "/review"
        prefs.shortcuts["ACT08"] = Shortcut(
            keyCode: 49, modifiers: [.control, .option], key: "Space", mode: .hold
        )
        prefs.shortcuts["JOY.up"] = Shortcut(keyCode: 16, modifiers: [.command], key: "Y")
        prefs.caps["ACT07"] = "MAGIC"
        prefs.events["Stop"] = false
        prefs.notifications["idle_prompt"] = SessionState.awaiting
        prefs.notifications["permission_prompt"] = SessionState?.none

        prefs.encoder.cw = "scroll-down"
        prefs.encoder.cc = "scroll-up"
        prefs.encoder.click = .settings
        prefs.encoder.longPress = nil
        prefs.encoder.longPressMs = 700

        prefs.joystick.up = .tabForward
        prefs.joystick.down = nil
        prefs.joystick.left = .arrowUp
        prefs.joystick.right = .arrowDown
        prefs.joystick.northAngle = 0.125
        prefs.joystick.clockwise = false
        prefs.joystick.threshold = 0.65

        prefs.ambient.mode = "fixed"
        prefs.ambient.completionLap = false
        prefs.ambient.questionLap = false
        prefs.ambient.errorPulse = false
        prefs.ambient.fixed = Appearance(
            color: RGB(0x00C8D7), effect: .shallowBreath, brightness: 0.22, speed: 0.11
        )

        prefs.countdown.leadMs = 95
        prefs.countdown.introFlashSec = 9.5
        prefs.countdown.introFlashColor = RGB(0xE81CA8)
        prefs.countdown.introEnabled = false
        prefs.countdown.introColorKeys = RGB(0x1B2A6B)
        prefs.countdown.introBrightness = 0.44
        prefs.countdown.introTrail = 0.33
        prefs.countdown.gain = 1.55
        prefs.countdown.mediaDir = "/tmp/openboard-media"

        prefs.entrypoints = ["cli", "vscode"]
        prefs.scrollLines = 7
        prefs.staleHours = 24
        prefs.doneDecaySeconds = 120
        prefs.holdAttention = false
        prefs.maxHoldSeconds = 45
        prefs.padScope = .all

        expect(prefs != Preferences.default, "the fixture never left the defaults")

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        PreferencesStore().save(prefs, url: url, immediately: true)
        let reloaded = PreferencesStore().load(url: url)

        expectEqual(reloaded, prefs)
    }

    test("the pad follows the focused workspace by default") {
        // The point of the feature; `all` is the way back to the old board.
        expectEqual(Preferences.default.padScope, .focusedWorkspace)
        expectEqual(Preferences.merging([:]).padScope, .focusedWorkspace)
        // An unknown value is ignored rather than silently meaning "all".
        expectEqual(Preferences.merging(["padScope": "sideways"]).padScope, .focusedWorkspace)
    }

    test("the pad scope survives a save and reload") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var prefs = Preferences.default
        prefs.padScope = .all
        PreferencesStore().save(prefs, url: url, immediately: true)
        expectEqual(PreferencesStore().load(url: url).padScope, .all)
        expectEqual(prefs.json["padScope"] as? String, "all")
    }

    test("the file is written on first load, and is not world-readable") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = PreferencesStore().load(url: url)
        expect(FileManager.default.fileExists(atPath: url.path), "no file was created")

        // 0600, like the Node version and the calibration record beside it. An atomic
        // write replaces the inode, so the mode has to be reapplied every save.
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }?.intValue ?? 0
        expectEqual(mode & 0o077, 0, "group or other can read it")
    }

    test("a corrupt file falls back rather than stopping the app") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ this is not json".utf8).write(to: url)

        let prefs = PreferencesStore().load(url: url)
        expectEqual(prefs.appearance(for: .idle).color.hex, "#2E4A6B")
    }

    test("writes are atomic") {
        // A crash mid-write must not truncate the file that controls everything.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore()
        var prefs = store.load(url: url)

        for level in stride(from: 0.0, through: 1.0, by: 0.1) {
            prefs.setAppearance(
                Appearance(color: RGB(0x0C47E9), effect: .breath, brightness: level, speed: 0),
                for: .working
            )
            store.save(prefs, url: url, immediately: true)
        }

        let data = try Harness.require(try? Data(contentsOf: url))
        expect(
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil,
            "the file on disk is not valid JSON"
        )
    }

    test("the daylight lift is fixed, but still readable from disk") {
        // The slider is gone: the answer is "bright enough for the room you are in",
        // which is one decision per room rather than per viewing. 2 is what this pad
        // was tuned to, and it is what a document saying nothing gets.
        expectEqual(Preferences.default.countdown.gain, 2)
        expectEqual(Preferences.merging(["countdown": ["leadMs": 70]]).countdown.gain, 2)

        // Still honoured for a genuinely darker or brighter room, and still bounded:
        // a hand-edited 0 would blank the show and a 20 would flatten it.
        expectEqual(Preferences.merging(["countdown": ["gain": 1.5]]).countdown.gain, 1.5)
        expectEqual(Preferences.merging(["countdown": ["gain": 20.0]]).countdown.gain, 4)
        expectEqual(Preferences.merging(["countdown": ["gain": 0.01]]).countdown.gain, 0.25)
        // Nonsense leaves the default rather than blanking the pad.
        expectEqual(Preferences.merging(["countdown": ["gain": 0.0]]).countdown.gain, 2)
        expectEqual(Preferences.merging(["countdown": ["gain": -3.0]]).countdown.gain, 2)

        var next = Preferences.default
        next.countdown.gain = 1.75
        expectEqual(Preferences.merging(next.json).countdown.gain, 1.75)
    }

    test("timings come from the document, not from constants") {
        let prefs = Preferences.merging([
            "staleHours": 3, "doneDecaySeconds": 10,
            "holdAttention": false, "maxHoldSeconds": 5, "scrollLines": 7,
        ])
        expectEqual(prefs.staleHours, 3)
        expectEqual(prefs.staleInterval, 3 * 3600)
        expectEqual(prefs.doneDecaySeconds, 10)
        expectEqual(prefs.holdAttention, false)
        expectEqual(prefs.maxHoldSeconds, 5)
        expectEqual(prefs.scrollLines, 7)
    }

    test("a configured stale window actually reclaims") {
        // The registry used a hardcoded 12h. Wiring the value through is the point.
        var registry = SessionRegistry()
        registry.staleInterval = 60
        let start = Date()
        _ = registry.claim(sessionID: "a", pid: 1, now: start, isAlive: { _ in true })
        let entry = try Harness.require(registry.entry(forSession: "a"))

        expect(!registry.isReclaimable(entry, now: start, isAlive: { _ in true }))
        expect(
            registry.isReclaimable(entry, now: start.addingTimeInterval(120), isAlive: { _ in true }),
            "past the configured window it should be reclaimable"
        )
    }

    test("encoder direction is configurable, and the two ends stay opposite") {
        // A dial bound to the same direction at both ends scrolls one way whichever way
        // it is turned, which reads as broken hardware rather than as a setting.
        var encoder = Preferences.Encoder()
        expect(encoder.clockwiseScrollsUp, "the default matches macOS natural scrolling")

        encoder.clockwiseScrollsUp = false
        expectEqual(encoder.cw, "scroll-down")
        expectEqual(encoder.cc, "scroll-up")

        encoder.clockwiseScrollsUp = true
        expectEqual(encoder.cw, "scroll-up")
        expectEqual(encoder.cc, "scroll-down")

        // A hand-written document that sets both the same way is read as its cw value
        // rather than obeyed into a one-way dial.
        let both = Preferences.merging(["encoder": ["cw": "scroll-down", "cc": "scroll-down"]])
        expect(!both.encoder.clockwiseScrollsUp)
    }

    test("an inverted encoder survives a relaunch") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore()

        var prefs = store.load(url: url)
        prefs.encoder.clockwiseScrollsUp = false
        prefs.scrollLines = 8
        store.save(prefs, url: url, immediately: true)

        let reloaded = PreferencesStore().load(url: url)
        expect(!reloaded.encoder.clockwiseScrollsUp)
        expectEqual(reloaded.scrollLines, 8)
    }

    test("hex parsing accepts what a person would type") {
        expectEqual(RGB(hex: "#7B2FF7")?.hex, "#7B2FF7")
        expectEqual(RGB(hex: "7b2ff7")?.hex, "#7B2FF7")
        expectEqual(RGB(hex: "  #7B2FF7  ")?.hex, "#7B2FF7")
        expect(RGB(hex: "#7B2FF") == nil)
        expect(RGB(hex: "purple") == nil)
        expect(RGB(hex: "") == nil)
    }

    // MARK: - Superset groups (Plan §2.5/§2.6)

    test("superset/profiles/actionKeysLong/confirm/targeted/launch survive a json round-trip") {
        /*
         Every new field moved off its default, written, reloaded, compared whole — the
         same shape as "every single setting survives", for the groups that test predates.
         A group missing from `json` or from `merging` is a control that forgets.
        */
        var prefs = Preferences.default

        prefs.superset.hostClient = .off
        prefs.superset.orgID = "55555555-test"
        prefs.superset.testedVersion = "1.31.0"
        prefs.superset.onVersionMismatch = .full
        prefs.superset.events = false
        prefs.superset.startDebounceMs = 350
        prefs.superset.dedupeWindowMs = 900
        prefs.superset.padWriteCoalesceMs = 120
        prefs.superset.reconcileOnLaunch = false

        prefs.profiles["com.superset.desktop"]?.joystick[.up] = .arrowUp
        prefs.profiles["com.superset.desktop"]?.joystick[.left] = KeyAction?.none
        prefs.profiles["com.superset.desktop"]?.encoderLongPress = KeyAction??.some(nil)
        prefs.profiles["com.googlecode.iterm2"] = Preferences.AppProfile(
            joystick: [.down: .nextSession],
            encoderLongPress: .some(.popover),
            actionKeysLong: ["ACT09": .prevSession, "ACT10": KeyAction?.none]
        )

        prefs.actionKeysLong["ACT07"] = KeyAction?.none
        prefs.actionKeysLong["ACT10"] = .countdown
        prefs.actionLongPressMs = 700

        prefs.confirm.windowMs = 4500
        prefs.confirm.color = RGB(0x33AA77)
        prefs.confirm.effect = .shallowBreath
        prefs.confirm.brightness = 0.55

        prefs.targeted.mode = .chord
        prefs.targeted.windowMs = 2500
        prefs.targeted.snapshotLines = 40
        prefs.targeted.maxSendBytes = 2048
        prefs.targeted.defaultSnippet = "continue"
        prefs.targeted.snippets = ["AG+ACT06": "sigue", "review": "/review"]

        prefs.launch.newAgent = "3f1c2a9e-preset"
        prefs.launch.handoffAgent = "claude"
        prefs.launch.handoffContextChars = 8000
        prefs.launch.createCooldownMs = 3500

        prefs.snippetsAllowDangerous = true

        expect(prefs != Preferences.default, "the fixture never left the defaults")

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        PreferencesStore().save(prefs, url: url, immediately: true)
        let reloaded = PreferencesStore().load(url: url)

        expectEqual(reloaded.superset, prefs.superset)
        expectEqual(reloaded.profiles, prefs.profiles)
        expectEqual(reloaded.actionKeysLong, prefs.actionKeysLong)
        expectEqual(reloaded.confirm, prefs.confirm)
        expectEqual(reloaded.targeted, prefs.targeted)
        expectEqual(reloaded.launch, prefs.launch)
        expectEqual(reloaded, prefs)
    }

    test("an optional left unset survives as unset, not as a value") {
        // `orgId: null` means "the only org on disk", and `handoffContextChars: null`
        // means "not verified yet" — neither may come back as an empty string or a 0.
        var prefs = Preferences.default
        prefs.superset.orgID = nil
        prefs.launch.handoffContextChars = nil
        let json = prefs.json
        expect((json["superset"] as? [String: Any])?["orgId"] is NSNull, "orgId must be written as null")
        let reloaded = Preferences.merging(json)
        expect(reloaded.superset.orgID == nil)
        expect(reloaded.launch.handoffContextChars == nil)
    }

    test("a removed built-in profile stays removed") {
        // The Superset profile ships as a default. Without a tombstone, deleting it in
        // the settings window would last exactly until the next launch.
        var prefs = Preferences.default
        prefs.profiles["com.superset.desktop"] = nil
        prefs.shortcuts["JOY.up@com.superset.desktop"] = nil
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        PreferencesStore().save(prefs, url: url, immediately: true)
        let reloaded = PreferencesStore().load(url: url)
        expect(reloaded.profiles["com.superset.desktop"] == nil, "profile came back")
        expect(reloaded.shortcuts["JOY.up@com.superset.desktop"] == nil, "shortcut came back")
        expectEqual(reloaded, prefs)
    }

    test("states.unconfirmed survives a save") {
        // D11: not a SessionState case, but its look lives beside the others. The
        // reader drops unknown state names, so this is the one it must not drop.
        var prefs = Preferences.default
        prefs.states["unconfirmed"] = Appearance(
            color: RGB(0x445566), effect: .breath, brightness: 0.25, speed: 0.1
        )
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        PreferencesStore().save(prefs, url: url, immediately: true)
        let reloaded = PreferencesStore().load(url: url)
        expectEqual(reloaded.states["unconfirmed"], prefs.states["unconfirmed"])
        expectEqual(reloaded.unconfirmedAppearance, prefs.states["unconfirmed"])
        // A partial override merges like any state: only the effect changes.
        let partial = Preferences.merging(["states": ["unconfirmed": ["effect": "breath"]]])
        expectEqual(partial.unconfirmedAppearance.effect, .breath)
        expectEqual(partial.unconfirmedAppearance.color, RGB(0x2E4A6B))
        // Still no room for invented states.
        expect(Preferences.merging(["states": ["bogus": ["effect": "breath"]]]).states["bogus"] == nil)
    }

    test("a profile for an unknown bundle is kept verbatim") {
        // No list of known apps: whatever bundle id the document names is a profile,
        // with its explicit nulls intact.
        let document: [String: Any] = [
            "profiles": [
                "org.example.NeverHeardOf": [
                    "joystick": ["up": "next-session", "right": NSNull()],
                    "encoder": ["longPress": NSNull()],
                    "actionKeysLong": ["ACT09": "shortcut", "ACT11": NSNull()],
                ],
            ],
        ]
        let prefs = Preferences.merging(document)
        let profile = try Harness.require(prefs.profiles["org.example.NeverHeardOf"])
        expectEqual(profile.joystick[.up], .some(.nextSession))
        expect(profile.joystick[.right] == .some(nil), "explicit null became inherit")
        expect(profile.joystick[.down] == nil, "absent became a value")
        expect(profile.encoderLongPress == .some(nil), "explicit null encoder became inherit")
        expectEqual(profile.actionKeysLong["ACT09"], .some(.shortcut))
        expect(profile.actionKeysLong["ACT11"] == .some(nil))

        let written = try Harness.require(
            (prefs.json["profiles"] as? [String: Any])?["org.example.NeverHeardOf"] as? [String: Any]
        )
        let stick = try Harness.require(written["joystick"] as? [String: Any])
        expectEqual(stick["up"] as? String, "next-session")
        expect(stick["right"] is NSNull)
        expect(stick["down"] == nil, "an inherited direction must stay absent")
        expectEqual(Preferences.merging(prefs.json).profiles, prefs.profiles)
    }

    test("defaults equal Plan §2.5/§2.6") {
        let d = Preferences.default

        // superset
        expectEqual(d.superset.hostClient, .auto)
        expect(d.superset.orgID == nil)
        expectEqual(d.superset.testedVersion, "1.30.0")
        expectEqual(d.superset.onVersionMismatch, .readOnly)          // D8
        expectEqual(d.superset.onVersionMismatch.rawValue, "read-only")
        expectEqual(d.superset.events, true)
        expectEqual(d.superset.startDebounceMs, 200)
        expectEqual(d.superset.dedupeWindowMs, 1500)
        expectEqual(d.superset.padWriteCoalesceMs, 90)
        expectEqual(d.superset.reconcileOnLaunch, true)

        // actionKeysLong + threshold (D7: APPR held = jump to the oldest waiting)
        expectEqual(d.actionLongPressMs, 500)
        expectEqual(d.actionKeysLong["ACT07"], .some(.jumpOldestWaiting))
        expectEqual(d.actionKeysLong["ACT08"], .some(.interruptFocused))
        expectEqual(d.actionKeysLong["ACT09"], .some(.shortcut))
        expectEqual(d.actionKeysLong["ACT11"], .some(.shortcut))
        // D4/D10: FAST held arms the targeted mode.
        expectEqual(d.actionKeysLong["ACT06"], .some(.targetedArm))
        // F8: CODEX held hands the focused terminal off to Codex; its tap is ⎋×2.
        expectEqual(d.actionKeysLong["ACT12"], .some(.supersetHandoff))
        expectEqual(d.actionKeysLong.count, 6)

        // D1: NEW and CODEX ship unassigned; `enter` is still offered, just not bound.
        expect(d.actionKeys["ACT11"] == .some(nil), "ACT11 must be explicitly unassigned")
        expect(d.actionKeys["ACT12"] == .some(nil), "ACT12 must be explicitly unassigned")
        expect(!d.keyActions.values.contains(.enter), "enter bound by default")
        expect(KeyAction.allCases.contains(.enter))

        // The Superset profile, and its chords under `@bundle`.
        let superset = try Harness.require(d.profiles["com.superset.desktop"])
        for direction in Joystick.Direction.allCases {
            expectEqual(superset.joystick[direction], .some(.shortcut), direction.rawValue)
        }
        expect(superset.encoderLongPress == .some(.shortcut))
        expectEqual(d.profiles.count, 1)
        let chords: [(String, Int, Set<Shortcut.Modifier>)] = [
            ("JOY.up@com.superset.desktop", 126, [.command, .option]),
            ("JOY.down@com.superset.desktop", 125, [.command, .option]),
            ("JOY.left@com.superset.desktop", 123, [.command, .option]),
            ("JOY.right@com.superset.desktop", 124, [.command, .option]),
            ("ENC.long@com.superset.desktop", 40, [.command, .shift]),
            ("ACT09.long@com.superset.desktop", 37, [.command, .shift]),
            ("ACT11.long@com.superset.desktop", 45, [.command, .shift]),
        ]
        for (key, code, modifiers) in chords {
            let chord = try Harness.require(d.shortcuts[key], "missing \(key)")
            expectEqual(chord.keyCode, code, key)
            expectEqual(chord.modifiers, modifiers, key)
            expectEqual(chord.mode, .tap, key)
        }

        // confirm (D3: white, breathing)
        expectEqual(d.confirm.windowMs, 3000)
        expectEqual(d.confirm.color, RGB(0xFFFFFF))
        expectEqual(d.confirm.effect, .breath)
        expectEqual(d.confirm.brightness, 0.8)

        // targeted (D10: armed)
        expectEqual(d.targeted.mode, .armed)
        expectEqual(d.targeted.snapshotLines, 20)
        expectEqual(d.targeted.requireStopForSend, true)
        expectEqual(d.targeted.maxSendBytes, 4096)
        expectEqual(d.targeted.defaultSnippet, "sigue")
        expectEqual(d.targeted.snippets, [:])

        // launch (D2: debounce only)
        expectEqual(d.launch.newAgent, "claude")
        expectEqual(d.launch.handoffAgent, "codex")
        expect(d.launch.handoffContextChars == nil, "unverified, so unset")
        expectEqual(d.launch.createCooldownMs, 2000)

        // states.unconfirmed (Plan §2.4)
        expectEqual(
            d.states["unconfirmed"],
            Appearance(color: RGB(0x2E4A6B), effect: .solid, brightness: 0.3, speed: 0)
        )

        // An empty document is the defaults, so a first launch writes exactly these.
        expectEqual(Preferences.merging([:]), d)
    }

    test("default taps are the clone's layout (FAST APPR REJ BRANCH MIC NEW CODEX)") {
        let d = Preferences.default
        expectEqual(d.actionKeys["ACT06"], .some(.shortcut))
        expectEqual(d.actionKeys["ACT07"], .some(.approve))
        expectEqual(d.actionKeys["ACT08"], .some(.reject))
        expectEqual(d.actionKeys["ACT09"], .some(.nextSession))
        expectEqual(d.actionKeys["ACT10"], .some(.voiceTalk))
        expect(d.actionKeys["ACT11"] == .some(nil), "NEW ships unassigned")
        expect(d.actionKeys["ACT12"] == .some(nil), "CODEX ships unassigned")
        // FAST is ⇧⇥, a tap: Claude Code's permission-mode toggle.
        let fast = try Harness.require(d.shortcuts["ACT06"], "FAST has no chord")
        expectEqual(fast.keyCode, 48)
        expectEqual(fast.modifiers, [.shift])
        expectEqual(fast.mode, .tap)
        // No snippet is typed by any default key, so none ships.
        expect(!d.keyActions.values.contains(.snippet), "a snippet key by default")
        expect(d.snippets.isEmpty, "a default snippet with no key to type it")
        // What the first launch writes is exactly this.
        expectEqual(Preferences.merging([:]).actionKeys, d.actionKeys)
    }

    test("the long press of APPR and REJ sits on the cap whose tap is approve / reject") {
        // The long bindings were written for the clone's caps. If the taps drift back
        // to the upstream layout, "hold APPR" lands on a cap that rejects.
        let d = Preferences.default
        let approveCap = try Harness.require(d.keyActions.first { $0.value == .approve }?.key)
        let rejectCap = try Harness.require(d.keyActions.first { $0.value == .reject }?.key)
        expectEqual(d.actionKeysLong[approveCap], .some(.jumpOldestWaiting))
        expectEqual(d.actionKeysLong[rejectCap], .some(.interruptFocused))
        let fastCap = try Harness.require(d.shortcuts["ACT06"] != nil ? "ACT06" : nil)
        expectEqual(d.actionKeys[fastCap], .some(.shortcut))
        expectEqual(d.actionKeysLong[fastCap], .some(.targetedArm))
    }

    test("a chord's repeat survives the whole config round trip") {
        var prefs = Preferences.default
        prefs.shortcuts["ACT12"] = Shortcut(keyCode: 53, key: "⎋", mode: .tap, repeats: 2)
        let data = try JSONSerialization.data(withJSONObject: prefs.json)
        let json = try Harness.require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reloaded = Preferences.merging(json)
        expectEqual(reloaded.shortcuts["ACT12"]?.repeats, 2)
        // Written as `repeat`, the name the user's config uses.
        let stored = try Harness.require((json["shortcuts"] as? [String: Any])?["ACT12"] as? [String: Any])
        expectEqual(stored["repeat"] as? Int, 2)
        // A hand-edited `"repeat": 2` in config.json is read.
        let hand = Preferences.merging(["shortcuts": ["ACT12": ["keyCode": 53, "key": "⎋", "mode": "tap", "repeat": 2]]])
        expectEqual(hand.shortcuts["ACT12"]?.repeats, 2)
    }

    test("snippetsAllowDangerous defaults to false") {
        expectEqual(Preferences.default.snippetsAllowDangerous, false)
        expectEqual(Preferences.merging([:]).snippetsAllowDangerous, false)
        // Only a real boolean turns it on — a string "true" typed by hand does not.
        expectEqual(Preferences.merging(["snippetsAllowDangerous": "true"]).snippetsAllowDangerous, false)
        expectEqual(Preferences.merging(["snippetsAllowDangerous": true]).snippetsAllowDangerous, true)
    }
}

/**
 Event gating — the Events pane was decorative until this.

 `EventMapper.state` accepted `enabledEvents:` and `notifications:` and the caller
 passed neither, so every toggle in the pane changed nothing.
 */
func runEventGatingTests() {
    test("muting an event stops it repainting") {
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: [:]), .done)
        expect(EventMapper.state(for: "Stop", enabledEvents: ["Stop": false]) == nil)
        // Absent means enabled: muting is opt-in, so an untouched document behaves
        // exactly like the defaults.
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: ["SessionStart": false]), .done)
    }

    test("a configured notification mapping is honoured") {
        // This machine maps idle_prompt to idle rather than leaving it unmapped.
        expectEqual(
            EventMapper.state(
                for: "Notification", matcher: "idle_prompt", notifications: ["idle_prompt": .idle]
            ),
            .idle
        )
        expect(EventMapper.state(for: "Notification", matcher: "idle_prompt") == nil)
    }

    test("mapping idle_prompt to awaiting makes an idle prompt orange") {
        // The plan's acceptance test for gap 2.
        let state = EventMapper.state(
            for: "Notification", matcher: "idle_prompt", notifications: ["idle_prompt": .awaiting]
        )
        expectEqual(state, .awaiting)
        expect(state?.isAttention == true)
    }

    test("an unmapped subtype still repaints nothing") {
        // agent_completed and auth_success are about the app, not about a key.
        expect(
            EventMapper.state(
                for: "Notification", matcher: "agent_completed",
                notifications: EventMapper.defaultNotifications
            ) == nil
        )
    }
}

/**
 What the tool-use events actually mean.

 The Events pane described `PostToolUseFailure` as "sets error" for as long as it has
 existed, and that was never what it does. Pinned here so the copy and the behaviour
 cannot drift apart again.
 */
func runToolEventTests() {
    test("a failed tool call is not a failed session") {
        // Claude retries and the turn carries on. Mapping this to error would flash the
        // key red on every retry, which teaches you to ignore red.
        expectEqual(EventMapper.state(for: "PostToolUseFailure"), .working)
        expectEqual(EventMapper.state(for: "PostToolUse"), .working)
    }

    test("both tool events clear a stuck prompt") {
        // Their real job: a permission prompt answered outside OpenBoard leaves the key
        // orange, and the next tool call is the proof it was answered.
        expect(EventMapper.clearsAttention.contains("PostToolUse"))
        expect(EventMapper.clearsAttention.contains("PostToolUseFailure"))
    }

    test("the turn failing is what sets error") {
        // The distinction the pane copy blurred.
        expectEqual(EventMapper.state(for: "StopFailure"), .error)
        expectEqual(EventMapper.state(for: "Stop"), .done)
        expect(!EventMapper.clearsAttention.contains("StopFailure"))
    }
}
