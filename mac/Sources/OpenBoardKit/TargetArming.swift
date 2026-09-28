import Foundation

/**
 The armed mode of targeted control (D10): FAST held arms a send of the default
 snippet, REJ turns it into an interrupt, and the next agent key fires it at that
 agent — **without jumping** to it.

 Chosen over the plan's chord (hold an agent key + REJ/FAST) because agent keys jump on
 press today; a chord would delay every jump to the release. Everything here is inert
 while disarmed: each method returns `.none` and the key does what it always does.

 Like `PendingConfirmation`, a key that lands after the window cancels instead of
 firing, so a send the user saw lapse never goes out.
 */
public struct TargetArming {
    public typealias Intent = TargetedControl.Intent

    public enum Step: Equatable, Sendable {
        case armed(Intent)
        case fire(Intent, padKey: Int)
        case cancelled
        /// Not armed: the key keeps its ordinary meaning.
        case none
    }

    private let window: TimeInterval
    private let snippet: String
    private var armed: (intent: Intent, at: Date)?

    /// `snippet` is `targeted.defaultSnippet`; the default only mirrors that preference.
    public init(window: TimeInterval, snippet: String = Preferences.Targeted().defaultSnippet) {
        self.window = window
        self.snippet = snippet
    }

    /// Arming again restarts the window and resets the intent to a send.
    public mutating func arm(now: Date) -> Step {
        let intent = Intent.send(text: snippet)
        armed = (intent, now)
        return .armed(intent)
    }

    public mutating func reject(now: Date) -> Step {
        guard let current = armed else { return .none }
        if lapsed(current.at, now: now) { armed = nil; return .cancelled }
        armed = (.interrupt, now)
        return .armed(.interrupt)
    }

    public mutating func agentKey(_ padKey: Int, now: Date) -> Step {
        guard let current = armed else { return .none }
        armed = nil
        if lapsed(current.at, now: now) { return .cancelled }
        return .fire(current.intent, padKey: padKey)
    }

    public mutating func otherKey(now: Date) -> Step {
        guard armed != nil else { return .none }
        armed = nil
        return .cancelled
    }

    /// `.cancelled` once the window is over, reported once; `.none` otherwise.
    public mutating func expire(now: Date) -> Step {
        guard let current = armed, lapsed(current.at, now: now) else { return .none }
        armed = nil
        return .cancelled
    }

    private func lapsed(_ since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) >= window
    }
}
