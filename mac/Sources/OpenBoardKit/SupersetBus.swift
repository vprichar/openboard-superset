import Foundation

/**
 Decodes one `/events` WebSocket message.

 The bus broadcasts everything to everyone, as plain JSON (no superjson envelope,
 unlike `/trpc`). Only two types matter here: `agent:lifecycle`, which moves a key's
 state, and `agent:bindings-changed`, which says a terminal's agents changed without
 saying how — `clearWorkspaceStatuses` and subagents report through it, never through
 lifecycle (SP formas.md §2–3). Everything else is `.other` so the caller can count it
 and move on.

 `preview` — the terminal text Superset attaches to some events — is never read: the
 event type has no field for it, so it cannot be stored or logged by accident.
 */
public enum SupersetBus {
    public enum Message: Equatable, Sendable {
        case lifecycle(LifecycleEvent)
        case bindingsChanged(workspaceID: String?)
        case other(type: String)
    }

    /// nil for anything that is not a JSON object with a `type`, and for a lifecycle
    /// event missing its ids or naming an event type Superset does not emit.
    /// `occurredAt` is epoch milliseconds; without it the event is dated `now`.
    public static func decode(_ data: Data, now: Date) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "agent:lifecycle":
            guard let rawType = object["eventType"] as? String,
                  let eventType = LifecycleType(rawValue: rawType),
                  let terminal = object["terminalId"] as? String,
                  let workspace = object["workspaceId"] as? String,
                  let agent = (object["agent"] as? [String: Any])?["agentId"] as? String
            else { return nil }
            let at = (object["occurredAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? now
            return .lifecycle(LifecycleEvent(type: eventType, terminalID: terminal, workspaceID: workspace,
                                             agent: agent, at: at))
        case "agent:bindings-changed":
            return .bindingsChanged(workspaceID: object["workspaceId"] as? String)
        default:
            return .other(type: type)
        }
    }
}
