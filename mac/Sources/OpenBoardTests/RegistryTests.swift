import Foundation
import OpenBoardKit

/**
 Slot allocation, which is where a board learns to lie.

 Every rule here exists because of a specific failure: a tab burning a key on every
 `/clear`, a dead session holding a light, an orange key stolen to show something
 nobody asked about. The tests are written against those failures rather than against
 the implementation.
 */
func runRegistryTests() {
    // F7 lives with the registry tests: keys → sessions → a terminal (no suite of its own).
    targetedControlChecks()
    let alwaysAlive: (Int?) -> Bool = { _ in true }
    let neverAlive: (Int?) -> Bool = { _ in false }

    test("a new session takes the lowest free slot") {
        var registry = SessionRegistry()
        for expected in 1...6 {
            let result = registry.claim(
                sessionID: "s\(expected)", pid: expected, isAlive: alwaysAlive
            )
            expectEqual(result.entry?.slot, expected)
            expectEqual(result.mode, .unused)
        }
    }

    test("a known session keeps its slot rather than taking another") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        let again = registry.claim(sessionID: "a", pid: 1, state: .working, isAlive: alwaysAlive)
        expectEqual(again.mode, .kept)
        expectEqual(again.entry?.slot, 1)
        expectEqual(again.entry?.state, .working)
        expectEqual(registry.entries.count, 1)
    }

    test("one tab, one key — a cleared session reuses its own slot") {
        // `/clear` mints a fresh session_id inside the same process. Without this a
        // single tab burns another key every time and the board fills with dead
        // entries for a window you never left.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "before", pid: 100, tty: "/dev/ttys001", isAlive: neverAlive)
        let after = registry.claim(
            sessionID: "after", pid: 100, tty: "/dev/ttys001", isAlive: neverAlive
        )
        expectEqual(after.mode, .sameHost)
        expectEqual(after.entry?.slot, 1)
        expectEqual(registry.entries.count, 1, "the old entry is replaced, not kept alongside")
    }

    test("a cleared session in a still-running process reuses its own slot") {
        // `/clear` keeps the same Claude process, so its pid is alive — that liveness
        // is the new session's. Requiring the old entry to look dead left a ghost key
        // for the pre-clear session, with a jump landing in the same tab as the new one.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "before", pid: 100, tty: "/dev/ttys001", isAlive: alwaysAlive)
        let after = registry.claim(
            sessionID: "after", pid: 100, tty: "/dev/ttys001", isAlive: alwaysAlive
        )
        expectEqual(after.mode, .sameHost)
        expectEqual(after.entry?.slot, 1)
        expectEqual(registry.entries.count, 1, "no ghost key for the pre-clear session")
    }

    test("/clear keeps the session's place in the board order") {
        // The pad is drawn sorted by `boardOrder`, not by registry slot. A `/clear`
        // is the same tab, so it must stay where it was on the pad — inheriting the
        // order, not taking a new one and jumping to the end. The slot is freed and
        // re-used first so the slot number and the order disagree, and a
        // `boardOrder` that merely mirrors the slot is caught.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.claim(sessionID: "b", pid: 2, isAlive: alwaysAlive)
        registry.release(sessionID: "a")
        let c = try Harness.require(registry.claim(sessionID: "c", pid: 3, isAlive: alwaysAlive).entry)
        expectEqual(c.slot, 1)
        let cleared = registry.claim(sessionID: "c2", pid: 3, isAlive: alwaysAlive)
        expectEqual(cleared.mode, .sameHost)
        expectEqual(cleared.entry?.boardOrder, c.boardOrder, "the cleared tab moved on the pad")
        expect((cleared.entry?.boardOrder ?? 0) > (registry.entry(forSession: "b")?.boardOrder ?? .max),
               "c was claimed after b, so it stays after b")
    }

    test("a new session goes last even when it takes a freed low slot") {
        // Registry slots are reused lowest-first; the pad must not follow them, or a
        // new session pushes every existing one a key to the right.
        var registry = SessionRegistry()
        for (index, id) in ["a", "b", "c"].enumerated() {
            _ = registry.claim(sessionID: id, pid: index + 1, isAlive: alwaysAlive)
        }
        registry.release(sessionID: "a")
        let d = try Harness.require(registry.claim(sessionID: "d", pid: 9, isAlive: alwaysAlive).entry)
        expectEqual(d.slot, 1, "the registry still reuses the lowest free slot")
        let order = registry.entries.sorted { $0.boardOrder < $1.boardOrder }.map(\.sessionID)
        expectEqual(order, ["b", "c", "d"])
    }

    test("a live session sharing a tty does not lose its key") {
        // A tty match alone (a different process in the same tab) only reuses a
        // session that is genuinely finished or gone; otherwise it would steal a key
        // from something still running.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "live", pid: 100, tty: "/dev/ttys001", isAlive: alwaysAlive)
        let other = registry.claim(
            sessionID: "new", pid: 200, tty: "/dev/ttys001", isAlive: alwaysAlive
        )
        expectEqual(other.mode, .unused, "must take a fresh slot")
        expectEqual(other.entry?.slot, 2)
        expectEqual(registry.entries.count, 2)
    }

    test("a full board reclaims the oldest finished session") {
        var registry = SessionRegistry()
        for i in 1...6 { _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive) }
        registry.markEnded(sessionID: "s3")

        let result = registry.claim(sessionID: "new", pid: 99, isAlive: alwaysAlive)
        expectEqual(result.mode, .reclaimed)
        expectEqual(result.entry?.slot, 3)
    }

    test("eviction never takes a key that is asking for attention") {
        // Stealing the orange key to show something nobody asked about is the single
        // worst thing this could do — it destroys the one signal the product exists
        // to deliver.
        var registry = SessionRegistry()
        for i in 1...6 { _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive) }
        registry.setState(sessionID: "s1", to: .awaiting, pendingTool: "Bash")
        registry.setState(sessionID: "s2", to: .stalled)

        let result = registry.claim(sessionID: "new", pid: 99, isAlive: alwaysAlive)
        expectEqual(result.mode, .evicted)
        expect(result.entry?.slot != 1, "must not evict the awaiting key")
        expect(result.entry?.slot != 2, "must not evict the stalled key")
        expectEqual(registry.entry(forSession: "s1")?.state, .awaiting)
    }

    test("a board where every key is waiting fails dark") {
        // Better to give the new session nothing than to take the light someone
        // needs in order to see.
        var registry = SessionRegistry()
        for i in 1...6 {
            _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive)
            registry.setState(sessionID: "s\(i)", to: .awaiting)
        }
        let result = registry.claim(sessionID: "new", pid: 99, isAlive: alwaysAlive)
        expectEqual(result.mode, .noSlot)
        expect(result.entry == nil)
        expectEqual(registry.entries.count, 6, "nothing was disturbed")
    }

    test("leaving an attention state clears what was pending") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        registry.setState(sessionID: "a", to: .awaiting, pendingTool: "AskUserQuestion")
        expectEqual(registry.entry(forSession: "a")?.pendingTool, "AskUserQuestion")

        registry.setState(sessionID: "a", to: .working)
        expect(registry.entry(forSession: "a")?.pendingTool == nil, "nothing is pending now")
    }

    test("a session already in progress can be adopted") {
        // The registry is rebuilt from hooks and SessionStart fires once, so a session
        // that was already running when the app started would otherwise stay invisible
        // forever. Observed for real: hooks arriving normally while the board reported
        // zero sessions.
        var registry = SessionRegistry()
        expect(registry.setState(sessionID: "already-running", to: .working) == nil,
               "setState alone must not create it")

        let adopted = registry.claim(
            sessionID: "already-running", cwd: "/tmp", state: .working, isAlive: alwaysAlive
        )
        expectEqual(adopted.mode, .unused)
        expectEqual(registry.entry(forSession: "already-running")?.state, .working)
    }

    test("an unknown session is ignored, not given a key") {
        var registry = SessionRegistry()
        expect(registry.setState(sessionID: "ghost", to: .working) == nil)
        expectEqual(registry.entries.count, 0, "a stray event must not claim a slot")
    }

    test("a dead process does not keep its light") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.claim(sessionID: "b", pid: 2, isAlive: alwaysAlive)
        expectEqual(registry.prune(isAlive: { $0 == 1 }), 1)
        expect(registry.entry(forSession: "b") == nil)
        expect(registry.entry(forSession: "a") != nil)
    }

    test("done holds; awaiting expires") {
        // Reversed from the original rule, on purpose. `done` used to age out after 90s
        // on the reasoning that permanent green stops meaning anything. That traded away
        // the more valuable signal: a session that finished while you were elsewhere is
        // exactly the one you need to be told about, and a timer makes the board forget
        // it before you look. Green now clears when you go back and send something.
        var registry = SessionRegistry()
        let start = Date()
        _ = registry.claim(sessionID: "a", pid: 1, now: start, isAlive: alwaysAlive)
        registry.setState(sessionID: "a", to: .done, now: start)
        _ = registry.claim(sessionID: "b", pid: 2, now: start, isAlive: alwaysAlive)
        registry.setState(sessionID: "b", to: .awaiting, now: start)

        // Two minutes on, nothing has changed.
        expectEqual(registry.decay(now: start.addingTimeInterval(120)), 0)
        expectEqual(registry.entry(forSession: "a")?.state, .done)
        expectEqual(registry.entry(forSession: "b")?.state, .awaiting)

        // Twenty minutes on, both are still lit. Attention is held by default now: the
        // hooks clear it the moment the prompt is answered, and a deadline for a prompt
        // that is never answered is a question nobody can answer in minutes.
        expectEqual(registry.decay(now: start.addingTimeInterval(1200)), 0)
        expectEqual(registry.entry(forSession: "b")?.state, .awaiting)
        expectEqual(registry.entry(forSession: "a")?.state, .done, "green cleared itself")

        // Asked for, the old safety net comes back at a fixed 15 minutes.
        expectEqual(
            registry.decay(holdAttention: false, now: start.addingTimeInterval(1200)), 1
        )
        expectEqual(registry.entry(forSession: "b")?.state, .idle)
        expect(registry.entry(forSession: "b")?.pendingTool == nil)
    }

    test("reset forgets everything") {
        var registry = SessionRegistry()
        for i in 1...6 { _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive) }
        registry.reset()
        expectEqual(registry.entries.count, 0)
        // The cursor resets too, or the next claim looks arbitrarily old.
        let result = registry.claim(sessionID: "fresh", pid: 1, isAlive: alwaysAlive)
        expectEqual(result.entry?.slot, 1)
        expectEqual(result.entry?.claimSeq, 1)
    }

    test("occupancy always reports all six slots") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        let rows = registry.occupancy()
        expectEqual(rows.count, 6)
        expectEqual(rows[0].entry?.sessionID, "a")
        expect(rows[1].entry == nil)
    }

    // MARK: - event mapping

    test("hook events map to the states the Node version used") {
        expectEqual(EventMapper.state(for: "SessionStart"), .idle)
        expectEqual(EventMapper.state(for: "UserPromptSubmit"), .working)
        expectEqual(EventMapper.state(for: "Stop"), .done)
        expectEqual(EventMapper.state(for: "SessionEnd"), .ended)
        expectEqual(EventMapper.state(for: "StopFailure"), .error)
        // Fires the instant a prompt appears; the equivalent Notification lags it by
        // about six seconds, measured.
        expectEqual(EventMapper.state(for: "PermissionRequest"), .awaiting)
        expect(EventMapper.state(for: "SomethingElse") == nil)
    }

    test("idle_prompt stays unmapped") {
        // It means "sitting idle", not "needs you". Mapping it lights the attention
        // color with nothing to act on, which teaches you to ignore the one color
        // that must never be ignored.
        expect(EventMapper.state(for: "Notification", matcher: "idle_prompt") == nil)
        expectEqual(EventMapper.state(for: "Notification", matcher: "permission_prompt"), .awaiting)
        expectEqual(EventMapper.state(for: "Notification", matcher: "agent_needs_input"), .awaiting)
        // Not per-session status: these are about the app, not about a key.
        expect(EventMapper.state(for: "Notification", matcher: "agent_completed") == nil)
        expect(EventMapper.state(for: "Notification", matcher: "auth_success") == nil)
    }

    test("a muted event repaints nothing") {
        // Muting is a supported configuration, not a failure — so it returns nil
        // exactly like an unrecognised event.
        expect(EventMapper.state(for: "Stop", enabledEvents: ["Stop": false]) == nil)
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: ["Stop": true]), .done)
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: [:]), .done, "absent means enabled")
    }

    test("every event the installer registers is understood") {
        // A toggle for an event nothing handles would be a lie in the settings window.
        let installed = [
            "SessionStart", "UserPromptSubmit", "Notification", "Stop",
            "SessionEnd", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
        ]
        for event in installed where event != "Notification" {
            expect(EventMapper.state(for: event) != nil, "\(event) maps to nothing")
        }
        // Notification needs a matcher, and carries its own map.
        expect(EventMapper.state(for: "Notification") == nil)
    }

    test("adjustDelegation on SubagentStart inserts the agent id, and ignores an unknown session") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-1")
        expectEqual(registry.entry(forSession: "a")?.delegatingAgentIDs, ["agent-1"])
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-2")
        expectEqual(registry.entry(forSession: "a")?.delegatingAgentIDs, ["agent-1", "agent-2"])
        // Inserting the same id twice must not double-count (a set, not a counter).
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-1")
        expectEqual(registry.entry(forSession: "a")?.delegatingAgentIDs.count, 2)

        // An unknown session_id never allocates a slot — mirrors setState's own rule.
        let before = registry.entries.count
        let result = registry.adjustDelegation(
            sessionID: "ghost", event: "SubagentStart", agentID: "agent-1"
        )
        expect(result == nil, "an unknown session must not be given a key")
        expectEqual(registry.entries.count, before)
    }

    test("adjustDelegation on SubagentStart with a missing agent_id is a no-op") {
        // Documented degrade: an unmatchable insert could never be removed
        // by its own SubagentStop, so it is skipped rather than fabricating an id —
        // the next Stop's reconcile remains authoritative regardless.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: nil)
        expect(registry.entry(forSession: "a")?.delegatingAgentIDs.isEmpty == true)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "")
        expect(registry.entry(forSession: "a")?.delegatingAgentIDs.isEmpty == true)
    }

    test("adjustDelegation on SubagentStop removes the agent id; removing an absent id is a no-op") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-1")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-2")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStop", agentID: "agent-1")
        expectEqual(registry.entry(forSession: "a")?.delegatingAgentIDs, ["agent-2"])
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStop", agentID: "agent-2")
        expect(registry.entry(forSession: "a")?.delegatingAgentIDs.isEmpty == true)
        // Duplicate/unknown SubagentStop delivery must not error or resurrect anything.
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStop", agentID: "agent-2")
        expect(registry.entry(forSession: "a")?.delegatingAgentIDs.isEmpty == true)

        expect(
            registry.adjustDelegation(sessionID: "ghost", event: "SubagentStop", agentID: "agent-1")
                == nil,
            "an unknown session must not be given a key"
        )
    }

    test("the late-SubagentStop race: a SubagentStop for an already-reconciled-away agent is a no-op") {
        // Hardware-observed sequence: A dispatched, A killed, B dispatched, a Stop
        // reconciles the set to {B} (A is already gone from background_tasks), then
        // A's late SubagentStop finally arrives. A bare counter would decrement past
        // the truth; the set must stay exactly {B} and delegating must stay true.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "A")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "B")
        // Stop reconciles to the live background_tasks set — A already dropped off it.
        _ = registry.reconcileDelegation(sessionID: "a", ids: ["B"])
        expectEqual(registry.entry(forSession: "a")?.delegatingAgentIDs, ["B"])

        // A's late SubagentStop arrives after the reconcile already removed it.
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStop", agentID: "A")
        expectEqual(
            registry.entry(forSession: "a")?.delegatingAgentIDs, ["B"],
            "a late SubagentStop for an id the reconcile already dropped must not touch B"
        )
        expect(
            !(registry.entry(forSession: "a")?.delegatingAgentIDs.isEmpty ?? true),
            "still delegating: B is still in flight"
        )
    }

    test("reconcileDelegation is authoritative, overriding drifted incremental sets") {
        // Simulates the spike's out-of-order-finish / non-head-removal case: whatever
        // SubagentStart/SubagentStop produced is replaced wholesale by the live
        // background_tasks ids on every Stop, never trusted as a running total.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-1")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-2")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart", agentID: "agent-3")
        expectEqual(registry.entry(forSession: "a")?.delegatingAgentIDs.count, 3)

        // The authoritative Stop-time set disagrees with the drifted increments.
        _ = registry.reconcileDelegation(sessionID: "a", ids: ["agent-2"])
        expectEqual(registry.entry(forSession: "a")?.delegatingAgentIDs, ["agent-2"])

        // Reconcile to empty clears delegating entirely.
        _ = registry.reconcileDelegation(sessionID: "a", ids: [])
        expect(registry.entry(forSession: "a")?.delegatingAgentIDs.isEmpty == true)

        expect(
            registry.reconcileDelegation(sessionID: "ghost", ids: ["x"]) == nil,
            "an unknown session must not be given a key"
        )
    }

    test("the Stop override formula: done + delegating stays working, done + not delegating stays done") {
        // Pure-function replica of BoardController.handle's counter-gated override
        // (the `else` branch of its if/else if/else chain) — the live socket/hook
        // path is not reachable from this suite, but the formula itself, including
        // its load-bearing parens, is. `?? 0 > 0` would parse as `?? (0 > 0)` without
        // them, which always evaluates true for an existing entry with an empty set.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)

        func applied(_ state: SessionState, sessionID: String) -> SessionState {
            (state == .done
                && (registry.entry(forSession: sessionID)?.delegatingAgentIDs.count ?? 0) > 0)
                ? .working : state
        }

        // No agents in flight: a plain turn's Stop -> done, unchanged
        // (regression guard).
        expectEqual(applied(.done, sessionID: "a"), .done)

        // Reconciled to 1 in-flight subagent: Stop -> working, not done.
        _ = registry.reconcileDelegation(sessionID: "a", ids: ["agent-1"])
        expectEqual(applied(.done, sessionID: "a"), .working)

        // A state other than .done is never touched by the override, delegating or not.
        expectEqual(applied(.awaiting, sessionID: "a"), .awaiting)

        // Reconciled back to empty: Stop -> done again.
        _ = registry.reconcileDelegation(sessionID: "a", ids: [])
        expectEqual(applied(.done, sessionID: "a"), .done)

        // An unknown session_id must not crash or be treated as delegating.
        expectEqual(applied(.done, sessionID: "ghost"), .done)

        // The formula alone is not the whole story: BoardController feeds `applied`
        // into `setState`, which is itself gated by `SessionState.mayReplace`. Prove
        // `.working` is actually accepted over an entry sitting at `.done` — the exact
        // path a recovering delegating session takes — rather than
        // stopping one line short of the guard that could silently swallow it.
        _ = registry.setState(sessionID: "a", to: .done)
        expectEqual(registry.entry(forSession: "a")?.state, .done)
        _ = registry.reconcileDelegation(sessionID: "a", ids: ["agent-1"])
        let override = applied(.done, sessionID: "a")
        _ = registry.setState(sessionID: "a", to: override)
        expectEqual(
            registry.entry(forSession: "a")?.state, .working,
            "mayReplace must not swallow the delegating override"
        )
    }

    test("suppressesDelegating: idle_prompt suppressed only while delegating") {
        // idle_prompt fires on an idle timer, independent of subagent activity — it
        // must not be allowed to clobber a delegating .working key, but a plain
        // session (count == 0) is unaffected: the notification applies exactly as it
        // always has.
        expect(
            EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: "idle_prompt", delegatedCount: 1
            ),
            "idle_prompt while delegating must be suppressed"
        )
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: "idle_prompt", delegatedCount: 0
            ),
            "idle_prompt with no subagents in flight must apply normally"
        )
    }

    test("suppressesDelegating: real attention subtypes are never suppressed") {
        // permission_prompt/agent_needs_input/elicitation_dialog are genuine
        // human-attention signals and must keep winning orange precedence over a
        // delegating .working key — the suppression is keyed on the idle_prompt
        // subtype specifically, never on any other Notification subtype.
        for matcher in ["permission_prompt", "agent_needs_input", "elicitation_dialog"] {
            expect(
                !EventMapper.suppressesDelegating(
                    eventName: "Notification", matcher: matcher, delegatedCount: 1
                ),
                "\(matcher) must never be suppressed, delegating or not"
            )
        }
    }

    test("suppressesDelegating: keyed on subtype, not event name or mapped state") {
        // A non-Notification event, or a Notification with no matcher/a different
        // subtype, must never be suppressed regardless of delegatedCount — the
        // suppression follows the false signal (the subtype), not the color it
        // happens to be remapped to.
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Stop", matcher: "idle_prompt", delegatedCount: 1
            ),
            "only a Notification event can be suppressed"
        )
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: nil, delegatedCount: 1
            ),
            "a Notification with no matcher must not be suppressed"
        )
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: "agent_completed", delegatedCount: 1
            ),
            "an unrelated subtype must not be suppressed"
        )
    }

    test("stateSince starts at the claim and moves only when the state does") {
        // "How long has it been waiting" is measured from the state change, not from
        // the last event — a repeated hook must not reset the clock.
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, state: .working, now: t0, isAlive: alwaysAlive)
        expectEqual(registry.entry(forSession: "a")?.stateSince, t0)

        registry.setState(sessionID: "a", to: .awaiting, now: t0.addingTimeInterval(5))
        expectEqual(registry.entry(forSession: "a")?.stateSince, t0.addingTimeInterval(5))

        registry.setState(sessionID: "a", to: .awaiting, now: t0.addingTimeInterval(9))
        expectEqual(registry.entry(forSession: "a")?.stateSince, t0.addingTimeInterval(5),
                    "the same state again reset the clock")
        expectEqual(registry.entry(forSession: "a")?.updatedAt, t0.addingTimeInterval(9))

        _ = registry.claim(sessionID: "a", pid: 1, state: .working, now: t0.addingTimeInterval(20),
                           isAlive: alwaysAlive)
        expectEqual(registry.entry(forSession: "a")?.stateSince, t0.addingTimeInterval(20),
                    "a re-claim that changes the state restarts the clock")
    }

    test("a decayed state restarts stateSince") {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, state: .done, now: t0, isAlive: alwaysAlive)
        _ = registry.decay(doneAfter: 90, now: t0.addingTimeInterval(91))
        expectEqual(registry.entry(forSession: "a")?.state, .idle)
        expectEqual(registry.entry(forSession: "a")?.stateSince, t0.addingTimeInterval(91))
    }

    test("a live event confirms a restored entry") {
        // Unconfirmed is only ever a stand-in until something live speaks. The first
        // hook for the session is that word, whatever it says.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        var saved = SessionRegistry()
        _ = saved.claim(sessionID: "a", pid: 1, state: .awaiting, now: t0, isAlive: alwaysAlive)
        _ = saved.claim(sessionID: "b", pid: 2, state: .awaiting, now: t0, isAlive: alwaysAlive)
        RegistryStore.save(saved, url: url)

        var loaded = RegistryStore.load(url: url, now: t0, isAlive: alwaysAlive)
        expectEqual(loaded.entry(forSession: "a")?.isUnconfirmed, true)

        loaded.setState(sessionID: "a", to: .awaiting, now: t0.addingTimeInterval(1))
        expectEqual(loaded.entry(forSession: "a")?.isUnconfirmed, false, "same state still confirms")
        expectEqual(loaded.entry(forSession: "b")?.isUnconfirmed, true, "only the session spoken for")

        _ = loaded.claim(sessionID: "b", pid: 2, state: .working, now: t0.addingTimeInterval(2),
                         isAlive: alwaysAlive)
        expectEqual(loaded.entry(forSession: "b")?.isUnconfirmed, false, "a re-claim is a live event")
        expectEqual(loaded.entry(forSession: "b")?.state, .working)
    }

    test("a fresh claim is never unconfirmed") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, state: .awaiting, isAlive: alwaysAlive)
        expectEqual(registry.entry(forSession: "a")?.isUnconfirmed, false)
    }

    // MARK: - sessions from Superset's bus (F3)

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func event(_ type: LifecycleType, _ terminal: String = "t-codex", agent: String = "codex",
               workspace: String = "ws-1", at time: Date) -> LifecycleEvent {
        LifecycleEvent(type: type, terminalID: terminal, workspaceID: workspace, agent: agent, at: time)
    }
    func change(_ state: SessionState, _ terminal: String = "t-codex", agent: String = "codex") -> LifecycleMapper.Change {
        LifecycleMapper.Change(terminalID: terminal, workspaceID: "ws-1", agent: agent, state: state)
    }

    test("a session born on the bus (Codex) takes a key and gives it back on Detached") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "claude-1", pid: 1, isAlive: alwaysAlive)
        var mapper = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)

        // Codex has no hooks: Attached is the first word of it, and it gets a key.
        let attached = try Harness.require(mapper.ingest(event(.attached, at: at(0)), from: .bus, now: at(0)))
        let outcome = registry.applyBus(attached, mayClaim: true, now: at(0), isAlive: alwaysAlive)
        expectEqual(outcome, .claimed(slot: 2))
        let entry = try Harness.require(registry.entry(forTerminal: "t-codex"))
        expect(entry.isBusBorn)
        expectEqual(entry.state, .idle)
        expectEqual(entry.supersetWorkspaceID, "ws-1")
        expectEqual(entry.supersetTerminalID, "t-codex")

        // It works: a Start is held for the debounce, then paints working.
        expect(mapper.ingest(event(.start, at: at(1)), from: .bus, now: at(1)) == nil)
        for due in mapper.flush(now: at(1.3)) {
            _ = registry.applyBus(due, mayClaim: true, now: at(1.3), isAlive: alwaysAlive)
        }
        expectEqual(registry.entry(forTerminal: "t-codex")?.state, .working)

        // No pid, and it is not reclaimable for that: the process is not ours to see.
        expect(!registry.isReclaimable(try Harness.require(registry.entry(forTerminal: "t-codex")),
                                        now: at(2), isAlive: neverAlive))
        expectEqual(registry.prune(now: at(2), isAlive: neverAlive), 1, "only the Claude pid is gone")
        expect(registry.entry(forTerminal: "t-codex") != nil, "prune kept the bus session")

        // Detached: the key is free again, and the next session takes it.
        expectEqual(registry.releaseBus(terminalID: "t-codex"), 2)
        expect(registry.entry(forSlot: 2) == nil)
        expectEqual(registry.claim(sessionID: "next", pid: 9, isAlive: alwaysAlive).entry?.slot, 1)
    }

    test("a bus session also ends when Superset stops listing its terminal") {
        var registry = SessionRegistry()
        _ = registry.applyBus(change(.working), mayClaim: true, now: at(0), isAlive: alwaysAlive)
        _ = registry.applyBus(change(.done, "t-other"), mayClaim: true, now: at(0), isAlive: alwaysAlive)
        let changed = registry.syncBus(
            bindings: [AgentBinding(terminalID: "t-other", workspaceID: "ws-1", agent: "codex", lastEventType: .stop)],
            hookedAgents: ["claude"], now: at(5), isAlive: alwaysAlive
        )
        expect(changed)
        expect(registry.entry(forTerminal: "t-codex") == nil, "a terminal no longer listed kept its key")
        expectEqual(registry.entry(forTerminal: "t-other")?.state, .done)
    }

    test("the launch sync seeds unhooked agents and leaves Claude to its hooks") {
        var registry = SessionRegistry()
        _ = registry.syncBus(
            bindings: [
                AgentBinding(terminalID: "t-codex", workspaceID: "ws-1", agent: "codex", lastEventType: .permissionRequest),
                AgentBinding(terminalID: "t-claude", workspaceID: "ws-1", agent: "claude", lastEventType: .start),
                AgentBinding(terminalID: "t-gone", workspaceID: "ws-1", agent: "codex", lastEventType: .detached),
                AgentBinding(terminalID: "t-new", workspaceID: "ws-2", agent: "opencode"),
            ],
            hookedAgents: ["claude"], now: at(0), isAlive: alwaysAlive
        )
        expectEqual(registry.entry(forTerminal: "t-codex")?.state, .awaiting)
        expect(registry.entry(forTerminal: "t-claude") == nil, "Claude has hooks; the bus must not add a second key")
        expect(registry.entry(forTerminal: "t-gone") == nil)
        expectEqual(registry.entry(forTerminal: "t-new")?.state, .idle, "no event yet reads as idle")
    }

    test("Failed paints error, for a bus session and for a hooked one") {
        var registry = SessionRegistry()
        var mapper = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        _ = registry.applyBus(change(.working), mayClaim: true, now: at(0), isAlive: alwaysAlive)
        let failed = try Harness.require(mapper.ingest(event(.failed, at: at(1)), from: .bus, now: at(1)))
        expectEqual(failed.state, .error)
        _ = registry.applyBus(failed, mayClaim: true, now: at(1), isAlive: alwaysAlive)
        expectEqual(registry.entry(forTerminal: "t-codex")?.state, .error)

        // A Claude session the hooks own, in a Superset terminal.
        _ = registry.claim(sessionID: "claude-1", pid: 1, state: .working, isAlive: alwaysAlive)
        registry.enrich(sessionID: "claude-1", supersetWorkspaceID: "ws-1", supersetTerminalID: "t-claude")
        let outcome = registry.applyBus(change(.error, "t-claude", agent: "claude"), mayClaim: false, now: at(2), isAlive: alwaysAlive)
        expectEqual(outcome, .updated(sessionID: "claude-1"))
        expectEqual(registry.entry(forSession: "claude-1")?.state, .error, "a failed turn must not read as done")
    }

    test("the bus does not repaint a hooked session with what its hooks already said") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "claude-1", pid: 1, state: .working, isAlive: alwaysAlive)
        registry.enrich(sessionID: "claude-1", supersetWorkspaceID: "ws-1", supersetTerminalID: "t-claude")
        // Hooks decide Claude's done/working (they know about delegating subagents);
        // a bus Stop must not paint done over a delegating session.
        expectEqual(
            registry.applyBus(change(.done, "t-claude", agent: "claude"), mayClaim: false, now: at(1), isAlive: alwaysAlive),
            .ignored
        )
        expectEqual(registry.entry(forSession: "claude-1")?.state, .working)
        // And an unknown Claude terminal is never claimed from the bus.
        expectEqual(
            registry.applyBus(change(.working, "t-unknown", agent: "claude"), mayClaim: false, now: at(1), isAlive: alwaysAlive),
            .ignored
        )
        expectEqual(registry.entries.count, 1)
    }

    test("dedupe: the same Stop from our hook and from the bus counts once") {
        var mapper = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        let hook = event(.stop, "t-claude", agent: "claude", at: at(0))
        expectEqual(mapper.ingest(hook, from: .hook, now: at(0))?.state, .done)
        expect(mapper.ingest(event(.stop, "t-claude", agent: "claude", at: at(0.4)), from: .bus, now: at(0.4)) == nil,
               "the bus echo of the hook's Stop was applied again")
        // Outside the window it is a new turn.
        expectEqual(mapper.ingest(event(.stop, "t-claude", agent: "claude", at: at(3)), from: .bus, now: at(3))?.state, .done)
        // And the hook's own event types map to lifecycle types the mapper knows.
        expectEqual(LifecycleType.forHookState(.done), .stop)
        expectEqual(LifecycleType.forHookState(.error), .failed)
        expectEqual(LifecycleType.forHookState(.awaiting), .permissionRequest)
        expectEqual(LifecycleType.forHookState(.working), .start)
        expectEqual(LifecycleType.forHookState(.ended), .detached)
        expect(LifecycleType.forHookState(.stalled) == nil)
    }

    test("a hook for a terminal the bus already put on the board takes over that key") {
        var registry = SessionRegistry()
        _ = registry.applyBus(change(.working, "t-x", agent: "claude"), mayClaim: true, now: at(0), isAlive: alwaysAlive)
        let slot = try Harness.require(registry.entry(forTerminal: "t-x")?.slot)
        expect(registry.promoteBusEntry(terminalID: "t-x", to: "claude-9"))
        let entry = try Harness.require(registry.entry(forSession: "claude-9"))
        expectEqual(entry.slot, slot)
        expect(!entry.isBusBorn)
        let again = registry.claim(sessionID: "claude-9", pid: 7, state: .working, now: at(1), isAlive: alwaysAlive)
        expectEqual(again.mode, .kept)
        expectEqual(registry.entries.count, 1)
    }

    test("the launch reconciliation confirms or ends what the file restored") {
        var saved = SessionRegistry()
        _ = saved.claim(sessionID: "a", pid: 1, state: .awaiting, now: at(0), isAlive: alwaysAlive)
        _ = saved.claim(sessionID: "b", pid: 2, state: .working, now: at(0), isAlive: alwaysAlive)
        // Through the store, the only way an entry comes back unconfirmed.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        RegistryStore.save(saved, url: url)
        var registry = RegistryStore.load(url: url, now: at(1), isAlive: alwaysAlive)
        expect(registry.entries.allSatisfy(\.isUnconfirmed), "precondition: restored unconfirmed")
        registry.apply(
            [.confirm(sessionID: "a", state: .done), .end(sessionID: "b")],
            now: at(10)
        )
        let a = try Harness.require(registry.entry(forSession: "a"))
        expectEqual(a.state, .done, "Superset's word wins over the file, even awaiting → done")
        expect(!a.isUnconfirmed)
        expectEqual(a.stateSince, at(10))
        expectEqual(registry.entry(forSession: "b")?.state, .ended)
        expectEqual(registry.entry(forSession: "b")?.isUnconfirmed, false)
    }
}

