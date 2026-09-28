import Foundation
import OpenBoardKit

/*
 The `/events` bus, the lifecycle → state mapping, reconciliation at launch, and the
 pad-write coalescer. All pure; time is passed in.

 Bus messages are plain JSON (no superjson envelope). The literals are copied from
 the spike's `SP/fixtures/events-60s.json` (which carries no `preview`); where a test
 needs a `preview`, a made-up one is added and marked as such.
*/

private let base = Date(timeIntervalSince1970: 1_790_549_000)
private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

private let ws = "11111111-1111-4111-8111-111111111111"
private let term = "33333333-3333-4333-8333-333333333333"

// Fixture: SP/fixtures/events-60s.json, messages[0] (receivedAt dropped — the spike
// added it, the bus does not send it).
private let startMessage = """
{"type":"agent:lifecycle","workspaceId":"11111111-1111-4111-8111-111111111111","eventType":"Start",\
"terminalId":"33333333-3333-4333-8333-333333333333","agent":{"agentId":"claude",\
"sessionId":"b7e3fe04-e547-49ab-b8c2-74ca76eb47f1"},"occurredAt":1790549033967}
"""

// Fixture: SP/fixtures/events-60s.json, the last agent:lifecycle (Stop).
private let stopMessage = """
{"type":"agent:lifecycle","workspaceId":"11111111-1111-4111-8111-111111111111","eventType":"Stop",\
"terminalId":"33333333-3333-4333-8333-333333333333","agent":{"agentId":"claude",\
"sessionId":"44444444-4444-4444-8444-444444444444"},"occurredAt":1790549078316}
"""

// Fixture: SP/fixtures/events-60s.json, a git:changed.
private let gitChanged = #"{"type":"git:changed","workspaceId":"a199651d-ae2d-4691-8c48-6e848feb00a5"}"#

