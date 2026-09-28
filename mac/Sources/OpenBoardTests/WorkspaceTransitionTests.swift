import Foundation
import OpenBoardKit

/**
 The workspace switch's light: the order things appear in, what cuts what off, and the
 color a workspace gets. All of it pure — the controller only sleeps and writes what
 `TransitionPlanner` says — so the timings of the design are checked here, not on a pad.
 */
func runWorkspaceTransitionTests() {
    let settings = Preferences.WorkspaceTransition()
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let workspace = BoardContext.superset(workspaceID: "ws-a")

    /// A tracker already past the launch-time switch, which never animates.
    func settledTracker() -> TransitionTracker {
        var tracker = TransitionTracker()
        _ = tracker.plan(
            generation: tracker.contextChanged(), now: t0.addingTimeInterval(-60), to: workspace,
            roles: [:], overflowKey: nil, settings: settings, reduceMotion: false, ringFree: true
        )
        return tracker
    }

    func plan(
        _ tracker: inout TransitionTracker, at seconds: Double,
        roles: [Int: TransitionPlanner.KeyRole] = [1: .session],
        overflowKey: Int? = nil,
        settings: Preferences.WorkspaceTransition = settings,
        reduceMotion: Bool = false,
        ringFree: Bool = true
    ) -> TransitionPlan? {
        tracker.plan(
            generation: tracker.contextChanged(), now: t0.addingTimeInterval(seconds), to: workspace,
            roles: roles, overflowKey: overflowKey, settings: settings,
            reduceMotion: reduceMotion, ringFree: ringFree
        )
    }

    func darkExcept(_ lit: Set<Int>) -> [Int: TransitionPlan.Look] {
        Dictionary(uniqueKeysWithValues: (1...6).map { ($0, lit.contains($0) ? .final : .dark) })
    }

    // MARK: - the sequence

    test("one session: the board goes dark in one write, then key 1 lights at 80ms") {
        var tracker = settledTracker()
        let result = try Harness.require(plan(&tracker, at: 0, roles: [1: .session]))
        expectEqual(result.kind, .cascade)
        expectEqual(result.ring, .sweep)
        expectEqual(result.frames, [
            .init(atMs: 0, keys: darkExcept([])),
            .init(atMs: 80, keys: [1: .final]),
        ])
    }

    test("two sessions and a borrowed prompt: the prompt is lit from the first frame") {
        var tracker = settledTracker()
        let result = try Harness.require(plan(
            &tracker, at: 0, roles: [1: .session, 2: .session, 6: .attention], overflowKey: 6
        ))
        expectEqual(result.frames, [
            // Attention is never dark, not even for the length of the count.
            .init(atMs: 0, keys: darkExcept([6])),
            .init(atMs: 80, keys: [1: .final]),
            .init(atMs: 150, keys: [2: .final]),
        ])
    }

    test("a borrowed key not already lit enters last, 150ms after the count") {
        let frames = TransitionPlanner.cascade(
            roles: [1: .session, 2: .session, 6: .session], overflowKey: 6, settings: settings
        )
        expectEqual(frames.map(\.atMs), [0, 80, 150, 300])
        expectEqual(frames.last?.keys, [6: .final])
    }

    test("five sessions count up 70ms apart and are all lit by 360ms") {
        let frames = TransitionPlanner.cascade(
            roles: [1: .session, 2: .session, 3: .session, 4: .session, 5: .session],
            overflowKey: nil, settings: settings
        )
        expectEqual(frames.map(\.atMs), [0, 80, 150, 220, 290, 360])
        expectEqual(frames.dropFirst().map { $0.keys.keys.first ?? 0 }, [1, 2, 3, 4, 5])
    }

    test("a local key needing a human is lit at once and left out of the count") {
        let frames = TransitionPlanner.cascade(
            roles: [1: .session, 2: .attention, 3: .session], overflowKey: nil, settings: settings
        )
        expectEqual(frames.first?.keys[2], .final)
        expectEqual(frames.map(\.atMs), [0, 80, 150])
        expectEqual(frames.dropFirst().map { $0.keys.keys.first ?? 0 }, [1, 3])
    }

    test("an empty workspace still sweeps, and lights nothing") {
        var tracker = settledTracker()
        let result = try Harness.require(plan(&tracker, at: 0, roles: [:]))
        expectEqual(result.ring, .sweep)
        expectEqual(result.frames, [.init(atMs: 0, keys: darkExcept([]))])
    }

    test("the sweep is one lap and a fade, all over in about 1.4s") {
        let show = Shows.workspaceSweep(color: RGB(0x9B30FF), settings: settings)
        let first = try Harness.require(show.steps.first)
        expectEqual(first.side.e, CodexProtocol.Effect.snake.rawValue)
        expectEqual(first.side.c, 0x9B30FF)
        expectEqual(first.side.b, 0.8)
        expectEqual(first.side.s, 0.55)
        expectEqual(first.milliseconds, 900)
        // Solid on the way down, like the laps, and dark at the end.
        expect(show.steps.dropFirst().dropLast().allSatisfy {
            $0.side.e == CodexProtocol.Effect.solid.rawValue && $0.milliseconds == 60
        })
        expectEqual(show.steps.last?.side.e, CodexProtocol.Effect.off.rawValue)
        let total = show.steps.reduce(0) { $0 + $1.milliseconds }
        expect((1300...1500).contains(total), "sweep lasts \(total)ms")
        // Shorter than every lap, so it can never pass for one.
        for name in ["completion", "question", "error"] {
            let lap = try Harness.require(Shows.show(named: name))
            expect(total < lap.steps.reduce(0) { $0 + $1.milliseconds }, "longer than \(name)")
        }
        expectEqual(ShowPriority.of(showNamed: show.name), .workspace)
    }

    // MARK: - switching fast

    test("a switch within 1500ms of the last paints directly, without a cascade") {
        var tracker = settledTracker()
        expectEqual(plan(&tracker, at: 0)?.kind, .cascade)
        let quick = try Harness.require(plan(&tracker, at: 1.0))
        expectEqual(quick.kind, .direct)
        expectEqual(quick.ring, .none)
        expectEqual(quick.frames.count, 1)
        expectEqual(quick.frames.first?.keys.values.allSatisfy { $0 == .final }, true)
        // Measured from the last transition that played, so a pause brings it back.
        expectEqual(plan(&tracker, at: 1.6)?.kind, .cascade)
    }

    test("the sweep does not repeat within 4s, though the keys still count") {
        var tracker = settledTracker()
        expectEqual(plan(&tracker, at: 0)?.ring, .sweep)
        let second = try Harness.require(plan(&tracker, at: 2))
        expectEqual(second.kind, .cascade)
        expectEqual(second.ring, .none)
        expectEqual(plan(&tracker, at: 4.1)?.ring, .sweep)
    }

    test("a switch superseded during its debounce plays nothing") {
        var tracker = settledTracker()
        let first = tracker.contextChanged()
        let second = tracker.contextChanged()
        let stale = tracker.plan(
            generation: first, now: t0, to: workspace, roles: [1: .session], overflowKey: nil,
            settings: settings, reduceMotion: false, ringFree: true
        )
        expect(stale == nil, "a superseded switch planned \(String(describing: stale))")
        expect(tracker.plan(
            generation: second, now: t0, to: workspace, roles: [1: .session], overflowKey: nil,
            settings: settings, reduceMotion: false, ringFree: true
        ) != nil)
    }

    test("the board arriving at launch, and leaving for a terminal, do not animate") {
        var tracker = TransitionTracker()
        expectEqual(plan(&tracker, at: 0)?.kind, .direct)
        let toAll = tracker.plan(
            generation: tracker.contextChanged(), now: t0.addingTimeInterval(10), to: .all,
            roles: [1: .session], overflowKey: nil, settings: settings,
            reduceMotion: false, ringFree: true
        )
        expectEqual(toAll?.kind, .direct)
        expectEqual(toAll?.ring, TransitionPlan.Ring.none)
    }

    test("a busy ring skips the sweep, never the count") {
        var tracker = settledTracker()
        let result = try Harness.require(plan(&tracker, at: 0, roles: [1: .session, 2: .session], ringFree: false))
        expectEqual(result.kind, .cascade)
        expectEqual(result.ring, .none)
        expectEqual(result.frames.count, 3)
    }

    // MARK: - no motion

    test("style off is a single write, nothing on the ring") {
        var tracker = settledTracker()
        var off = settings
        off.style = .off
        let result = try Harness.require(plan(&tracker, at: 0, roles: [1: .session, 2: .session], settings: off))
        expectEqual(result.kind, .direct)
        expectEqual(result.ring, .none)
        expectEqual(result.frames.count, 1)
    }

    test("Reduce Motion paints directly, unless told to ignore it") {
        var tracker = settledTracker()
        let reduced = try Harness.require(plan(&tracker, at: 0, reduceMotion: true))
        expectEqual(reduced.kind, .direct)
        expectEqual(reduced.ring, .none)
        expectEqual(reduced.frames.count, 1)

        var ignoring = settings
        ignoring.respectReduceMotion = false
        var other = settledTracker()
        expectEqual(plan(&other, at: 0, settings: ignoring, reduceMotion: true)?.kind, .cascade)
    }

    test("style cut is one write for the keys and a brief solid on the ring") {
        var tracker = settledTracker()
        var cut = settings
        cut.style = .cut
        let result = try Harness.require(plan(&tracker, at: 0, roles: [1: .session, 2: .session], settings: cut))
        expectEqual(result.kind, .direct)
        expectEqual(result.ring, .cut)
        expectEqual(result.frames.count, 1)
        expectEqual(Shows.workspaceCut(color: RGB(0x00C9A7)).steps.first?.side.e,
                    CodexProtocol.Effect.solid.rawValue)
    }

    // MARK: - interrupted

    test("a prompt arriving mid-cascade aborts it and the board is painted whole") {
        var tracker = settledTracker()
        let generation = tracker.contextChanged()
        let result = try Harness.require(tracker.plan(
            generation: generation, now: t0, to: workspace,
            roles: [1: .session, 2: .session, 3: .session], overflowKey: nil,
            settings: settings, reduceMotion: false, ringFree: true
        ))
        var playback = TransitionPlayback(result)
        var written: [TransitionPlan.Frame] = []
        func step() -> TransitionPlayback.Action {
            let action = playback.next(isCurrent: tracker.isCurrent(generation))
            if case let .write(frame) = action { written.append(frame) }
            return action
        }

        guard case .write = step() else { return expect(false, "frame 0 was not written first") }
        expectEqual(step(), .wait(untilMs: 80))
        guard case .write = step() else { return expect(false, "key 1 was not written") }
        expectEqual(step(), .wait(untilMs: 150))
        // Key 2 would be next; a session asks for a human instead.
        tracker.interrupt()
        expectEqual(step(), .abort)
        expectEqual(step(), .done)
        // Frame 0 and key 1, nothing after: keys 2 and 3 come from the repaint.
        expectEqual(written.count, 2)
        expectEqual(written.last?.keys, [1: .final])
    }

    test("a cascade played out ends in a full repaint") {
        var tracker = settledTracker()
        let result = try Harness.require(plan(&tracker, at: 0, roles: [1: .session, 2: .session]))
        guard result.frames.count == 3 else {
            return expect(false, "planned \(result.frames.count) frames, not 3")
        }
        var playback = TransitionPlayback(result)
        var actions: [TransitionPlayback.Action] = []
        for _ in 0..<10 {
            let action = playback.next(isCurrent: true)
            actions.append(action)
            if action == .done { break }
        }
        expectEqual(actions, [
            .write(result.frames[0]),
            .wait(untilMs: 80), .write(result.frames[1]),
            .wait(untilMs: 150), .write(result.frames[2]),
            .finish, .done,
        ])
    }

    // MARK: - priority

    test("a sweep never interrupts a prompt or a failure") {
        expectEqual(ShowArbiter.decide(incoming: .workspace, running: .error, voiceActive: false), .ignore)
        expectEqual(ShowArbiter.decide(incoming: .workspace, running: .question, voiceActive: false), .ignore)
        expectEqual(ShowArbiter.decide(incoming: .workspace, running: .workspace, voiceActive: false), .ignore)
    }

    test("a prompt or a failure cuts a sweep off") {
        expectEqual(ShowArbiter.decide(incoming: .error, running: .workspace, voiceActive: false), .preempt)
        expectEqual(ShowArbiter.decide(incoming: .question, running: .workspace, voiceActive: false), .preempt)
        expectEqual(ShowArbiter.decide(incoming: .error, running: .question, voiceActive: false), .preempt)
        // And a sweep outranks only the completion lap.
        expectEqual(ShowArbiter.decide(incoming: .workspace, running: .completion, voiceActive: false), .preempt)
        expectEqual(ShowArbiter.decide(incoming: .completion, running: .workspace, voiceActive: false), .ignore)
        expectEqual(ShowArbiter.decide(incoming: .workspace, running: nil, voiceActive: false), .start)
    }

    test("nothing plays over dictation") {
        for incoming in [ShowPriority.completion, .workspace, .manual, .question, .error] {
            expectEqual(ShowArbiter.decide(incoming: incoming, running: nil, voiceActive: true), .ignore)
        }
    }

    test("each show carries its rank") {
        expectEqual(ShowPriority.of(showNamed: "completion"), .completion)
        expectEqual(ShowPriority.of(showNamed: "question"), .question)
        expectEqual(ShowPriority.of(showNamed: "error"), .error)
        expectEqual(ShowPriority.of(showNamed: "rainbow"), .manual)
        expectEqual(ShowPriority.of(showNamed: "confirm"), .confirm)
        expectEqual(ShowPriority.of(showNamed: "no-workspace"), .confirm)
        expectEqual(ShowPriority.of(showNamed: "targeted"), .confirm)
        expectEqual(ShowPriority.of(showNamed: "refused"), .confirm)
        expectEqual(Shows.targetArmed(color: RGB(0xFFFFFF), brightness: 0.8, milliseconds: 3000).name, "targeted")
        expectEqual(
            Shows.targetArmed(color: RGB(0xFFFFFF), brightness: 0.8, milliseconds: 3000).steps.reduce(0) { $0 + $1.milliseconds },
            3000
        )
        expectEqual(Shows.refused().name, "refused")
        let order: [ShowPriority] = [.completion, .workspace, .manual, .confirm, .question, .error, .voice]
        expectEqual(order, order.sorted())
    }

    // MARK: - two-step confirmation (F4)

    test("confirm loses to a prompt and a failure, and beats a workspace sweep") {
        expectEqual(ShowArbiter.decide(incoming: .question, running: .confirm, voiceActive: false), .preempt)
        expectEqual(ShowArbiter.decide(incoming: .error, running: .confirm, voiceActive: false), .preempt)
        expectEqual(ShowArbiter.decide(incoming: .confirm, running: .question, voiceActive: false), .ignore)
        expectEqual(ShowArbiter.decide(incoming: .confirm, running: .error, voiceActive: false), .ignore)
        expectEqual(ShowArbiter.decide(incoming: .confirm, running: .workspace, voiceActive: false), .preempt)
        expectEqual(ShowArbiter.decide(incoming: .confirm, running: .completion, voiceActive: false), .preempt)
        expectEqual(ShowArbiter.decide(incoming: .confirm, running: nil, voiceActive: false), .start)
    }

    test("confirm is not interrupted by a workspace sweep") {
        // A switch while the ring asks "are you sure?" must not wipe the question.
        expectEqual(ShowArbiter.decide(incoming: .workspace, running: .confirm, voiceActive: false), .ignore)
        expectEqual(ShowArbiter.decide(incoming: .completion, running: .confirm, voiceActive: false), .ignore)
    }

    test("the confirm show holds the whole window in the configured look, then hands the ring back") {
        let show = Shows.confirm(color: RGB(0xFFFFFF), effect: .breath, brightness: 0.8, milliseconds: 3000)
        expectEqual(show.name, "confirm")
        expectEqual(ShowPriority.of(showNamed: show.name), .confirm)
        expect(show.auto)
        let first = try Harness.require(show.steps.first)
        expectEqual(first.side.c, 0xFFFFFF)
        expectEqual(first.side.e, CodexProtocol.Effect.breath.rawValue)
        expectEqual(first.side.b, 0.8)
        expectEqual(show.steps.reduce(0) { $0 + $1.milliseconds }, 3000, "the light lasts exactly the window")
        expectEqual(show.steps.last?.side.e, CodexProtocol.Effect.off.rawValue)
    }

    test("the no-workspace blink is amber, brief and not the awaiting look") {
        let show = Shows.noWorkspace()
        expectEqual(show.name, "no-workspace")
        expect(show.duration.seconds <= 1.5, "a blink, not a state")
        let lit = show.steps.filter { $0.side.e != CodexProtocol.Effect.off.rawValue }
        expect(!lit.isEmpty)
        for step in lit {
            expectEqual(step.side.c, Shows.amber.value)
            // Awaiting breathes; the blink is solid pulses, so the two never read alike.
            expectEqual(step.side.e, CodexProtocol.Effect.solid.rawValue)
        }
        expectEqual(show.steps.last?.side.e, CodexProtocol.Effect.off.rawValue)
    }

    test("the ring is not free over dictation, in off, or while aggregate holds a prompt") {
        let appearances = SessionState.defaultAppearances
        expect(TransitionPlanner.ringFree(
            mode: .events, ringStates: [.awaiting], appearances: appearances, voiceActive: false
        ))
        expect(!TransitionPlanner.ringFree(
            mode: .events, ringStates: [], appearances: appearances, voiceActive: true
        ))
        expect(!TransitionPlanner.ringFree(
            mode: .off, ringStates: [], appearances: appearances, voiceActive: false
        ))
        expect(!TransitionPlanner.ringFree(
            mode: .aggregate, ringStates: [.working, .error], appearances: appearances, voiceActive: false
        ))
        expect(TransitionPlanner.ringFree(
            mode: .aggregate, ringStates: [.working, .done], appearances: appearances, voiceActive: false
        ))
    }

    // MARK: - identity

    let identity = Preferences.WorkspaceIdentity()
    let stateColors = SessionState.defaultAppearances.values.map(\.color)

    test("a workspace's color is stable, and keyed by id") {
        // FNV-1a's published value for "a": a hash seeded per process would fail this.
        expectEqual(WorkspaceColors.fnv1a("a"), 0xE40C_292C)
        let first = WorkspaceColors.color(for: "7f3c-workspace", identity: identity, stateColors: stateColors)
        let again = WorkspaceColors.color(for: "7f3c-workspace", identity: identity, stateColors: stateColors)
        expectEqual(first, again)
        expect(identity.palette.contains(first))
        // Different ids spread over the palette rather than collapsing onto one color.
        let spread = Set((0..<40).map {
            WorkspaceColors.color(for: "ws-\($0)", identity: identity, stateColors: stateColors).value
        })
        expectEqual(spread.count, identity.palette.count)
    }

    test("a pinned color wins over the palette") {
        var pinned = identity
        pinned.colors["7f3c-workspace"] = RGB(0x123456)
        expectEqual(
            WorkspaceColors.color(for: "7f3c-workspace", identity: pinned, stateColors: stateColors),
            RGB(0x123456)
        )
        // Only for that workspace.
        expect(WorkspaceColors.color(for: "other", identity: pinned, stateColors: stateColors) != RGB(0x123456))
    }

    test("the palette holds no state color, and keeps its distance from their hues") {
        for candidate in Preferences.WorkspaceIdentity.defaultPalette {
            for state in stateColors {
                expect(candidate != state, "\(candidate.hex) is a state color")
                guard let a = WorkspaceColors.hue(of: candidate), let b = WorkspaceColors.hue(of: state)
                else { continue }
                let gap = min(abs(a - b), 360 - abs(a - b))
                expect(gap >= 30, "\(candidate.hex) is \(Int(gap))° from \(state.hex)")
            }
        }
        // A hand-edited palette naming a state color never hands it out.
        var edited = identity
        edited.palette = [RGB(0xFF6A00), RGB(0xD41145), RGB(0xFF7A10), RGB(0x9B30FF)]
        let colors = Set((0..<40).map {
            WorkspaceColors.color(for: "ws-\($0)", identity: edited, stateColors: stateColors)
        }.map(\.value))
        expectEqual(colors, [0x9B30FF])
    }

    // MARK: - the borrowed key

    test("the borrowed key keeps its state's color, and holds still") {
        let awaiting = SessionState.defaultAppearances[.awaiting]!
        let look = OverflowLook.appearance(awaiting, settings: Preferences.Overflow())
        expectEqual(look.color, awaiting.color)
        expectEqual(look.effect, .solid)
        expectEqual(look.brightness, 0.6)
        let wink = OverflowLook.wink(origin: RGB(0x00C9A7), settings: Preferences.Overflow())
        expectEqual(wink.color, RGB(0x00C9A7))
        expect(OverflowLook.winkAllowed(
            settings: .init(), transition: settings, reduceMotion: false
        ))
        expect(!OverflowLook.winkAllowed(
            settings: .init(), transition: settings, reduceMotion: true
        ))
    }

    // MARK: - one call per repaint

    test("a repaint is one thstatus carrying all six keys") {
        let pad = VirtualPad()
        let looks = Dictionary(uniqueKeysWithValues: (1...6).map { key in
            (key, Appearance(color: RGB(UInt32(key) * 0x10), effect: .solid, brightness: 0.5))
        })
        let result = PadPaint.keyBatch(looks, calibration: .identity, transport: pad)
        expectEqual(result.batch.count, 1)
        expectEqual(result.written, 6)
        guard case let .threads(threads, _)? = PadFrames.decode(result.batch[0]) else {
            return expect(false, "the batch did not decode as one thstatus")
        }
        expectEqual(threads.map(\.slot), [1, 2, 3, 4, 5, 6])
        expectEqual(threads.map(\.color), [0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
    }

    test("the batched repaint still goes through the calibration, and skips what it lacks") {
        let pad = VirtualPad()
        let swapped = Calibration(mapping: [1: 2, 2: 1])
        let looks: [Int: Appearance] = [
            1: Appearance(color: RGB(0xAA0000), effect: .solid, brightness: 1),
            2: Appearance(color: RGB(0x00AA00), effect: .solid, brightness: 1),
            3: Appearance(color: RGB(0x0000AA), effect: .solid, brightness: 1),
        ]
        let result = PadPaint.keyBatch(looks, calibration: swapped, transport: pad)
        expectEqual(result.skipped, 1)
        guard case let .threads(threads, _)? = result.batch.first.flatMap(PadFrames.decode) else {
            return expect(false, "no thstatus")
        }
        expectEqual(threads.first { $0.slot == 2 }?.color, 0xAA0000)
        expectEqual(threads.first { $0.slot == 1 }?.color, 0x00AA00)
        expectEqual(PadPaint.keyBatch([:], calibration: .identity, transport: pad).batch.count, 0)
    }

    // MARK: - configuration

    test("the three new groups default to the design's values") {
        let t = Preferences.default.workspaceTransition
        expectEqual(t.style, .sweepCascade)
        expectEqual(t.respectReduceMotion, true)
        expectEqual(
            [t.debounceMs, t.rapidWindowMs, t.keyStaggerMs, t.firstKeyDelayMs, t.overflowDelayMs,
             t.ringHoldMs, t.ringFadeSteps, t.ringFadeStepMs, t.minSweepIntervalMs],
            [150, 1500, 70, 80, 150, 900, 8, 60, 4000]
        )
        expectEqual(t.ringSweep, true)
        expectEqual(t.ringSpeed, 0.55)
        expectEqual(t.ringBrightness, 0.8)

        let identity = Preferences.default.workspaceIdentity
        expectEqual(identity.palette.map(\.value), [10_170_623, 51623, 11_855_360, 14_083_327])
        expect(identity.colors.isEmpty)

        let overflow = Preferences.default.overflow
        expectEqual(overflow.enabled, true)
        expectEqual(overflow.effect, .solid)
        expectEqual(overflow.brightness, 0.6)
        expectEqual(overflow.winkEveryMs, 3000)
        expectEqual(overflow.winkMs, 250)
        expectEqual(overflow.winkOriginColor, true)

        // An old document, with none of them, gets the same.
        let old = Preferences.merging(["padScope": "all"])
        expectEqual(old.workspaceTransition, t)
        expectEqual(old.workspaceIdentity, identity)
        expectEqual(old.overflow, overflow)
    }

    test("the new groups merge field by field, and reject what they cannot play") {
        let merged = Preferences.merging([
            "workspaceTransition": ["keyStaggerMs": 90, "style": "wave", "debounceMs": -5],
            "workspaceIdentity": ["colors": ["ws-a": "#123456", "ws-b": 0x00FF00]],
            "overflow": ["brightness": 0.4, "effect": "breath"],
        ])
        expectEqual(merged.workspaceTransition.keyStaggerMs, 90)
        // Designed and not built: ignored, not taken to mean off.
        expectEqual(merged.workspaceTransition.style, .sweepCascade)
        expectEqual(merged.workspaceTransition.debounceMs, 0)
        expectEqual(merged.workspaceTransition.firstKeyDelayMs, 80)
        expectEqual(merged.workspaceIdentity.colors["ws-a"], RGB(0x123456))
        expectEqual(merged.workspaceIdentity.colors["ws-b"], RGB(0x00FF00))
        expectEqual(merged.workspaceIdentity.palette, Preferences.WorkspaceIdentity.defaultPalette)
        expectEqual(merged.overflow.brightness, 0.4)
        expectEqual(merged.overflow.effect, .breath)
        expectEqual(merged.overflow.winkMs, 250)
    }

    test("the new groups survive a save and reload") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openboard-transition-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var prefs = Preferences.default
        prefs.workspaceTransition.style = .cut
        prefs.workspaceTransition.ringSpeed = 0.4
        prefs.workspaceTransition.minSweepIntervalMs = 2500
        prefs.workspaceIdentity.palette = [RGB(0x9B30FF), RGB(0x00C9A7)]
        prefs.workspaceIdentity.colors = ["ws-a": RGB(0xB4E600)]
        prefs.overflow.enabled = false
        prefs.overflow.winkEveryMs = 5000
        PreferencesStore().save(prefs, url: url, immediately: true)
        let reloaded = PreferencesStore().load(url: url)
        expectEqual(reloaded.workspaceTransition, prefs.workspaceTransition)
        expectEqual(reloaded.workspaceIdentity, prefs.workspaceIdentity)
        expectEqual(reloaded.overflow, prefs.overflow)
        // Colors as numbers, like every other color in the file.
        let written = prefs.json["workspaceIdentity"] as? [String: Any]
        expectEqual((written?["colors"] as? [String: Int])?["ws-a"], 0xB4E600)
    }

    test("the borrowed key can be switched off entirely") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "mine", cwd: nil, pid: 1, state: .working, isAlive: { _ in true })
        registry.enrich(sessionID: "mine", supersetWorkspaceID: "ws-a")
        _ = registry.claim(sessionID: "theirs", cwd: nil, pid: 2, state: .awaiting, isAlive: { _ in true })
        registry.enrich(sessionID: "theirs", supersetWorkspaceID: "ws-b")
        let context = BoardContext.superset(workspaceID: "ws-a")

        let lent = PadView.compose(entries: registry.entries, context: context)
        expectEqual(lent.overflowKey, 6)
        let kept = PadView.compose(entries: registry.entries, context: context, borrowOverflow: false)
        expect(kept.overflowKey == nil)
        expect(kept.keys[6] == nil)
    }

    // MARK: - the state flash and the animation speed

    let orange = Appearance(color: RGB(0xFF6A00), effect: .shallowBreath, brightness: 0.95, speed: 0.75)
    let blue = Appearance(color: RGB(0x0C47E9), effect: .shallowBreath, brightness: 0.75, speed: 0.45)
    let green = Appearance(color: RGB(0x09B821), effect: .shallowBreath, brightness: 0.7, speed: 0.25)
    func solid(_ look: Appearance) -> Appearance {
        Appearance(color: look.color, effect: .solid, brightness: 1, speed: 0)
    }
    func at(_ ms: Int) -> Date { t0.addingTimeInterval(Double(ms) / 1000) }

    test("flash: a key that changes state shows its new color solid at full brightness") {
        var flash = StateFlash()
        _ = flash.apply([1: blue, 2: blue], states: [1: .init("a", .working), 2: .init("b", .working)], now: at(0))
        let out = flash.apply([1: orange, 2: blue], states: [1: .init("a", .awaiting), 2: .init("b", .working)], now: at(500))
        expectEqual(out[1], solid(orange))
        expectEqual(out[2], blue, "unchanged key keeps its look")
        expectEqual(flash.until, at(850), "~350 ms")
    }

    test("flash: the next step after it lapses goes back to the key's own look") {
        var flash = StateFlash()
        _ = flash.apply([1: blue], states: [1: .init("a", .working)], now: at(0))
        _ = flash.apply([1: orange], states: [1: .init("a", .awaiting)], now: at(500))
        let during = flash.apply([1: orange], states: [1: .init("a", .awaiting)], now: at(700))
        expectEqual(during[1], solid(orange), "still inside the flash")
        let after = flash.apply([1: orange], states: [1: .init("a", .awaiting)], now: at(860))
        expectEqual(after[1], orange)
        expect(flash.until == nil)
    }

    test("flash: keys that change together share one flash") {
        var flash = StateFlash()
        _ = flash.apply([1: blue, 2: blue, 3: blue],
                        states: [1: .init("a", .working), 2: .init("b", .working), 3: .init("c", .working)], now: at(0))
        let out = flash.apply([1: orange, 2: green, 3: blue],
                              states: [1: .init("a", .awaiting), 2: .init("b", .done), 3: .init("c", .working)], now: at(100))
        expectEqual(out[1], solid(orange))
        expectEqual(out[2], solid(green))
        expectEqual(out[3], blue)
        expectEqual(flash.until, at(450), "one deadline for both")
        let back = flash.apply([1: orange, 2: green, 3: blue],
                               states: [1: .init("a", .awaiting), 2: .init("b", .done), 3: .init("c", .working)], now: at(460))
        expectEqual(back, [1: orange, 2: green, 3: blue])
    }

    test("flash: nothing on the first paint, on a new session in the key, or on a dark key") {
        var flash = StateFlash()
        let first = flash.apply([1: blue], states: [1: .init("a", .working)], now: at(0))
        expectEqual(first[1], blue, "launch: nothing changed, it was never seen")
        // A workspace switch puts another session on the key: the cascade owns that.
        let swapped = flash.apply([1: orange], states: [1: .init("x", .awaiting)], now: at(100))
        expectEqual(swapped[1], orange)
        let ended = flash.apply([1: .off], states: [1: .init("x", .ended)], now: at(200))
        expectEqual(ended[1], .off, "a dark key stays dark")
    }

    test("animation speed: fast by default, and it scales effect speed without passing 1") {
        expectEqual(Preferences.default.animationSpeed, .fast)
        expectEqual(AnimationSpeed.normal.look(blue), blue)
        let fast = AnimationSpeed.fast.look(blue)
        expect(abs(fast.speed - blue.speed * AnimationSpeed.fast.factor) < 1e-9, "\(fast.speed)")
        expectEqual(fast.color, blue.color)
        expectEqual(fast.brightness, blue.brightness)
        expectEqual(AnimationSpeed.veryFast.look(orange).speed, 1, "clamped to the device's range")
        expect(AnimationSpeed.fast.factor > 1)
        expect(AnimationSpeed.veryFast.factor > AnimationSpeed.fast.factor)
    }

    test("animation speed: with speeds already high it clamps at 1, and the flash still shows") {
        let high = Appearance(color: RGB(0x0C47E9), effect: .shallowBreath, brightness: 0.75, speed: 0.8)
        for speed in AnimationSpeed.allCases {
            let painted = speed.look(high)
            expect(painted.speed <= 1, "\(speed): \(painted.speed)")
            expect(painted.speed >= high.speed, "\(speed) never slows it")
        }
        expectEqual(AnimationSpeed.fast.look(high).speed, 1)
        var flash = StateFlash()
        let fast = AnimationSpeed.fast.look(high)
        _ = flash.apply([1: fast], states: [1: .init("a", .idle)], now: at(0))
        let out = flash.apply([1: fast], states: [1: .init("a", .working)], now: at(100))
        expectEqual(out[1], solid(fast), "solid 1.0 whatever the configured speed")
        let question = try Harness.require(Shows.show(named: "question"))
        let paced = Shows.paced(question, speed: .fast)
        expect(paced.duration < question.duration, "the lap is shorter even when its speed clamps")
        for step in paced.steps { expect(step.side.s <= 1) }
    }

    test("animation speed: the ring's laps get shorter in proportion, the others do not") {
        for name in ["completion", "question", "error"] {
            let show = try Harness.require(Shows.show(named: name))
            let paced = Shows.paced(show, speed: .fast)
            let expected = show.duration.seconds / AnimationSpeed.fast.factor
            // Each step rounds to a whole millisecond.
            expect(abs(paced.duration.seconds - expected) < 0.001 * Double(show.steps.count), "\(name) \(paced.duration.seconds) vs \(expected)")
            expectEqual(Shows.paced(show, speed: .normal).duration, show.duration, name)
        }
        let sweep = Shows.workspaceSweep(color: RGB(0x00FF00), settings: settings)
        expect(Shows.paced(sweep, speed: .veryFast).duration < sweep.duration, "workspace sweep")
        let rainbow = try Harness.require(Shows.show(named: "rainbow"))
        expectEqual(Shows.paced(rainbow, speed: .veryFast).duration, rainbow.duration, "picked by hand: untouched")
        let confirm = Shows.confirm(color: RGB(0xFFB000), effect: .breath, brightness: 1, milliseconds: 3000)
        expectEqual(Shows.paced(confirm, speed: .veryFast).duration, confirm.duration, "tied to the confirm window")
    }
}