/**
 Reconnecting to sessions that were already running.

 The board's job is to say what is happening without being asked, so a session sitting
 idle in another tab must not be invisible until you go and type in it.
 */
func runDiscoveryTests() {
    let alwaysAlive: (Int?) -> Bool = { _ in true }

    test("running sessions are seeded onto the board") {
        var registry = SessionRegistry()
        let found = [
            Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a"),
            Discovery.Found(pid: 200, tty: "/dev/ttys001", cwd: "/b"),
        ]
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 2)
        expectEqual(registry.entries.count, 2)
        expectEqual(registry.entry(forSlot: 1)?.tty, "/dev/ttys000")
    }

    /*
     Real `ps` output, trimmed to the columns and abbreviated in the path only.

     Every line here was observed at once on one Mac: three Terminal chats, one VS Code
     chat, and the MCP server the same extension runs out of the same directory.
    */
    let extensionBinary =
        "/Users/x/.vscode/extensions/anthropic.claude-code-2.1.226-darwin-arm64"
            + "/resources/native-binary/claude"
    let listing = """
    98987 ttys000  claude
    57023 ttys002  claude
     4405 ??       \(extensionBinary) --output-format stream-json --verbose \
    --input-format stream-json --max-thinking-tokens 31999 --permission-prompt-tool stdio
     4440 ??       \(extensionBinary) --claude-in-chrome-mcp
    12745 ??       /bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh.sh
    """

    test("a terminal chat and an extension-hosted chat are both found") {
        let found = Discovery.parse(ps: listing)
        expectEqual(found.count, 3)
        expectEqual(found.map(\.pid), [98987, 57023, 4405])
        expectEqual(found.map(\.entrypoint), ["cli", "cli", "claude-vscode"])
        // No tty is the whole reason this one was invisible before.
        expect(found.last?.tty == nil)
        expectEqual(found.first?.tty, "/dev/ttys000")
    }

    test("the MCP server running the same binary is not a session") {
        // Same path, same directory, not a chat. Only the stream-json flags separate
        // them, which is why both halves of the signature are checked.
        expect(!Discovery.parse(ps: listing).contains { $0.pid == 4440 })
    }

    test("a tty-less claude that is not the extension's is refused") {
        // The failure this guards against was real: ten of these under an unrelated
        // extension would take all six keys before a human session appeared.
        let impostors = """
        31000 ??       /usr/local/bin/claude --output-format stream-json --input-format stream-json
        31001 ??       /Users/x/.other-editor/extensions/someone.else/claude \
        --output-format stream-json --input-format stream-json
        """
        expect(Discovery.parse(ps: impostors).isEmpty)
    }

    test("two extension-hosted chats each get their own key") {
        // Both have no tty, so a duplicate check that compared ttys directly would read
        // the second as already on the board and silently drop it.
        var registry = SessionRegistry()
        let found = [
            Discovery.Found(pid: 300, tty: nil, cwd: "/a", entrypoint: "claude-vscode"),
            Discovery.Found(pid: 400, tty: nil, cwd: "/a", entrypoint: "claude-vscode"),
        ]
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 2)
        expectEqual(registry.entry(forSlot: 2)?.entrypoint, "claude-vscode")
    }

    test("reconnecting twice does not take more keys") {
        var registry = SessionRegistry()
        let found = [Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a")]
        _ = registry.reconnect(found, isAlive: alwaysAlive)
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 0, "already on the board")
        expectEqual(registry.entries.count, 1)
    }

    test("a real hook takes over its host's slot rather than a second one") {
        // Otherwise the same session appears twice: once as the discovered host and
        // again under its real id.
        var registry = SessionRegistry()
        _ = registry.reconnect(
            [Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a")], isAlive: alwaysAlive
        )
        let slotBefore = registry.entry(forSlot: 1)?.slot

        expect(registry.adoptRealSessionID("real-abc", pid: 100, tty: "/dev/ttys000"))
        expectEqual(registry.entries.count, 1, "still one key")
        expectEqual(registry.entry(forSession: "real-abc")?.slot, slotBefore)
        expect(!Discovery.isPlaceholder(registry.entry(forSlot: 1)?.sessionID ?? ""))
    }

    test("a takeover matches on tty when the pid is unknown") {
        // Hooks do not always carry CLAUDE_PID.
        var registry = SessionRegistry()
        _ = registry.reconnect(
            [Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a")], isAlive: alwaysAlive
        )
        expect(registry.adoptRealSessionID("real-abc", pid: nil, tty: "/dev/ttys000"))
        expectEqual(registry.entry(forSession: "real-abc")?.slot, 1)
    }

    test("a takeover never steals a real session's slot") {
        // Only placeholders are handed over. A genuine session keeps its key.
        var registry = SessionRegistry()
        _ = registry.claim(
            sessionID: "genuine", pid: 100, tty: "/dev/ttys000", isAlive: alwaysAlive
        )
        expect(!registry.adoptRealSessionID("other", pid: 100, tty: "/dev/ttys000"))
        expectEqual(registry.entry(forSession: "genuine")?.slot, 1)
    }

    test("a session already known is not taken over again") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "known", pid: 100, isAlive: alwaysAlive)
        expect(!registry.adoptRealSessionID("known", pid: 100, tty: nil))
    }

    test("placeholders are recognisable and never look like a session id") {
        let found = Discovery.Found(pid: 4321, tty: "/dev/ttys000", cwd: nil)
        expect(Discovery.isPlaceholder(found.placeholderSessionID))
        expect(!Discovery.isPlaceholder("4f0e1d2c-3b4a-5968-8776-a5b4c3d2e1f0"))
    }
}

