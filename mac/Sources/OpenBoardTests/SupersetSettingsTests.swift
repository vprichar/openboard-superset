import Foundation
import OpenBoardKit

/*
 The Superset and Workspaces panes' edits, without the window.

 Every control on those panes writes through `SettingsEditing+Superset`, so these pin
 the clamps (a slider or a hand-typed field can never leave a value the pad cannot
 survive), the safety rule that stays locked, and — the one that keeps the panes honest —
 that every field of the new groups has an edit *and* a control.
 */
func runSupersetSettingsTests() {
    /// What the next launch reads: saved to JSON and merged back.
    func reloaded(_ p: Preferences) -> Preferences {
        let data = try! JSONSerialization.data(withJSONObject: p.json)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return Preferences.merging(json)
    }

    test("superset settings: the host client can be switched off and back") {
        var p = Preferences.default
        expectEqual(p.superset.hostClient, .auto, "precondition: default is auto")
        SettingsEditing.setHostClient(.off, in: &p)
        expectEqual(p.superset.hostClient, .off)
        expectEqual(reloaded(p).superset.hostClient, .off, "off must survive a relaunch")
        SettingsEditing.setHostClient(.auto, in: &p)
        expectEqual(p.superset.hostClient, .auto)
    }

    test("superset settings: advanced timings are clamped to what the client accepts") {
        var p = Preferences.default
        SettingsEditing.setSuperset({ s in
            s.startDebounceMs = -5
            s.dedupeWindowMs = 99_999
            s.padWriteCoalesceMs = 5000
        }, in: &p)
        expectEqual(p.superset.startDebounceMs, 0)
        expectEqual(p.superset.dedupeWindowMs, 10000)
        expectEqual(p.superset.padWriteCoalesceMs, 1000)
    }

    test("superset settings: a blank org id means auto-detect, never an empty string") {
        var p = Preferences.default
        SettingsEditing.setSuperset({ $0.orgID = "  " }, in: &p)
        expectEqual(p.superset.orgID, nil)
        SettingsEditing.setSuperset({ $0.orgID = " org_1 " }, in: &p)
        expectEqual(p.superset.orgID, "org_1")
    }

    test("targeted snippets: add, rename and remove keep the others in order") {
        var p = Preferences.default
        SettingsEditing.setTargetedSnippet(name: "tests", text: "run the tests", in: &p)
        SettingsEditing.setTargetedSnippet(name: "commit", text: "commit it", in: &p)
        SettingsEditing.setTargetedSnippet(name: "review", text: "review the diff", in: &p)
        expectEqual(SettingsEditing.targetedSnippetNames(p), ["commit", "review", "tests"])

        SettingsEditing.renameTargetedSnippet(from: "review", to: "audit", in: &p)
        expectEqual(SettingsEditing.targetedSnippetNames(p), ["audit", "commit", "tests"])
        expectEqual(p.targeted.snippets["audit"], "review the diff", "a rename keeps the text")
        expectEqual(p.targeted.snippets["review"], nil)

        SettingsEditing.setTargetedSnippet(name: "commit", text: nil, in: &p)
        expectEqual(SettingsEditing.targetedSnippetNames(p), ["audit", "tests"])
        expectEqual(SettingsEditing.targetedSnippetNames(reloaded(p)), ["audit", "tests"])
    }

    test("targeted snippets: a rename onto an existing name or a blank one is refused") {
        var p = Preferences.default
        SettingsEditing.setTargetedSnippet(name: "a", text: "one", in: &p)
        SettingsEditing.setTargetedSnippet(name: "b", text: "two", in: &p)
        SettingsEditing.renameTargetedSnippet(from: "a", to: "b", in: &p)
        expectEqual(p.targeted.snippets, ["a": "one", "b": "two"], "b must not be overwritten")
        SettingsEditing.renameTargetedSnippet(from: "a", to: "   ", in: &p)
        expectEqual(p.targeted.snippets, ["a": "one", "b": "two"])
        SettingsEditing.setTargetedSnippet(name: " ", text: "x", in: &p)
        expectEqual(p.targeted.snippets.count, 2, "a blank name is not a snippet")
    }

    test("targeted: maxSendBytes is clamped to 1…16384") {
        var p = Preferences.default
        SettingsEditing.setMaxSendBytes(0, in: &p)
        expectEqual(p.targeted.maxSendBytes, 1)
        SettingsEditing.setMaxSendBytes(100_000, in: &p)
        expectEqual(p.targeted.maxSendBytes, 16384)
        SettingsEditing.setMaxSendBytes(2048, in: &p)
        expectEqual(p.targeted.maxSendBytes, 2048)
    }

    test("targeted: requireStopForSend stays locked on whatever the edit says") {
        var p = Preferences.default
        SettingsEditing.setTargeted({ $0.requireStopForSend = false }, in: &p)
        expect(p.targeted.requireStopForSend, "a safety rule, not a preference")
    }

    test("targeted: an empty default snippet is refused, windows are clamped") {
        var p = Preferences.default
        SettingsEditing.setTargeted({ t in
            t.defaultSnippet = "   "
            t.windowMs = 10
            t.snapshotLines = 0
        }, in: &p)
        expectEqual(p.targeted.defaultSnippet, Preferences.default.targeted.defaultSnippet)
        expectEqual(p.targeted.windowMs, 500)
        expectEqual(p.targeted.snapshotLines, 1)
    }

    test("confirm: the window is clamped to 1…10 s and the color is kept") {
        var p = Preferences.default
        SettingsEditing.setConfirm(color: nil, windowMs: 50, in: &p)
        expectEqual(p.confirm.windowMs, 1000)
        expectEqual(p.confirm.color, Preferences.default.confirm.color, "nil color leaves it alone")
        SettingsEditing.setConfirm(color: RGB(0x9B30FF), windowMs: 60_000, in: &p)
        expectEqual(p.confirm.windowMs, 10000)
        expectEqual(p.confirm.color, RGB(0x9B30FF))
        SettingsEditing.setConfirm(effect: .solid, brightness: 3, in: &p)
        expectEqual(p.confirm.effect, .solid)
        expectEqual(p.confirm.brightness, 1)
    }

    test("launch: a blank agent is refused, the cooldown is clamped") {
        var p = Preferences.default
        SettingsEditing.setLaunch({ l in
            l.newAgent = "  "
            l.handoffAgent = " claude "
            l.createCooldownMs = -1
            l.handoffContextChars = 0
        }, in: &p)
        expectEqual(p.launch.newAgent, Preferences.default.launch.newAgent)
        expectEqual(p.launch.handoffAgent, "claude")
        expectEqual(p.launch.createCooldownMs, 0)
        expectEqual(p.launch.handoffContextChars, 1)
    }

    test("transition: each slider is clamped to its range") {
        var p = Preferences.default
        SettingsEditing.setTransition({ t in
            t.keyStaggerMs = 900
            t.firstKeyDelayMs = -3
            t.ringSpeed = 1.7
            t.ringBrightness = -0.2
            t.ringFadeSteps = 0
            t.ringFadeStepMs = 1
            t.debounceMs = 9000
        }, in: &p)
        expectEqual(p.workspaceTransition.keyStaggerMs, 500)
        expectEqual(p.workspaceTransition.firstKeyDelayMs, 0)
        expectEqual(p.workspaceTransition.ringSpeed, 1)
        expectEqual(p.workspaceTransition.ringBrightness, 0)
        expectEqual(p.workspaceTransition.ringFadeSteps, 1, "zero steps is a sweep that never ends")
        expectEqual(p.workspaceTransition.ringFadeStepMs, 10)
        expectEqual(p.workspaceTransition.debounceMs, 2000)
    }

    test("transition: turning the sweep off is a plain style write") {
        var p = Preferences.default
        SettingsEditing.setTransition({ $0.style = .off }, in: &p)
        expectEqual(p.workspaceTransition.style, .off)
        expectEqual(reloaded(p).workspaceTransition.style, .off)
    }

    test("identity: the palette never ends up empty") {
        var p = Preferences.default
        SettingsEditing.setPalette([], in: &p)
        expect(!p.workspaceIdentity.palette.isEmpty, "an empty palette is refused")
        expectEqual(p.workspaceIdentity.palette, Preferences.WorkspaceIdentity.defaultPalette)
        SettingsEditing.setPalette([RGB(0x00C9A7)], in: &p)
        expectEqual(p.workspaceIdentity.palette, [RGB(0x00C9A7)])
    }

    test("identity: a pinned workspace color is set, and nil removes the entry") {
        var p = Preferences.default
        SettingsEditing.setWorkspaceColor(RGB(0xB4E600), workspaceID: "ws-1", in: &p)
        expectEqual(p.workspaceIdentity.colors["ws-1"], RGB(0xB4E600))
        expectEqual(reloaded(p).workspaceIdentity.colors["ws-1"], RGB(0xB4E600))
        SettingsEditing.setWorkspaceColor(nil, workspaceID: "ws-1", in: &p)
        expect(p.workspaceIdentity.colors["ws-1"] == nil, "nil removes, it does not store black")
        expect(p.workspaceIdentity.colors.keys.contains("ws-1") == false)
    }

    test("overflow: brightness and wink timings are clamped") {
        var p = Preferences.default
        SettingsEditing.setOverflow({ o in
            o.brightness = 2
            o.winkEveryMs = 10
            o.winkMs = 99_999
        }, in: &p)
        expectEqual(p.overflow.brightness, 1)
        expectEqual(p.overflow.winkEveryMs, 500)
        expectEqual(p.overflow.winkMs, 2000)
    }

    test("unconfirmed: its appearance is written under states[\"unconfirmed\"]") {
        var p = Preferences.default
        let look = Appearance(color: RGB(0x0C47E9), effect: .breath, brightness: 0.4, speed: 0.2)
        SettingsEditing.setUnconfirmedAppearance(look, in: &p)
        expectEqual(p.unconfirmedAppearance, look)
        expectEqual(reloaded(p).unconfirmedAppearance, look)
    }

    runFieldCoverageTests()
    runColorThemeTests()
    runThemePickerTests()
    runCustomThemeTests()
    runThemeSwitchTests()
}

