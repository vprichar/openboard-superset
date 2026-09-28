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

    // Question mode: while a session the pad is showing waits on a prompt, the stick
    // answers it — plain arrows — instead of switching Superset's tabs and workspaces.
    let alive: (Int?) -> Bool = { _ in true }
    let mine = "11111111-1111-4111-8111-111111111111"
    let theirs = "22222222-2222-4222-8222-222222222222"

    func board(_ sessions: [(id: String, workspace: String)]) -> SessionRegistry {
        var registry = SessionRegistry()
        for (index, session) in sessions.enumerated() {
            _ = registry.claim(sessionID: session.id, cwd: nil, pid: index + 1, state: .working, isAlive: alive)
            registry.enrich(sessionID: session.id, supersetWorkspaceID: session.workspace)
        }
        return registry
    }

    func questionMode(_ registry: SessionRegistry, workspace: String? = nil) -> Bool {
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: workspace ?? mine))
        return QuestionMode.isActive(entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey)
    }

    let arrows: [Joystick.Direction: KeyAction] = [
        .up: .arrowUp, .down: .arrowDown, .left: .arrowLeft, .right: .arrowRight,
    ]

    test("question mode: a visible session awaiting turns the stick into plain arrows, Superset in front") {
        var registry = board([("a", mine), ("b", mine)])
        registry.setState(sessionID: "b", to: .awaiting, pendingTool: "AskUserQuestion")
        let active = questionMode(registry)
        expect(active, "b is on key 2 of the workspace in front")
        for (direction, arrow) in arrows {
            let r = ProfileResolver.resolve(
                .joystick(direction), .tap, frontBundleID: superset, prefs: prefs, questionMode: active
            )
            expectEqual(r.action, arrow, "\(direction)")
            expectEqual(r.payloadKey, "JOY.\(direction.rawValue)", "no @bundle: no ⌥⌘ chord to find")
            expect(ProfileResolver.shortcut(forPayloadKey: r.payloadKey, prefs: prefs) == nil, "\(direction)")
        }
    }

    test("question mode: the trigger names the key, the workspace and the tool") {
        var registry = board([("a", mine), ("b", mine)])
        registry.setState(sessionID: "b", to: .awaiting, pendingTool: "Bash")
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: mine))
        let trigger = QuestionMode.trigger(entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey)
        expectEqual(trigger, QuestionMode.Trigger(key: 2, sessionID: "b", workspaceID: mine, pendingTool: "Bash"))
    }

    test("question mode: nothing awaiting leaves the stick on Superset's profile") {
        let registry = board([("a", mine), ("b", mine)])
        let active = questionMode(registry)
        expect(!active)
        let r = ProfileResolver.resolve(.joystick(.right), .tap, frontBundleID: superset, prefs: prefs, questionMode: active)
        expectEqual(r.action, .shortcut)
        expectEqual(r.payloadKey, "JOY.right@\(superset)")
        expectEqual(ProfileResolver.shortcut(forPayloadKey: r.payloadKey, prefs: prefs)?.modifiers, [.command, .option])
    }

    test("question mode: a session awaiting in another workspace does not turn it on") {
        var registry = board([("a", mine), ("x", theirs)])
        registry.setState(sessionID: "x", to: .awaiting, pendingTool: "AskUserQuestion")
        // Lent to the last key as overflow, but its prompt is not in the terminal in
        // front: arrows would land in the wrong tab.
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: mine))
        expectEqual(view.overflowKey, BoardLayout.slotCount)
        expect(!questionMode(registry), "another workspace's prompt")
        expect(questionMode(registry, workspace: theirs), "but in its own workspace it is on")
    }

    test("question mode: back to working gives the profile back") {
        var registry = board([("a", mine)])
        registry.setState(sessionID: "a", to: .awaiting, pendingTool: "AskUserQuestion")
        expect(questionMode(registry))
        registry.setState(sessionID: "a", to: .working)
        let active = questionMode(registry)
        expect(!active, "answered")
        let r = ProfileResolver.resolve(.joystick(.up), .tap, frontBundleID: superset, prefs: prefs, questionMode: active)
        expectEqual(r.action, .shortcut)
        expectEqual(r.payloadKey, "JOY.up@\(superset)")
    }

    test("question mode: the resolver only changes the stick — the dial and caps are routed by QuestionMode") {
        for control in [PadControl.encoderLong, .encoderClick, .action("ACT09"), .action("ACT11")] {
            for gesture in [Gesture.tap, .hold] {
                expectEqual(
                    ProfileResolver.resolve(control, gesture, frontBundleID: superset, prefs: prefs, questionMode: true),
                    ProfileResolver.resolve(control, gesture, frontBundleID: superset, prefs: prefs),
                    "\(control) \(gesture)"
                )
            }
        }
    }

    // The full question-mode map: what each control does while a prompt is waiting,
    // on top of the stick's arrows.

    test("question mode: FAST and CODEX are ignored, tap and hold") {
        for cap in ["ACT06", "ACT12"] {
            expect(QuestionMode.ignores(cap: cap, active: true), "\(cap) in question mode")
            expect(!QuestionMode.ignores(cap: cap, active: false), "\(cap) outside it")
        }
        expectEqual(QuestionMode.ignoredLogLine(cap: "ACT06"), "key ACT06: ignored in question mode")
    }

    test("question mode: every other cap keeps working — APPR, REJ, BRANCH, MIC, NEW") {
        for cap in ["ACT07", "ACT08", "ACT09", "ACT10", "ACT11"] {
            expect(!QuestionMode.ignores(cap: cap, active: true), cap)
        }
    }

    test("question mode: turning the dial sends one arrow per detent") {
        expectEqual(QuestionMode.dial(.turn(lines: 3), pendingTool: "AskUserQuestion"), .arrow(.up))
        expectEqual(QuestionMode.dial(.turn(lines: -3), pendingTool: "AskUserQuestion"), .arrow(.down))
        expectEqual(QuestionMode.dial(.turn(lines: 1), pendingTool: nil), .arrow(.up), "not multiplied by scrollLines")
        expectEqual(QuestionMode.dial(.turn(lines: -9), pendingTool: "Bash"), .arrow(.down))
    }

    test("question mode: with a plan waiting the dial keeps scrolling, to read it") {
        expectEqual(QuestionMode.dial(.turn(lines: 3), pendingTool: "ExitPlanMode"), .profile)
        expectEqual(QuestionMode.dial(.turn(lines: -3), pendingTool: "ExitPlanMode"), .profile)
    }

    test("question mode: dial click is Space, dial hold is Tab") {
        for tool in [nil, "AskUserQuestion", "ExitPlanMode"] as [String?] {
            expectEqual(QuestionMode.dial(.click, pendingTool: tool), .key(Shortcut(keyCode: 49, key: "Space")), "\(tool ?? "none")")
            expectEqual(QuestionMode.dial(.hold, pendingTool: tool), .key(Shortcut(keyCode: 48, key: "⇥")), "\(tool ?? "none")")
        }
    }

    test("question mode: APPR and REJ answer the trigger's session, not the one-waiting rule") {
        let trigger = QuestionMode.Trigger(key: 2, sessionID: "b", workspaceID: mine, pendingTool: "AskUserQuestion")
        expectEqual(QuestionMode.answerTarget(for: .approve, trigger: trigger), "b")
        expectEqual(QuestionMode.answerTarget(for: .reject, trigger: trigger), "b")
        expect(QuestionMode.answerTarget(for: .enter, trigger: trigger) == nil, "NEW's ⏎ is unconditional")
        expect(QuestionMode.answerTarget(for: .approve, trigger: nil) == nil, "outside question mode: the old rule")
    }

    test("question mode: APPR does not turn it off — a multi-question prompt is still open") {
        var registry = board([("a", mine), ("b", mine)])
        registry.setState(sessionID: "a", to: .awaiting, pendingTool: "AskUserQuestion")
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: mine))
        let current = QuestionMode.next(
            current: nil, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
        )
        expectEqual(current?.sessionID, "a")
        // APPR sent ⏎ to "a": the prompt moved to its next question and no hook arrived.
        // Nothing the key did is an input here — only the hook's state is.
        let after = QuestionMode.next(
            current: current, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
        )
        expectEqual(after, current)
    }

    test("question mode: it stays on its session while another one starts waiting") {
        var registry = board([("a", mine), ("b", mine)])
        registry.setState(sessionID: "b", to: .awaiting, pendingTool: "AskUserQuestion")
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: mine))
        let current = QuestionMode.next(
            current: nil, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
        )
        registry.setState(sessionID: "a", to: .awaiting, pendingTool: "Bash")
        let after = QuestionMode.next(
            current: current, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
        )
        expectEqual(after?.sessionID, "b", "APPR must not move to a prompt the arrows never reached")
    }

    test("question mode: it goes off the moment the session works, finishes, ends or closes") {
        func started() -> (SessionRegistry, PadView, QuestionMode.Trigger?) {
            var registry = board([("a", mine)])
            registry.setState(sessionID: "a", to: .awaiting, pendingTool: "AskUserQuestion")
            let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: mine))
            let trigger = QuestionMode.next(
                current: nil, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
            )
            return (registry, view, trigger)
        }
        for leave in [SessionState.working, .done, .ended] {
            var (registry, view, current) = started()
            expect(current != nil)
            registry.setState(sessionID: "a", to: leave)
            let after = QuestionMode.next(
                current: current, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
            )
            expect(after == nil, "\(leave)")
        }
        var (registry, view, current) = started()
        _ = registry.release(sessionID: "a")
        let after = QuestionMode.next(
            current: current, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
        )
        expect(after == nil, "closed")
    }

    test("question mode: a prompt restored from disk and never confirmed does not turn it on") {
        var registry = board([("a", mine)])
        registry.setState(sessionID: "a", to: .awaiting, pendingTool: "AskUserQuestion")
        var entries = registry.entries
        entries[0].isUnconfirmed = true
        let view = PadView.compose(entries: entries, context: .superset(workspaceID: mine))
        expect(
            QuestionMode.trigger(entries: entries, padKeys: view.keys, overflowKey: view.overflowKey) == nil,
            "a stale awaiting would send arrows into the chat prompt"
        )
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