/**
 Dead sessions must not hold keys.

 `prune` was written with the right reasoning in its own doc comment and then never
 called from anywhere, so a closed Terminal tab kept its key until the 12h stale window
 and the header counted it as live. The board claimed activity that did not exist,
 which is the exact failure this project is meant to avoid.
 */
func runPruneTests() {
    func board(_ pids: [Int], state: SessionState = .idle) -> SessionRegistry {
        var registry = SessionRegistry()
        let now = Date()
        for pid in pids {
            _ = registry.claim(
                sessionID: "s\(pid)", pid: pid, tty: "/dev/ttys\(pid)",
                state: state, now: now, isAlive: { _ in true }
            )
        }
        return registry
    }

    test("a session whose process is gone loses its key") {
        var registry = board([100, 200, 300])
        let dead: Set<Int> = [100, 300]
        expectEqual(registry.prune(isAlive: { pid in !dead.contains(pid ?? 0) }), 2)
        expectEqual(registry.entries.map(\.sessionID), ["s200"])
    }

    test("pruning frees the key for reuse") {
        var registry = board([100, 200])
        let slot = try Harness.require(registry.entry(forSession: "s100")?.slot)
        _ = registry.prune(isAlive: { $0 == 200 })

        let claimed = registry.claim(
            sessionID: "new", pid: 999, isAlive: { _ in true }
        )
        expectEqual(claimed.entry?.slot, slot, "the freed key was not reused")
    }

    test("a finished session with a live process keeps its key") {
        // The interaction with green holding: `done` persists until you go back, and
        // pruning must not undo that. Only the process being *gone* frees the key.
        var registry = board([100], state: .done)
        expectEqual(registry.prune(isAlive: { _ in true }), 0)
        expectEqual(registry.entry(forSession: "s100")?.state, .done)

        // Close the terminal and there is nothing to go back to.
        expectEqual(registry.prune(isAlive: { _ in false }), 1)
        expect(registry.entries.isEmpty)
    }

    test("an entry with no pid is never pruned") {
        // A session can reach the board without one. Guessing it is dead would drop a
        // live session, which is the worse error.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "no-pid", pid: nil, isAlive: { _ in true })
        expectEqual(registry.prune(isAlive: { _ in false }), 0)
        expectEqual(registry.entries.count, 1)
    }

    test("pruning an already-clean board reports no change") {
        // The caller repaints only when something changed; a nonzero return on a clean
        // board would repaint on every cycle.
        var registry = board([100, 200])
        expectEqual(registry.prune(isAlive: { _ in true }), 0)
    }
}

