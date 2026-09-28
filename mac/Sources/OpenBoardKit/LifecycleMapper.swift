import Foundation

/**
 Lifecycle events → key states, with the two filters the live bus needs.

 - **Start debounce.** `Start` fires on every tool use — SP saw ten from one terminal
   in 45 s. A `Start` is therefore never applied immediately: it is held for
   `startDebounce` and released by `flush`. Any other event for that terminal in the
   meantime cancels it (a `Stop` 100 ms after a `Start` means the turn is over, and a
   late `working` would paint over `done`). And once a terminal is `working`, further
   `Start`s change nothing.
 - **Dedupe.** Our own hook and the bus both report the same moment. The same event
   type for the same terminal inside `dedupeWindow` counts once, whichever source
   came first. After the window it counts again: that is a new turn.

 Mapping (Plan F3): Start → working, Stop → done, PermissionRequest → awaiting,
 Failed → error, Attached → idle (a harness without hooks gets its key), Detached → no
 change. Time is always passed in.
 */
public struct LifecycleMapper {
    public enum Source: Sendable { case hook, bus }

    public struct Change: Equatable, Sendable {
        public var terminalID: String
        public var workspaceID: String
        public var agent: String
        public var state: SessionState

        public init(terminalID: String, workspaceID: String, agent: String, state: SessionState) {
            self.terminalID = terminalID
            self.workspaceID = workspaceID
            self.agent = agent
            self.state = state
        }
    }

    private let startDebounce: TimeInterval
    private let dedupeWindow: TimeInterval
    /// Held `Start`s, by terminal, with when they fall due.
    private var pending: [String: (change: Change, due: Date)] = [:]
    /// The last event applied per terminal, for dedupe.
    private var lastApplied: [String: (type: LifecycleType, at: Date)] = [:]
    /// The last state emitted per terminal.
    private var lastState: [String: SessionState] = [:]

    public init(startDebounce: TimeInterval, dedupeWindow: TimeInterval) {
        self.startDebounce = startDebounce
        self.dedupeWindow = dedupeWindow
    }

    public static func state(for type: LifecycleType) -> SessionState? {
        switch type {
        case .start: .working
        case .stop: .done
        case .permissionRequest: .awaiting
        case .failed: .error
        case .attached: .idle
        case .detached: nil
        }
    }

    /// The change to apply now, if any. `Start` always returns nil here — see `flush`.
    public mutating func ingest(_ e: LifecycleEvent, from: Source, now: Date) -> Change? {
        guard let state = Self.state(for: e.type) else { return nil }
        let terminal = e.terminalID
        let change = Change(terminalID: terminal, workspaceID: e.workspaceID, agent: e.agent, state: state)

        if e.type == .start {
            if lastState[terminal] == .working { return nil }
            if pending[terminal] == nil { pending[terminal] = (change, now.addingTimeInterval(startDebounce)) }
            return nil
        }

        pending[terminal] = nil
        if let last = lastApplied[terminal], last.type == e.type, now.timeIntervalSince(last.at) < dedupeWindow {
            return nil
        }
        return apply(change, type: e.type, now: now)
    }

    /// Held `Start`s whose debounce ran out, oldest first.
    public mutating func flush(now: Date) -> [Change] {
        let due = pending.filter { $0.value.due <= now }.sorted { $0.value.due < $1.value.due }
        var out: [Change] = []
        for (terminal, held) in due {
            pending[terminal] = nil
            if lastState[terminal] == .working { continue }
            if let change = apply(held.change, type: .start, now: now) { out.append(change) }
        }
        return out
    }

    private mutating func apply(_ change: Change, type: LifecycleType, now: Date) -> Change? {
        lastApplied[change.terminalID] = (type, now)
        lastState[change.terminalID] = change.state
        return change
    }
}