/**
 "Every field of the new groups has a `SettingsEditing` — and a control."

 The groups are walked with `Mirror`, so a field added to `Preferences` later fails
 here until someone gives it an edit below and a control on a pane. Each edit must
 actually change its field (except the locked safety rule), and each field's name must
 appear in the pane source that owns it.
 */
private func runFieldCoverageTests() {
    typealias Edit = (inout Preferences) -> Void

    let edits: [String: Edit] = [
        "superset.hostClient": { SettingsEditing.setHostClient(.off, in: &$0) },
        "superset.orgID": { SettingsEditing.setSuperset({ $0.orgID = "org_x" }, in: &$0) },
        "superset.testedVersion": { SettingsEditing.setSuperset({ $0.testedVersion = "9.9.9" }, in: &$0) },
        "superset.onVersionMismatch": { SettingsEditing.setSuperset({ $0.onVersionMismatch = .full }, in: &$0) },
        "superset.events": { SettingsEditing.setSuperset({ $0.events.toggle() }, in: &$0) },
        "superset.startDebounceMs": { SettingsEditing.setSuperset({ $0.startDebounceMs = 700 }, in: &$0) },
        "superset.dedupeWindowMs": { SettingsEditing.setSuperset({ $0.dedupeWindowMs = 700 }, in: &$0) },
        "superset.padWriteCoalesceMs": { SettingsEditing.setSuperset({ $0.padWriteCoalesceMs = 300 }, in: &$0) },
        "superset.reconcileOnLaunch": { SettingsEditing.setSuperset({ $0.reconcileOnLaunch.toggle() }, in: &$0) },

        "confirm.windowMs": { SettingsEditing.setConfirm(color: nil, windowMs: 5000, in: &$0) },
        "confirm.color": { SettingsEditing.setConfirm(color: RGB(0x123456), windowMs: nil, in: &$0) },
        "confirm.effect": { SettingsEditing.setConfirm(effect: .solid, in: &$0) },
        "confirm.brightness": { SettingsEditing.setConfirm(brightness: 0.1, in: &$0) },

        "targeted.mode": { SettingsEditing.setTargeted({ $0.mode = .chord }, in: &$0) },
        "targeted.windowMs": { SettingsEditing.setTargeted({ $0.windowMs = 7000 }, in: &$0) },
        "targeted.snapshotLines": { SettingsEditing.setTargeted({ $0.snapshotLines = 50 }, in: &$0) },
        "targeted.requireStopForSend": { SettingsEditing.setTargeted({ $0.requireStopForSend = false }, in: &$0) },
        "targeted.maxSendBytes": { SettingsEditing.setMaxSendBytes(100, in: &$0) },
        "targeted.defaultSnippet": { SettingsEditing.setTargeted({ $0.defaultSnippet = "go on" }, in: &$0) },
        "targeted.snippets": { SettingsEditing.setTargetedSnippet(name: "n", text: "t", in: &$0) },

        "launch.newAgent": { SettingsEditing.setLaunch({ $0.newAgent = "codex" }, in: &$0) },
        "launch.handoffAgent": { SettingsEditing.setLaunch({ $0.handoffAgent = "claude" }, in: &$0) },
        "launch.handoffContextChars": { SettingsEditing.setLaunch({ $0.handoffContextChars = 800 }, in: &$0) },
        "launch.createCooldownMs": { SettingsEditing.setLaunch({ $0.createCooldownMs = 4000 }, in: &$0) },

        "workspaceTransition.style": { SettingsEditing.setTransition({ $0.style = .cut }, in: &$0) },
        "workspaceTransition.respectReduceMotion": { SettingsEditing.setTransition({ $0.respectReduceMotion.toggle() }, in: &$0) },
        "workspaceTransition.debounceMs": { SettingsEditing.setTransition({ $0.debounceMs = 300 }, in: &$0) },
        "workspaceTransition.rapidWindowMs": { SettingsEditing.setTransition({ $0.rapidWindowMs = 3000 }, in: &$0) },
        "workspaceTransition.keyStaggerMs": { SettingsEditing.setTransition({ $0.keyStaggerMs = 120 }, in: &$0) },
        "workspaceTransition.firstKeyDelayMs": { SettingsEditing.setTransition({ $0.firstKeyDelayMs = 200 }, in: &$0) },
        "workspaceTransition.overflowDelayMs": { SettingsEditing.setTransition({ $0.overflowDelayMs = 300 }, in: &$0) },
        "workspaceTransition.ringSweep": { SettingsEditing.setTransition({ $0.ringSweep.toggle() }, in: &$0) },
        "workspaceTransition.ringSpeed": { SettingsEditing.setTransition({ $0.ringSpeed = 0.3 }, in: &$0) },
        "workspaceTransition.ringBrightness": { SettingsEditing.setTransition({ $0.ringBrightness = 0.3 }, in: &$0) },
        "workspaceTransition.ringHoldMs": { SettingsEditing.setTransition({ $0.ringHoldMs = 1500 }, in: &$0) },
        "workspaceTransition.ringFadeSteps": { SettingsEditing.setTransition({ $0.ringFadeSteps = 4 }, in: &$0) },
        "workspaceTransition.ringFadeStepMs": { SettingsEditing.setTransition({ $0.ringFadeStepMs = 120 }, in: &$0) },
        "workspaceTransition.minSweepIntervalMs": { SettingsEditing.setTransition({ $0.minSweepIntervalMs = 8000 }, in: &$0) },

        "workspaceIdentity.palette": { SettingsEditing.setPalette([RGB(0x00C9A7)], in: &$0) },
        "workspaceIdentity.colors": { SettingsEditing.setWorkspaceColor(RGB(0x9B30FF), workspaceID: "w", in: &$0) },

        "overflow.enabled": { SettingsEditing.setOverflow({ $0.enabled.toggle() }, in: &$0) },
        "overflow.effect": { SettingsEditing.setOverflow({ $0.effect = .breath }, in: &$0) },
        "overflow.brightness": { SettingsEditing.setOverflow({ $0.brightness = 0.2 }, in: &$0) },
        "overflow.winkEveryMs": { SettingsEditing.setOverflow({ $0.winkEveryMs = 6000 }, in: &$0) },
        "overflow.winkMs": { SettingsEditing.setOverflow({ $0.winkMs = 400 }, in: &$0) },
        "overflow.winkOriginColor": { SettingsEditing.setOverflow({ $0.winkOriginColor.toggle() }, in: &$0) },
    ]

    /// Fields that no edit may change: safety rules shown locked.
    let locked: Set<String> = ["targeted.requireStopForSend"]

    let base = Preferences.default
    let groups: [(name: String, value: Any, pane: String)] = [
        ("superset", base.superset, "SupersetPane"),
        ("confirm", base.confirm, "SupersetPane"),
        ("targeted", base.targeted, "SupersetPane"),
        ("launch", base.launch, "SupersetPane"),
        ("workspaceTransition", base.workspaceTransition, "WorkspacePane"),
        ("workspaceIdentity", base.workspaceIdentity, "WorkspacePane"),
        ("overflow", base.overflow, "WorkspacePane"),
    ]

    func field(_ group: String, _ label: String, of p: Preferences) -> String {
        let value: Any = switch group {
        case "superset": p.superset
        case "confirm": p.confirm
        case "targeted": p.targeted
        case "launch": p.launch
        case "workspaceTransition": p.workspaceTransition
        case "workspaceIdentity": p.workspaceIdentity
        default: p.overflow
        }
        let child = Mirror(reflecting: value).children.first { $0.label == label }
        return child.map { String(reflecting: $0.value) } ?? "<missing>"
    }

    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // OpenBoardTests
        .deletingLastPathComponent()      // Sources
        .appendingPathComponent("OpenBoard")
    func source(_ pane: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent("\(pane).swift"), encoding: .utf8)) ?? ""
    }

    test("field coverage: the scan reads both pane sources and finds fields") {
        expect(source("SupersetPane").count > 2000, "SupersetPane.swift did not read, or is still a stub")
        expect(source("WorkspacePane").count > 2000, "WorkspacePane.swift did not read, or is still a stub")
        let total = groups.reduce(0) { $0 + Mirror(reflecting: $1.value).children.count }
        expect(total >= 40, "Mirror found only \(total) fields — the walk is checking nothing")
    }

    for group in groups {
        let text = source(group.pane)
        for child in Mirror(reflecting: group.value).children {
            guard let label = child.label else { continue }
            let key = "\(group.name).\(label)"
            test("field coverage: \(key) has an edit and a control") {
                guard let edit = edits[key] else {
                    expect(false, "\(key) has no SettingsEditing — add one and a control")
                    return
                }
                var p = base
                edit(&p)
                let before = field(group.name, label, of: base)
                let after = field(group.name, label, of: p)
                if locked.contains(key) {
                    expectEqual(after, before, "\(key) is locked")
                } else {
                    expect(after != before, "the edit for \(key) did not change it")
                }
                expect(
                    text.contains(".\(label)"),
                    "\(group.pane).swift never mentions .\(label) — no control shows it"
                )
            }
        }
    }
}