/**
 What green survives.

 `done` holding until you go back only works if nothing quietly repaints over it. One
 thing did: Claude Code fires an `idle_prompt` notification about 60 seconds after a
 turn ends, and a config mapping that to `idle` painted straight over the green —
 indistinguishable from a decay timer that had been switched off and was somehow still
 running.
 */
func runDoneSurvivalTests() {
    test("idle does not overwrite done") {
        // `done` already means idle, plus the thing you have not seen.
        expect(!SessionState.mayReplace(.done, with: .idle))
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s", pid: 1, state: .done, isAlive: { _ in true })
        registry.setState(sessionID: "s", to: .idle)
        expectEqual(registry.entry(forSession: "s")?.state, .done, "an idle prompt cleared it")
    }

    test("the exact sequence that caused it") {
        // Stop, then a Notification 60s later that a config maps to idle.
        var registry = SessionRegistry()
        let start = Date()
        _ = registry.claim(sessionID: "s", pid: 1, now: start, isAlive: { _ in true })
        registry.setState(sessionID: "s", to: .done, now: start)

        let mapped = EventMapper.state(
            for: "Notification", matcher: "idle_prompt", notifications: ["idle_prompt": .idle]
        )
        expectEqual(mapped, .idle, "the mapping itself is legitimate")
        registry.setState(sessionID: "s", to: mapped!, now: start.addingTimeInterval(60))
        expectEqual(registry.entry(forSession: "s")?.state, .done)
    }

    test("everything else still replaces done") {
        // Narrow on purpose: this must not become a general "green wins" rule, or a
        // session that fails or blocks after finishing would keep claiming it is fine.
        for next: SessionState in [.working, .awaiting, .stalled, .error, .ended, .viewing] {
            expect(
                SessionState.mayReplace(.done, with: next),
                "\(next.rawValue) was blocked from replacing done"
            )
        }
    }

    test("idle still replaces everything it should") {
        for current: SessionState in [.working, .viewing, .awaiting, .stalled, .error, .idle] {
            expect(
                SessionState.mayReplace(current, with: .idle),
                "idle was blocked from replacing \(current.rawValue)"
            )
        }
    }

    test("sending a new message still clears it") {
        // The intended way out has to keep working.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s", pid: 1, state: .done, isAlive: { _ in true })
        registry.setState(sessionID: "s", to: EventMapper.state(for: "UserPromptSubmit")!)
        expectEqual(registry.entry(forSession: "s")?.state, .working)
    }
}

