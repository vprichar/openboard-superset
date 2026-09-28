import Foundation

/**
 At launch, confirms or ends each session the registry restored as unconfirmed,
 against what `terminalAgents.list` says now.

 A restored session with a terminal id that Superset no longer lists was closed while
 OpenBoard was off: it ends. One that is still listed takes the state of its last
 event. `Attached` (seen live, SP) and a binding with no event yet read as idle;
 `clearWorkspaceStatuses` leaves bindings at `Stop`, which reads as done — Superset's
 word, not ours. A session with no terminal id is not Superset's to judge (an iTerm2
 or cmux session) and gets no outcome.
 */
public enum Reconciler {
    public enum Outcome: Equatable, Sendable {
        case confirm(sessionID: String, state: SessionState)
        case end(sessionID: String)
    }

    public static func reconcile(
        unconfirmed: [(sessionID: String, terminalID: String?)],
        bindings: [AgentBinding]
    ) -> [Outcome] {
        let byTerminal = Dictionary(bindings.map { ($0.terminalID, $0) }, uniquingKeysWith: { first, _ in first })
        return unconfirmed.compactMap { entry in
            guard let terminal = entry.terminalID else { return nil }
            guard let binding = byTerminal[terminal] else { return .end(sessionID: entry.sessionID) }
            switch binding.lastEventType {
            case .detached: return .end(sessionID: entry.sessionID)
            case nil: return .confirm(sessionID: entry.sessionID, state: .idle)
            case let type?:
                return .confirm(sessionID: entry.sessionID, state: LifecycleMapper.state(for: type) ?? .idle)
            }
        }
    }
}