/**
 Color themes: a skin over the pad's vocabulary, never a new vocabulary.

 Every theme is checked against the rules that make the board readable at a glance —
 what each state *means* stays put whatever it is painted, the workspace palette never
 imitates a state, and idle stays visibly quieter than working. Classic must be the
 shipped defaults exactly, so choosing it is always a way back.
 */
private func runColorThemeTests() {
    // Hue windows, in degrees. Wide enough for a theme's taste, narrow enough that a
    // glance still reads the meaning.
    let attention: ClosedRange<Double> = 5...45       // awaiting, stalled: warm
    let greens: ClosedRange<Double> = 75...165        // done
    let colds: ClosedRange<Double> = 180...275        // working
    func isRed(_ hue: Double) -> Bool { hue >= 330 || hue <= 10 }   // error
    func isAttention(_ hue: Double) -> Bool { attention.contains(hue) || isRed(hue) }

    func hueGap(_ a: Double, _ b: Double) -> Double {
        let gap = abs(a - b)
        return min(gap, 360 - gap)
    }
    /// Euclidean distance in 8-bit RGB: below ~40 two colors light a key the same.
    func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = (a.red - b.red) * 255, dg = (a.green - b.green) * 255, db = (a.blue - b.blue) * 255
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
    /// What a key actually emits: linear-light luminance scaled by the brightness.
    func emitted(_ a: Appearance) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(a.color.red) + 0.7152 * lin(a.color.green) + 0.0722 * lin(a.color.blue)
        return l * a.brightness
    }

    let themed: [SessionState] = [.idle, .viewing, .working, .awaiting, .stalled, .done, .error]

    test("themes: the five ship, with unique ids, and Classic is first") {
        expectEqual(ColorTheme.all.map(\.id), ["classic", "gamer", "ai", "pop", "claude"])
        expectEqual(Set(ColorTheme.all.map(\.id)).count, ColorTheme.all.count)
        for theme in ColorTheme.all {
            expect(!theme.name.isEmpty && !theme.summary.isEmpty, "\(theme.id) needs a name and a line")
        }
    }

    for theme in ColorTheme.all {
        let hue = { (s: SessionState) in WorkspaceColors.hue(of: theme.appearance(for: s).color) }

        test("theme \(theme.id): every state and unconfirmed is defined") {
            for state in themed { expect(theme.states[state] != nil, "\(theme.id) lacks \(state)") }
            expect(theme.palette.count >= 4, "\(theme.id) palette has \(theme.palette.count) colors")
        }

        test("theme \(theme.id): each state keeps its meaning (a)") {
            guard let awaiting = hue(.awaiting), let stalled = hue(.stalled),
                  let error = hue(.error), let done = hue(.done), let working = hue(.working) else {
                expect(false, "\(theme.id): a signal state is too grey to carry a hue")
                return
            }
            expect(attention.contains(awaiting), "\(theme.id) awaiting \(Int(awaiting))° is not a warm attention hue")
            expect(attention.contains(stalled), "\(theme.id) stalled \(Int(stalled))° is not a warm attention hue")
            expect(isRed(error), "\(theme.id) error \(Int(error))° is not red")
            expect(greens.contains(done), "\(theme.id) done \(Int(done))° is not green")
            expect(colds.contains(working), "\(theme.id) working \(Int(working))° is not blue/cold")
            // A prompt and a failure must never be mistaken for each other.
            expect(hueGap(awaiting, error) >= 20, "\(theme.id): awaiting and error only \(Int(hueGap(awaiting, error)))° apart")
            // Quiet states never borrow the attention hues.
            for quiet in [SessionState.idle, .viewing] {
                if let h = hue(quiet) { expect(!isAttention(h), "\(theme.id) \(quiet) looks like attention") }
            }
            if let h = WorkspaceColors.hue(of: theme.unconfirmed.color) {
                expect(!isAttention(h), "\(theme.id) unconfirmed looks like attention")
            }
            // D3: the confirmation light is not amber — amber already means "waiting".
            if let h = WorkspaceColors.hue(of: theme.confirmColor) {
                expect(!isAttention(h), "\(theme.id) confirmation color looks like attention")
            }
        }

        test("theme \(theme.id): no workspace color imitates a state (b)") {
            let stateColors = themed.map { theme.appearance(for: $0).color } + [theme.unconfirmed.color]
            // The runtime rule: nothing is dropped from the palette at 20°.
            expectEqual(
                WorkspaceColors.usablePalette(theme.palette, stateColors: stateColors), theme.palette,
                "\(theme.id): a palette color is within 20° of a state and would be skipped"
            )
            for color in theme.palette {
                for (state, stateColor) in zip(themed.map(\.rawValue) + ["unconfirmed"], stateColors) {
                    if let a = WorkspaceColors.hue(of: color), let b = WorkspaceColors.hue(of: stateColor) {
                        expect(hueGap(a, b) >= 20, "\(theme.id) \(color.hex) is \(Int(hueGap(a, b)))° from \(state)")
                    }
                    // Desaturated colors have no hue to compare; they must still look different.
                    expect(distance(color, stateColor) >= 40, "\(theme.id) \(color.hex) looks like \(stateColor.hex)")
                }
            }
            // And the workspaces must be told apart from each other.
            for (i, a) in theme.palette.enumerated() {
                for b in theme.palette[(i + 1)...] {
                    expect(distance(a, b) >= 60, "\(theme.id): \(a.hex) and \(b.hex) are hard to tell apart")
                }
            }
        }

        test("theme \(theme.id): idle is clearly quieter than working (c)") {
            let idle = emitted(theme.appearance(for: .idle))
            let working = emitted(theme.appearance(for: .working))
            expect(working >= idle * 1.5, "\(theme.id): working \(working) vs idle \(idle) — too close")
            expect(emitted(theme.appearance(for: .viewing)) > idle, "\(theme.id): viewing must be brighter than idle")
        }
    }

    test("themes: apply touches only the state colors, palette and confirmation (d)") {
        var before = Preferences.default
        before.workspaceIdentity.colors = ["ws-1": RGB(0x123456)]
        before.confirm.windowMs = 7000
        before.confirm.effect = .solid
        before.targeted.defaultSnippet = "go"
        before.states[SessionState.ended.rawValue] = Appearance(color: RGB(0x010203), effect: .off, brightness: 0)
        for theme in ColorTheme.all {
            let after = ColorTheme.apply(theme, to: before)
            for state in themed { expectEqual(after.appearance(for: state), theme.appearance(for: state)) }
            expectEqual(after.unconfirmedAppearance, theme.unconfirmed)
            expectEqual(after.workspaceIdentity.palette, theme.palette)
            expectEqual(after.confirm.color, theme.confirmColor)

            // Everything else is untouched: compare the documents with the themed keys put back.
            var restored = after
            for state in themed { restored.setAppearance(before.appearance(for: state), for: state) }
            restored.states[Preferences.unconfirmedKey] = before.states[Preferences.unconfirmedKey]
            restored.workspaceIdentity.palette = before.workspaceIdentity.palette
            restored.confirm.color = before.confirm.color
            expect(
                NSDictionary(dictionary: restored.json).isEqual(to: before.json),
                "\(theme.id): apply changed something outside its colors"
            )
            // Idempotent, and the theme is recognised afterwards.
            expect(NSDictionary(dictionary: ColorTheme.apply(theme, to: after).json).isEqual(to: after.json))
            expectEqual(ColorTheme.current(in: after)?.id, theme.id)
        }
    }

    test("themes: Classic is exactly the shipped defaults (e)") {
        expect(
            NSDictionary(dictionary: ColorTheme.apply(.classic, to: .default).json).isEqual(to: Preferences.default.json),
            "Classic on the defaults must change nothing"
        )
        for state in themed { expectEqual(ColorTheme.classic.appearance(for: state), state.defaultAppearance) }
        expectEqual(ColorTheme.classic.unconfirmed, Preferences.unconfirmedDefault)
        expectEqual(ColorTheme.classic.palette, Preferences.WorkspaceIdentity.defaultPalette)
        expectEqual(ColorTheme.classic.confirmColor, Preferences.Confirm().color)
        expectEqual(ColorTheme.current(in: .default)?.id, "classic")

        // And it is a way back from any other theme.
        let back = ColorTheme.apply(.classic, to: ColorTheme.apply(.gamer, to: .default))
        expect(NSDictionary(dictionary: back.json).isEqual(to: Preferences.default.json))
    }

    test("themes: a hand-edited color means no theme is current") {
        var p = ColorTheme.apply(.pop, to: .default)
        var look = p.appearance(for: .done)
        look.color = RGB(0x00FF00)
        p.setAppearance(look, for: .done)
        expect(ColorTheme.current(in: p) == nil)
    }
}