/**
 The pad's physical rows.

 The wide MIC cap spans two columns, and only `Grid` honours that — `LazyVGrid` ignores
 `gridCellColumns` silently, which rendered the bottom row a column short and every key
 slightly wrong without anything failing.
 */
func runBoardRowTests() {
    test("four rows, each four columns wide") {
        let rows = BoardLayout.rows
        expectEqual(rows.count, 4)
        for (index, row) in rows.enumerated() {
            let width = row.reduce(0) { $0 + $1.span }
            expectEqual(width, 4, "row \(index + 1) is \(width) columns wide")
        }
    }

    test("the rows contain every cell, in order, once") {
        // Derived from `cells` so there is one definition of what is on the pad; this
        // is what stops the two drifting.
        let flattened = BoardLayout.rows.flatMap { $0 }.map(\.id)
        expectEqual(flattened, BoardLayout.cells.map(\.id))
    }

    test("no cell spans on the clone") {
        let spanning = BoardLayout.cells.filter { $0.span > 1 }
        expectEqual(spanning.map(\.id), [])
    }

    test("the bottom row is the touch strip and three single keys") {
        let last = try Harness.require(BoardLayout.rows.last)
        expectEqual(last.map(\.id), ["TOUCH", "ACT10", "ACT11", "ACT12"])
    }
}

