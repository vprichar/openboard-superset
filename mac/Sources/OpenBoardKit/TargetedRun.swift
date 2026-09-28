import Foundation

/**
 Targeted control from the pad (F7), between the key and the host-service.

 Two halves, both testable without an app: `route` decides what a key means while the
 armed mode (D10) is waiting for its agent key, and `fire` takes a fired intent to the
 host-service — binding, snapshot, `TargetedControl.plan`, calls — and says what
 happened in a report that carries sizes, never text. The controller logs the report
 and nothing else, so neither the screen nor the snippet can reach `app.log`.
 */
public enum TargetedRun {
    public enum Route: Equatable, Sendable {
        /// Not armed, or an input that is not a key press: do what it always does.
        case passThrough
        /// The armed mode took the key. It must not also do its own thing — above all,
        /// an agent key must not jump (that is the point of aiming without looking).
        case consumed(TargetArming.Step)
    }

    /**
     What a key means while armed. REJ — by tap or by the press of its long binding —
     turns the send into an interrupt; an agent key fires at that key; any other key
     cancels. Releases and the dial's turn are not presses and pass through: FAST's own
     release, right after its hold armed the mode, must not cancel it.
     */
    public static func route(
        _ intent: KeyDispatcher.Intent,
        arming: inout TargetArming,
        taps: [String: KeyAction],
        now: Date
    ) -> Route {
        let step: TargetArming.Step
        switch intent {
        case .release, .scroll:
            return .passThrough
        case let .jump(slot):
            step = arming.agentKey(slot, now: now)
        case let .action(action, _) where action == .reject:
            step = arming.reject(now: now)
        case let .actionPressed(key) where taps[key] == .reject:
            step = arming.reject(now: now)
        case .action, .actionPressed, .encoderPressed:
            step = arming.otherKey(now: now)
        }
        return step == .none ? .passThrough : .consumed(step)
    }

    public enum Report: Equatable, Sendable {
        case refused(reason: String)
        /// Every call went through. `bytes` is the size of the text sent, 0 for an
        /// interrupt.
        case done(procedures: [SupersetProcedure], bytes: Int)
        /// A call failed partway; the ones before it went through.
        case failed(after: [SupersetProcedure], error: String)
    }

    /**
     Fire at one terminal: read its binding and a snapshot first (Plan §6: nothing is
     written to a terminal without looking at it), plan, then run the calls in order.
     The snapshot is only evidence that the look happened; it is dropped here.
     */
    public static func fire(
        _ intent: TargetedControl.Intent,
        terminalID: String,
        workspaceID: String,
        host: SupersetHostAPI,
        limits: Preferences.Targeted
    ) async -> Report {
        let bindings: [AgentBinding]
        do {
            bindings = try await host.agents(workspaceID: workspaceID)
        } catch {
            return .refused(reason: "could not read the agent list (\(describe(error)))")
        }
        let binding = bindings.first { $0.terminalID == terminalID }
        let snapshot: String? = binding == nil ? nil : try? await host.snapshot(
            terminalID: terminalID, workspaceID: workspaceID, maxLines: limits.snapshotLines
        )
        switch TargetedControl.plan(intent, binding: binding, snapshot: snapshot, limits: limits) {
        case let .refuse(reason):
            return .refused(reason: reason)
        case let .calls(calls):
            var done: [SupersetProcedure] = []
            var bytes = 0
            for call in calls {
                do {
                    try await host.perform(call)
                } catch {
                    return .failed(after: done, error: describe(error))
                }
                done.append(call.procedure)
                if case let .send(_, _, text, _) = call { bytes += text.utf8.count }
            }
            return .done(procedures: done, bytes: bytes)
        }
    }

    /**
     The one line the controller logs for a fired intent. Built only from the report,
     the kind of intent and the key's label — the snippet and the snapshot never reach
     it, because neither is in its inputs.
     */
    public static func logLine(_ report: Report, intent: TargetedControl.Intent, label: String) -> String {
        switch (report, intent) {
        case (.done, .interrupt):
            return "targeted: interrupted \(label)"
        case let (.done(_, bytes), .send):
            return "targeted: sent \(bytes) bytes to \(label)"
        case let (.refused(reason), _):
            return "targeted: refused — \(label): \(reason)"
        case let (.failed(after, error), _):
            return "targeted: refused — \(label): failed after \(after.map(\.rawValue)) — \(error)"
        }
    }

    /// The client's own error cases, or a code — never a description that could carry
    /// the endpoint.
    public static func describe(_ error: Error) -> String {
        if let error = error as? SupersetClientError { return "\(error)" }
        if let error = error as? URLError { return "network error \(error.code.rawValue)" }
        return "error \((error as NSError).code)"
    }
}