/**
 The theme picker on the Workspaces pane: the edit it makes, the card it marks, and the
 words it shows in both languages.
 */
private func runThemePickerTests() {
    func same(_ a: Preferences, _ b: Preferences) -> Bool {
        NSDictionary(dictionary: a.json).isEqual(to: b.json)
    }

    test("theme picker: setTheme applies the theme, and Classic takes it back") {
        var p = Preferences.default
        p.targeted.defaultSnippet = "go"
        let before = p
        SettingsEditing.setTheme(.claude, in: &p)
        expectEqual(ColorTheme.current(in: p)?.id, "claude")
        expect(same(p, ColorTheme.apply(.claude, to: before)), "setTheme is apply, nothing more")
        SettingsEditing.setTheme(.classic, in: &p)
        expect(same(p, before), "Classic restores every color and leaves the rest alone")
    }

    test("theme picker: the card marked is the current theme, or Custom after a hand edit") {
        var p = Preferences.default
        expectEqual(SettingsEditing.themeSelection(p), .theme("classic"))
        for theme in ColorTheme.all {
            SettingsEditing.setTheme(theme, in: &p)
            expectEqual(SettingsEditing.themeSelection(p), .theme(theme.id))
        }
        var look = p.appearance(for: .working)
        look.color = RGB(0x123456)
        p.setAppearance(look, for: .working)
        expectEqual(SettingsEditing.themeSelection(p), .custom)
    }

    test("theme picker: the Spanish names, with English for every visible theme string") {
        expectEqual(ColorTheme.all.map(\.name), ["Clásico", "Gamer", "IA", "Pop", "Claude"])
        for theme in ColorTheme.all {
            expect(UIStrings.table[theme.name] != nil, "\(theme.name) has no English")
            expect(UIStrings.table[theme.summary] != nil, "\(theme.id) summary has no English")
        }
        expectEqual(UIStrings.table["Clásico"], "Classic")
        expectEqual(UIStrings.table["IA"], "AI")
        expect(UIStrings.table["Personalizado"] != nil)
    }

    test("theme picker: the pane shows the cards, marks the current one, and writes through setTheme") {
        let pane = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenBoard/WorkspacePane.swift"), encoding: .utf8)) ?? ""
        expect(pane.contains("ColorTheme.available(in:"), "no card per theme, built-in and custom")
        expect(pane.contains("SettingsEditing.themeSelection("), "the marked card is not the current theme")
        expect(pane.contains("SettingsEditing.setTheme("), "choosing a theme does not go through setTheme")
        expect(pane.contains("theme.displayName"), "theme names are not translated")
    }
}