/// A host-service that only records what it was asked. Nothing leaves the process.
private actor RecordingHost: SupersetHostAPI {
    var bindings: [AgentBinding]
    var snapshotText: String? = "$ claude\n> working…"
    private(set) var performed: [SupersetCall] = []
    private(set) var snapshots: [(terminal: String, lines: Int)] = []

    init(bindings: [AgentBinding]) { self.bindings = bindings }

    var state: SupersetLinkState { .connected(version: "1.30.0", readOnly: false) }
    func health() async throws -> String { "1.30.0" }
    func agents(workspaceID: String?) async throws -> [AgentBinding] {
        bindings.filter { workspaceID == nil || $0.workspaceID == workspaceID }
    }
    func snapshot(terminalID: String, workspaceID: String, maxLines: Int) async throws -> String {
        snapshots.append((terminalID, maxLines))
        guard let snapshotText else { throw SupersetClientError.unreachable }
        return snapshotText
    }
    func transcript(terminalID: String, workspaceID: String, maxChars: Int) async throws -> String { "" }
    func perform(_ call: SupersetCall) async throws { performed.append(call) }
}

/// Runs an async body to completion from the synchronous test harness.
private func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task { box.value = await body(); done.signal() }
    done.wait()
    return box.value!
}
private final class ResultBox<T>: @unchecked Sendable { var value: T? }

