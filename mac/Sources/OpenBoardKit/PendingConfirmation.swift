import Foundation

/// Something a key asked for that runs only after a second, deliberate press.
public enum PendingAction: Equatable, Sendable {
    /// F8: hand the focused terminal over to another agent. What that becomes on the
    /// wire is decided after the spike; this only names the intent.
    case handoff(terminalID: String, workspaceID: String, agent: String)
    /// F4's acceptance action: exercises the window without doing anything.
    case probe
}

/**
 The two-step confirmation behind everything that creates, sends or spends (F4).

 One action at a time. While one is pending, the pad belongs to it: APPR confirms, and
 **any other key** cancels — and does not do its own thing, so a stray REJ never rejects
 a prompt and a stray agent key never jumps while the ring is asking "are you sure?".

 The window is checked against the injected clock on every input, not only when the
 app polls `expire`. A late APPR — one that lands after the window but before the poll
 noticed — cancels rather than confirms: a confirmation the user watched lapse must not
 run.
 */
public struct PendingConfirmation {
    public enum Input: Sendable {
        case approve
        case other(key: String)
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing pending: the key does what it always does.
        case passThrough
        case confirmed(PendingAction)
        /// Cancelled by a key or by a late press; the key itself is swallowed.
        case cancelled(PendingAction)
    }

    private let window: TimeInterval
    private var armed: (action: PendingAction, at: Date)?

    public init(window: TimeInterval) {
        self.window = window
    }

    public var pending: PendingAction? { armed?.action }

    /// Arming again replaces whatever was pending and restarts the window.
    public mutating func arm(_ action: PendingAction, now: Date) {
        armed = (action, now)
    }

    public mutating func handle(_ input: Input, now: Date) -> Outcome {
        guard let current = armed else { return .passThrough }
        armed = nil
        if lapsed(current.at, now: now) { return .cancelled(current.action) }
        switch input {
        case .approve: return .confirmed(current.action)
        case .other: return .cancelled(current.action)
        }
    }

    /// The pending action once its window is over, reported once; nil otherwise.
    public mutating func expire(now: Date) -> PendingAction? {
        guard let current = armed, lapsed(current.at, now: now) else { return nil }
        armed = nil
        return current.action
    }

    private func lapsed(_ since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) >= window
    }
}