/**
 Themes of one's own: saved from the current colors, duplicated, renamed, deleted,
 exported and imported — and checked against the same rules the built-in ones pass.
 */
private func runCustomThemeTests() {
    let savedLanguage = UIStrings.override
    UIStrings.override = .es
    defer { UIStrings.override = savedLanguage }

    func handEdited() -> Preferences {
        var p = Preferences.default
        var look = p.appearance(for: .working)
        look.color = RGB(0x3355FF)
        p.setAppearance(look, for: .working)
        return p
    }

    test("custom themes: save from Custom keeps those colors and becomes current") {
        var p = handEdited()
        expectEqual(SettingsEditing.themeSelection(p), .custom, "precondition")
        guard let saved = SettingsEditing.saveCurrentAsTheme(name: "  Mío ", in: &p) else {
            expect(false, "save refused a fresh name"); return
        }
        expectEqual(saved.name, "Mío")
        expect(saved.id.hasPrefix("custom-"))
        expectEqual(p.customThemes, [saved])
        expectEqual(saved.states[.working]?.color, RGB(0x3355FF))
        expectEqual(ColorTheme.current(in: p)?.id, saved.id, "current(in:) recognises it")
        expectEqual(SettingsEditing.themeSelection(p), .theme(saved.id))
    }

    test("custom themes: a taken or blank name is refused, in either language") {
        var p = handEdited()
        _ = SettingsEditing.saveCurrentAsTheme(name: "Mío", in: &p)
        for name in ["Mío", "mío ", "Clásico", "classic", "IA", "   "] {
            expect(SettingsEditing.themeNameProblem(name, in: p) != nil, "«\(name)» should be refused")
            expect(SettingsEditing.saveCurrentAsTheme(name: name, in: &p) == nil)
        }
        expectEqual(p.customThemes.count, 1)
        expect(SettingsEditing.themeNameProblem("Otro", in: p) == nil)
    }

    test("custom themes: duplicating a built-in copies it under a new, free name") {
        var p = Preferences.default
        let copy = SettingsEditing.duplicateTheme(.claude, in: &p)
        let again = SettingsEditing.duplicateTheme(.claude, in: &p)
        expect(copy.id != "claude" && copy.id != again.id)
        expect(copy.name != again.name, "two copies, two names")
        expectEqual(copy.theme.states, ColorTheme.claude.states)
        expectEqual(copy.theme.palette, ColorTheme.claude.palette)
        expectEqual(copy.theme.confirmColor, ColorTheme.claude.confirmColor)
        expectEqual(p.customThemes.count, 2)
    }

    test("custom themes: rename checks the name, delete never touches a built-in") {
        var p = Preferences.default
        let mine = SettingsEditing.duplicateTheme(.pop, in: &p)
        expect(SettingsEditing.renameTheme(id: mine.id, to: "Caramelo", in: &p))
        expectEqual(p.customThemes.first?.name, "Caramelo")
        expect(!SettingsEditing.renameTheme(id: mine.id, to: "Gamer", in: &p), "taken by a built-in")
        expect(!SettingsEditing.renameTheme(id: "pop", to: "Otra cosa", in: &p), "a built-in cannot be renamed")

        SettingsEditing.deleteTheme(id: "pop", in: &p)
        expectEqual(ColorTheme.all.map(\.id), ["classic", "gamer", "ai", "pop", "claude"])
        expectEqual(p.customThemes.count, 1)
        SettingsEditing.deleteTheme(id: mine.id, in: &p)
        expect(p.customThemes.isEmpty)
    }

    test("custom themes: applying one then Classic goes back to the defaults") {
        var p = Preferences.default
        let mine = SettingsEditing.duplicateTheme(.gamer, in: &p)
        SettingsEditing.setTheme(mine.theme, in: &p)
        expectEqual(ColorTheme.current(in: p)?.id, "gamer", "identical colors: the built-in is named first")
        SettingsEditing.setTheme(.classic, in: &p)
        p.customThemes = []
        expect(NSDictionary(dictionary: p.json).isEqual(to: Preferences.default.json))
    }

    test("theme file: export then import gives the same theme, under a new id") {
        var p = handEdited()
        let mine = SettingsEditing.saveCurrentAsTheme(name: "Exportado", in: &p)!
        let data = ThemeFile.encode(mine.theme)
        let text = String(decoding: data, as: UTF8.self)
        expect(text.contains("\"openboardTheme\" : 1"), "versioned")
        expect(text.contains("#3355FF"), "colors as hex")
        let back = try? ThemeFile.decode(data)
        expectEqual(back?.name, "Exportado")
        expectEqual(back?.states, mine.states)
        expectEqual(back?.unconfirmed, mine.unconfirmed)
        expectEqual(back?.palette, mine.palette)
        expectEqual(back?.confirmColor, mine.confirmColor)
        expect(back?.id != mine.id, "an import is a new theme")

        // A built-in exports too, and imports as a custom copy of it.
        let classic = try? ThemeFile.decode(ThemeFile.encode(.classic))
        expectEqual(classic?.theme.states, ColorTheme.classic.states)
    }

    test("theme file: import names a clash apart instead of overwriting") {
        var p = Preferences.default
        let first = try! ThemeFile.decode(ThemeFile.encode(.claude))
        let added = SettingsEditing.addTheme(first, in: &p)
        expect(added.name != "Claude", "a built-in name is taken")
        let twice = SettingsEditing.addTheme(first, in: &p)
        expect(twice.name != added.name)
        expectEqual(p.customThemes.count, 2)
    }

    test("theme file: invalid input fails with a clear error") {
        func error(_ text: String) -> ThemeFileError? {
            do { _ = try ThemeFile.decode(Data(text.utf8)); return nil } catch let e as ThemeFileError { return e } catch { return nil }
        }
        let good = String(decoding: ThemeFile.encode(.pop), as: UTF8.self)
        expectEqual(error("not json"), .notATheme)
        expectEqual(error("{\"name\":\"x\"}"), .notATheme)
        expectEqual(error(good.replacingOccurrences(of: "\"openboardTheme\" : 1", with: "\"openboardTheme\" : 2")), .unsupportedVersion(2))
        guard case let .invalid(missing)? = error(good.replacingOccurrences(of: "\"done\"", with: "\"finished\"")) else {
            expect(false, "a missing state must be invalid"); return
        }
        expect(missing.contains("states.done"), "names the field: \(missing)")
        guard case let .invalid(effect)? = error(good.replacingOccurrences(of: "\"breath\"", with: "\"snake\"")) else {
            expect(false, "snake must be refused"); return
        }
        expect(effect.contains("effect"), "names the field: \(effect)")
        let emptyPalette = try! JSONSerialization.jsonObject(with: Data(good.utf8)) as! [String: Any]
        var noPalette = emptyPalette
        noPalette["palette"] = [String]()
        let data = try! JSONSerialization.data(withJSONObject: noPalette)
        guard case let .invalid(palette)? = error(String(decoding: data, as: UTF8.self)) else {
            expect(false, "an empty palette must be invalid"); return
        }
        expect(palette.contains("palette"))
        for e in [ThemeFileError.notATheme, .unsupportedVersion(2), .invalid("x")] {
            expect(!e.message.isEmpty)
        }
    }

    test("theme rules: the built-ins pass, and each rule catches its own breach") {
        for theme in ColorTheme.all {
            expectEqual(ThemeRules.violations(theme).map(\.message), [], "\(theme.id) should pass")
        }
        func variant(_ change: (inout CustomTheme) -> Void) -> [ThemeRules.Violation] {
            var t = CustomTheme(from: .classic, id: "custom-t", name: "t")
            change(&t)
            return ThemeRules.violations(t.theme)
        }
        let meaning = variant { $0.states[.awaiting]?.color = RGB(0x33CC33) }
        expect(meaning.contains { $0.rule == .meaning && $0.message.contains("5–45°") && $0.message.contains("120°") },
               "awaiting in green: \(meaning.map(\.message))")
        let palette = variant { $0.palette = [RGB(0xFF7000)] }
        expect(palette.contains { $0.rule == .palette }, "a palette orange next to awaiting")
        let contrast = variant { $0.states[.idle] = $0.states[.working] }
        expect(contrast.contains { $0.rule == .contrast }, "idle as bright as working")
        expect(!meaning.contains { $0.rule == .contrast }, "one breach, one rule")
    }
}