/**
 Targeted control from the pad (F7, D10 armed mode): which key does what while armed,
 and what reaches the host-service when it fires — through a recording fake.
 */
func targetedControlChecks() {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let taps: [String: KeyAction] = ["ACT06": .shortcut, "ACT07": .approve, "ACT08": .reject, "ACT09": .nextSession]
    let limits = Preferences.Targeted()
    func binding(_ type: LifecycleType?) -> AgentBinding {
        AgentBinding(terminalID: "t-1", workspaceID: "ws-1", agent: "claude", lastEventType: type)
    }

    test("targeted: an agent key while armed fires at that agent and does not jump") {
        var arming = TargetArming(window: 3, snippet: "sigue")
        _ = arming.arm(now: t0)
        let route = TargetedRun.route(.jump(slot: 2), arming: &arming, taps: taps, now: at(1))
        expectEqual(route, .consumed(.fire(.send(text: "sigue"), padKey: 2)))
        // Consumed means the controller never reaches its `.jump` case.
        expect(route != .passThrough)
        // Disarmed again: the next agent key jumps as always.
        expectEqual(TargetedRun.route(.jump(slot: 2), arming: &arming, taps: taps, now: at(2)), .passThrough)
    }

    test("targeted: REJ while armed turns the send into an interrupt, then the agent key fires it") {
        var arming = TargetArming(window: 3, snippet: "sigue")
        _ = arming.arm(now: t0)
        // REJ has a long press, so it arrives as a press to be timed.
        expectEqual(TargetedRun.route(.actionPressed(key: "ACT08"), arming: &arming, taps: taps, now: at(0.5)),
                    .consumed(.armed(.interrupt)))
        expectEqual(TargetedRun.route(.action(.reject, key: "ACT08"), arming: &arming, taps: taps, now: at(0.6)),
                    .consumed(.armed(.interrupt)))
        expectEqual(TargetedRun.route(.jump(slot: 1), arming: &arming, taps: taps, now: at(1)),
                    .consumed(.fire(.interrupt, padKey: 1)))
    }

    test("targeted: any other key cancels and does nothing else; releases and the dial pass") {
        var arming = TargetArming(window: 3, snippet: "sigue")
        _ = arming.arm(now: t0)
        expectEqual(TargetedRun.route(.release(key: "ACT06"), arming: &arming, taps: taps, now: at(0.1)), .passThrough,
                    "FAST's own release must not cancel what its hold armed")
        expectEqual(TargetedRun.route(.scroll(lines: 3), arming: &arming, taps: taps, now: at(0.2)), .passThrough)
        expectEqual(TargetedRun.route(.actionPressed(key: "ACT07"), arming: &arming, taps: taps, now: at(0.3)),
                    .consumed(.cancelled))
        // Not armed: everything keeps its meaning.
        expectEqual(TargetedRun.route(.action(.reject, key: "ACT08"), arming: &arming, taps: taps, now: at(0.4)), .passThrough)
        _ = arming.arm(now: at(1))
        expectEqual(TargetedRun.route(.encoderPressed, arming: &arming, taps: taps, now: at(1.1)), .consumed(.cancelled))
        // A key after the window cancels rather than fires.
        _ = arming.arm(now: at(2))
        expectEqual(TargetedRun.route(.jump(slot: 3), arming: &arming, taps: taps, now: at(6)), .consumed(.cancelled))
    }

    test("targeted: a send to a working agent is refused and nothing is written") {
        let host = RecordingHost(bindings: [binding(.start)])
        let report = blocking {
            await TargetedRun.fire(.send(text: "sigue"), terminalID: "t-1", workspaceID: "ws-1", host: host, limits: limits)
        }
        expectEqual(report, .refused(reason: "agent has not stopped"))
        expect(blocking { await host.performed }.isEmpty, "a refused send wrote to the terminal")
        // The snapshot is still read first (Plan §6), and never returned.
        expectEqual(blocking { await host.snapshots.map(\.lines) }, [limits.snapshotLines])
    }

    test("targeted: an interrupt sends ⎋ and then clears the status, in that order") {
        let host = RecordingHost(bindings: [binding(.start)])
        let report = blocking {
            await TargetedRun.fire(.interrupt, terminalID: "t-1", workspaceID: "ws-1", host: host, limits: limits)
        }
        expectEqual(report, .done(procedures: [.terminalWriteInput, .clearWorkspaceStatuses], bytes: 0))
        expectEqual(blocking { await host.performed }, [
            .writeInput(terminalID: "t-1", workspaceID: "ws-1", data: .escape),
            .clearStatuses(workspaceID: "ws-1", terminalID: "t-1"),
        ])
    }

    test("targeted: a send to a stopped agent submits the snippet and reports only its size") {
        let host = RecordingHost(bindings: [binding(.stop)])
        let report = blocking {
            await TargetedRun.fire(.send(text: "sigue"), terminalID: "t-1", workspaceID: "ws-1", host: host, limits: limits)
        }
        expectEqual(report, .done(procedures: [.terminalSend], bytes: 5))
        expectEqual(blocking { await host.performed }, [.send(terminalID: "t-1", workspaceID: "ws-1", text: "sigue", submit: true)])
        // What the log line is built from carries no text.
        expect(!"\(report)".contains("sigue"))
    }

    test("targeted: neither the report nor the logged line carries the screen or the snippet") {
        let screen = "SCREEN-7f3a secret on screen"
        let snippet = "SNIPPET-91cc please continue"
        for type in [LifecycleType.stop, .start] {
            let host = RecordingHost(bindings: [binding(type)])
            blocking { await host.setSnapshot(screen) }
            for intent in [TargetedControl.Intent.send(text: snippet), .interrupt] {
                let report = blocking {
                    await TargetedRun.fire(intent, terminalID: "t-1", workspaceID: "ws-1", host: host, limits: limits)
                }
                let line = TargetedRun.logLine(report, intent: intent, label: "key 1 · ws")
                for text in ["\(report)", String(reflecting: report), line] {
                    expect(!text.contains("SCREEN-7f3a"), "screen text leaked: \(type) \(TargetedRun.logLine(report, intent: .interrupt, label: ""))")
                    expect(!text.contains("SNIPPET-91cc"), "snippet leaked: \(type)")
                }
            }
        }
        // A failure partway reports procedures and a code, still no text.
        let failing = TargetedRun.logLine(
            .failed(after: [.terminalWriteInput], error: "readOnly"), intent: .send(text: snippet), label: "key 2"
        )
        expect(!failing.contains("SNIPPET-91cc"))
        expectEqual(TargetedRun.logLine(.done(procedures: [.terminalSend], bytes: 12), intent: .send(text: snippet), label: "key 2"),
                    "targeted: sent 12 bytes to key 2")
    }

    test("targeted: no snapshot, no binding or no terminal means nothing is written") {
        let noSnapshot = RecordingHost(bindings: [binding(.start)])
        blocking { await noSnapshot.setSnapshot(nil) }
        expectEqual(
            blocking { await TargetedRun.fire(.interrupt, terminalID: "t-1", workspaceID: "ws-1", host: noSnapshot, limits: limits) },
            .refused(reason: "no snapshot taken first")
        )
        expect(blocking { await noSnapshot.performed }.isEmpty)
        let unbound = RecordingHost(bindings: [])
        expectEqual(
            blocking { await TargetedRun.fire(.interrupt, terminalID: "t-1", workspaceID: "ws-1", host: unbound, limits: limits) },
            .refused(reason: "no agent bound to that terminal")
        )
        expect(blocking { await unbound.performed }.isEmpty)
    }
}

extension RecordingHost {
    fileprivate func setSnapshot(_ text: String?) { snapshotText = text }
}
