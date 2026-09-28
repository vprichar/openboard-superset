import Foundation

/**
 Snippets that would destroy a session are refused in code.

 A snippet is typed into whatever Claude Code session has focus, and snippets live in
 plain, editable JSON — so one careless edit (or a default carried over from another
 layout) puts `/clear` on a key, and a single press throws away a session's context.
 The config is not the place to rely on for that; this is.

 Every line is checked, not just the first: typing a newline submits the line before
 it, so a command on the second line arrives as a command of its own. Leading
 whitespace and case are ignored for the same reason — the session ignores them too.

 The match is a prefix, not a whole word. Refusing a legitimate `/clearance` costs one
 log line; letting `/clear` through with something glued on costs a session.
 */
public enum SnippetGuard {
    public enum Verdict: Equatable, Sendable { case allow, block(reason: String) }

    /// Commands that end, reset or wipe the session they are typed into.
    public static let dangerousPrefixes = ["/clear", "/reset", "/exit", "/quit", "/logout"]

    public static func check(_ text: String, allowDangerous: Bool) -> Verdict {
        guard !allowDangerous else { return .allow }
        for line in text.split(whereSeparator: \.isNewline) {
            let command = line.drop { $0.isWhitespace }.lowercased()
            if let hit = dangerousPrefixes.first(where: { command.hasPrefix($0) }) {
                return .block(reason: "snippet starts with \(hit) (snippetsAllowDangerous is off)")
            }
        }
        return .allow
    }
}

/**
 `enter` is not blind.

 A bare ⏎ right after a snippet submits whatever the snippet just typed, reviewed or
 not. Inside the window after a snippet it is refused; outside it, or with no snippet
 at all, it is an ordinary key. Time is injected so the rule is testable.
 */
public struct EnterGuard: Sendable {
    public let window: TimeInterval
    private var lastSnippet: Date?

    public init(window: TimeInterval = 10) {
        self.window = window
    }

    public mutating func noteSnippet(now: Date) {
        lastSnippet = now
    }

    public func allowsEnter(now: Date) -> Bool {
        guard let lastSnippet else { return true }
        return now.timeIntervalSince(lastSnippet) >= window
    }
}