/**
 Choosing a theme card: the pad plays the theme first and the colors land when it
 ends — directly without a pad, and only the last choice ever lands.
 */
private func runThemeSwitchTests() {
    test("theme switch: choosing plays a preview and applies when it ends") {
        var flow = ThemeSwitch()
        guard case let .preview(ticket) = flow.select("claude", padReady: true) else {
            expect(false, "with a pad, choosing previews first"); return
        }
        expectEqual(flow.pending, "claude", "the card shows it is on its way")
        expectEqual(flow.previewEnded(ticket: ticket), "claude", "applied at the end")
        expectEqual(flow.pending, nil)
        expectEqual(flow.previewEnded(ticket: ticket), nil, "a second end applies nothing")
    }

    test("theme switch: without a pad the theme applies at once") {
        var flow = ThemeSwitch()
        expectEqual(flow.select("pop", padReady: false), .applyNow)
        expectEqual(flow.pending, nil)
    }

    test("theme switch: the last choice wins") {
        var flow = ThemeSwitch()
        guard case let .preview(first) = flow.select("gamer", padReady: true),
              case let .preview(second) = flow.select("ai", padReady: true) else {
            expect(false, "both preview"); return
        }
        expectEqual(flow.pending, "ai")
        expectEqual(flow.previewEnded(ticket: first), nil, "the superseded one never lands")
        expectEqual(flow.previewEnded(ticket: second), "ai")

        // A direct apply also supersedes a preview still playing.
        guard case let .preview(third) = flow.select("claude", padReady: true) else { return }
        expectEqual(flow.select("classic", padReady: false), .applyNow)
        expectEqual(flow.previewEnded(ticket: third), nil)
    }

    test("theme switch: the card goes through the flow and previewThemeThen") {
        let pane = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenBoard/WorkspacePane.swift"), encoding: .utf8)) ?? ""
        expect(pane.contains("themeSwitch.select("), "choosing a card skips the flow")
        expect(pane.contains("commands.previewThemeThen("), "choosing a card does not play the theme first")
        expect(pane.contains("themeSwitch.previewEnded("), "the end of the preview does not apply")
        expect(pane.contains("commands.previewTheme(theme)"), "▶ must still try without applying")
    }
}