private func lifecycle(_ type: String, terminal: String = term, preview: String? = nil) -> Data {
    let extra = preview.map { #","preview":"\#($0)""# } ?? ""
    return Data("""
    {"type":"agent:lifecycle","workspaceId":"\(ws)","eventType":"\(type)","terminalId":"\(terminal)",\
    "agent":{"agentId":"codex","sessionId":"s-1"}\(extra),"occurredAt":1790549033967}
    """.utf8)
}

private func event(_ type: LifecycleType, terminal: String = term, _ seconds: TimeInterval) -> LifecycleEvent {
    LifecycleEvent(type: type, terminalID: terminal, workspaceID: ws, agent: "claude", at: at(seconds))
}

// MARK: - Bus + mapper

func runSupersetBusTests() {
    test("bus: decodes agent:lifecycle from the live fixture") {
        let message = SupersetBus.decode(Data(startMessage.utf8), now: at(99))
        expectEqual(message, .lifecycle(LifecycleEvent(
            type: .start, terminalID: term, workspaceID: ws, agent: "claude",
            at: Date(timeIntervalSince1970: 1_790_549_033.967)
        )))
        let stop = SupersetBus.decode(Data(stopMessage.utf8), now: at(99))
        if case let .lifecycle(e) = stop { expectEqual(e.type, .stop) } else { expect(false, "\(String(describing: stop))") }
    }

    test("bus: preview is dropped at decode and appears nowhere") {
        // Made-up preview text; the real fixtures were captured without one.
        let secret = "rm -rf ~/work && echo PREVIEW-TEXT"
        let message = try Harness.require(SupersetBus.decode(lifecycle("Stop", preview: secret), now: at(0)))
        var dumped = ""
        dump(message, to: &dumped)
        expect(!"\(message)".contains("PREVIEW-TEXT") && !dumped.contains("PREVIEW-TEXT"))
        // Equal to the same event without a preview: there is nowhere for it to live.
        expectEqual(message, SupersetBus.decode(lifecycle("Stop"), now: at(0)))
    }

    test("bus: no occurredAt falls back to now") {
        let data = Data(#"{"type":"agent:lifecycle","workspaceId":"w","eventType":"Failed","terminalId":"t","agent":{"agentId":"claude"}}"#.utf8)
        if case let .lifecycle(e) = SupersetBus.decode(data, now: at(5)) {
            expectEqual(e.at, at(5))
        } else {
            expect(false, "expected a lifecycle event")
        }
    }

    test("bus: an unknown type is .other; agent:bindings-changed is its own case") {
        expectEqual(SupersetBus.decode(Data(gitChanged.utf8), now: at(0)), .other(type: "git:changed"))
        // shape: catalog, unverified — SP saw no bindings-changed in its 60 s capture.
        expectEqual(
            SupersetBus.decode(Data(#"{"type":"agent:bindings-changed","workspaceId":"w-1"}"#.utf8), now: at(0)),
            .bindingsChanged(workspaceID: "w-1"))
        expectEqual(
            SupersetBus.decode(Data(#"{"type":"agent:bindings-changed"}"#.utf8), now: at(0)),
            .bindingsChanged(workspaceID: nil))
    }

    test("bus: garbage and a lifecycle with missing fields decode to nil") {
        expectEqual(SupersetBus.decode(Data("not json".utf8), now: at(0)), nil)
        expectEqual(SupersetBus.decode(Data(#"{"no":"type"}"#.utf8), now: at(0)), nil)
        expectEqual(SupersetBus.decode(Data(#"{"type":"agent:lifecycle","eventType":"Stop"}"#.utf8), now: at(0)), nil)
        expectEqual(SupersetBus.decode(lifecycle("Exploded"), now: at(0)), nil)
    }

    test("mapper: Stop → done, PermissionRequest → awaiting, Failed → error") {
        var m = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        expectEqual(m.ingest(event(.permissionRequest, 0), from: .bus, now: at(0))?.state, .awaiting)
        expectEqual(m.ingest(event(.stop, 10), from: .bus, now: at(10))?.state, .done)
        let failed = m.ingest(event(.failed, 20), from: .bus, now: at(20))
        expectEqual(failed, LifecycleMapper.Change(terminalID: term, workspaceID: ws, agent: "claude", state: .error))
    }

    test("mapper: Detached → nil") {
        var m = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        expectEqual(m.ingest(event(.detached, 0), from: .bus, now: at(0)), nil)
        expectEqual(m.flush(now: at(10)), [])
    }

    test("mapper: 5 Start in 100 ms → a single working after flush") {
        var m = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        for i in 0..<5 {
            let t = Double(i) * 0.025
            expectEqual(m.ingest(event(.start, t), from: .bus, now: at(t)), nil, "Start is held, never immediate")
        }
        expectEqual(m.flush(now: at(0.15)), [], "still inside the debounce")
        expectEqual(m.flush(now: at(0.4)).map(\.state), [.working])
        expectEqual(m.flush(now: at(1.0)), [], "flushed once")
    }

    test("mapper: live burst — 10 Start seconds apart stay one working") {
        // SP/fixtures/events-60s.json: 10 Start from one terminal, 2–12 s apart.
        var m = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        var changes: [LifecycleMapper.Change] = []
        for t in [0.0, 2.9, 5.8, 7.7, 9.7, 13.9, 17.1, 29.3, 37.1, 39.9] {
            _ = m.ingest(event(.start, t), from: .bus, now: at(t))
            changes += m.flush(now: at(t + 0.3))
        }
        expectEqual(changes.map(\.state), [.working])
        expectEqual(m.ingest(event(.stop, 44.3), from: .bus, now: at(44.3))?.state, .done)
    }

    test("mapper: a Stop inside the debounce cancels the held Start") {
        var m = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        _ = m.ingest(event(.start, 0), from: .bus, now: at(0))
        expectEqual(m.ingest(event(.stop, 0.1), from: .bus, now: at(0.1))?.state, .done)
        expectEqual(m.flush(now: at(1)), [], "the stale working must not land after done")
    }

    test("mapper: hook Stop + bus Stop of the same terminal within 1.5 s → one change") {
        var m = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        expectEqual(m.ingest(event(.stop, 0), from: .hook, now: at(0))?.state, .done)
        expectEqual(m.ingest(event(.stop, 1.2), from: .bus, now: at(1.2)), nil)
        // Another terminal is not deduplicated against this one.
        expectEqual(m.ingest(event(.stop, terminal: "other", 1.3), from: .bus, now: at(1.3))?.state, .done)
        // After the window the same type counts again (a new turn ended).
        expectEqual(m.ingest(event(.stop, 5), from: .bus, now: at(5))?.state, .done)
    }

    test("mapper: Attached → idle (a harness without hooks gets its key)") {
        var m = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
        expectEqual(m.ingest(event(.attached, 0), from: .bus, now: at(0))?.state, .idle)
    }

    test("clearStatuses: bindings-changed is not a lifecycle Change") {
        // formas.md §2: clearWorkspaceStatuses emits agent:bindings-changed, never
        // agent:lifecycle. shape: catalog, unverified (the payload was not captured).
        let message = SupersetBus.decode(Data(#"{"type":"agent:bindings-changed","workspaceId":"\#(ws)"}"#.utf8), now: at(0))
        expectEqual(message, .bindingsChanged(workspaceID: ws))
        if case .lifecycle = message { expect(false, "must not feed the mapper") }
    }
}

// MARK: - Reconcile

func runReconcileTests() {
    func binding(_ terminal: String, _ type: LifecycleType?) -> AgentBinding {
        AgentBinding(terminalID: terminal, workspaceID: ws, agent: "claude", lastEventType: type, lastEventAt: base)
    }

    test("reconcile: unconfirmed + PermissionRequest → awaiting; + Stop → done") {
        let out = Reconciler.reconcile(
            unconfirmed: [("s-1", "t-1"), ("s-2", "t-2")],
            bindings: [binding("t-1", .permissionRequest), binding("t-2", .stop)])
        expectEqual(out, [.confirm(sessionID: "s-1", state: .awaiting), .confirm(sessionID: "s-2", state: .done)])
    }

    test("reconcile: Start → working, Failed → error") {
        let out = Reconciler.reconcile(
            unconfirmed: [("s-1", "t-1"), ("s-2", "t-2")],
            bindings: [binding("t-1", .start), binding("t-2", .failed)])
        expectEqual(out, [.confirm(sessionID: "s-1", state: .working), .confirm(sessionID: "s-2", state: .error)])
    }

    test("reconcile: no binding → end") {
        let out = Reconciler.reconcile(unconfirmed: [("s-1", "gone")], bindings: [binding("t-1", .stop)])
        expectEqual(out, [.end(sessionID: "s-1")])
    }

    test("reconcile: Attached → idle") {
        // SP/fixtures/terminalAgents.list.json has two bindings with lastEventType "Attached".
        let out = Reconciler.reconcile(unconfirmed: [("s-1", "d759550f-03c7-4558-b6cc-d46ef5e3f86c")],
                                       bindings: [binding("d759550f-03c7-4558-b6cc-d46ef5e3f86c", .attached)])
        expectEqual(out, [.confirm(sessionID: "s-1", state: .idle)])
    }

    test("reconcile: after clearWorkspaceStatuses the binding reads Stop → done, not idle") {
        // formas.md §2: clearWorkspaceStatuses sets lastEventType = "Stop".
        let out = Reconciler.reconcile(unconfirmed: [("s-1", "t-1")], bindings: [binding("t-1", .stop)])
        expectEqual(out, [.confirm(sessionID: "s-1", state: .done)])
    }

    test("reconcile: Detached → end; no lastEventType → idle") {
        let out = Reconciler.reconcile(
            unconfirmed: [("s-1", "t-1"), ("s-2", "t-2")],
            bindings: [binding("t-1", .detached), binding("t-2", nil)])
        expectEqual(out, [.end(sessionID: "s-1"), .confirm(sessionID: "s-2", state: .idle)])
    }

    test("reconcile: a session with no terminal id is left alone (not Superset's to judge)") {
        let out = Reconciler.reconcile(unconfirmed: [("s-1", nil)], bindings: [])
        expectEqual(out, [])
    }
}

// MARK: - Pad writes

func runPadWriteCoalescerTests() {
    let a = Data("rgbcfg:A".utf8)
    let b = Data("rgbcfg:B".utf8)
    let c = Data("rgbcfg:C".utf8)

    test("coalescer: the first write after a quiet spell goes out at once") {
        var co = PadWriteCoalescer(interval: 0.09)
        expectEqual(co.offer(a, now: at(0)), a)
    }

    test("coalescer: two writes within 90 ms → one (the last)") {
        var co = PadWriteCoalescer(interval: 0.09)
        _ = co.offer(a, now: at(0))
        expectEqual(co.offer(b, now: at(0.01)), nil)
        expectEqual(co.offer(c, now: at(0.06)), nil)
        expectEqual(co.drain(now: at(0.05)), nil, "not before the window ends")
        expectEqual(co.drain(now: at(0.09)), c)
        expectEqual(co.drain(now: at(0.5)), nil, "drained once")
    }

    test("coalescer: a payload identical to the last one is not resent") {
        var co = PadWriteCoalescer(interval: 0.09)
        expectEqual(co.offer(a, now: at(0)), a)
        expectEqual(co.offer(a, now: at(1)), nil)
        // B goes out, then A and B again inside the window: B is already there.
        expectEqual(co.offer(b, now: at(1.01)), b)
        expectEqual(co.offer(a, now: at(1.02)), nil)
        expectEqual(co.offer(b, now: at(1.03)), nil)
        expectEqual(co.drain(now: at(1.2)), nil, "B is already on the pad")
    }
}
