import Foundation

/**
 Where APPR held goes (F6, D7): the session that has been waiting on you the longest,
 in any workspace.

 "Waiting" is `awaiting` (a prompt) or `error` (something broke and needs a look).
 `done` is not waiting — it finished, and a finished session that nobody revisited is
 key 6's business, not this one's. A tie on `since` is broken by session ID so the same
 board always jumps to the same place.
 */
public enum OldestWaiting {
    public struct Candidate: Equatable, Sendable {
        public var sessionID: String
        public var state: SessionState
        public var since: Date

        public init(sessionID: String, state: SessionState, since: Date) {
            self.sessionID = sessionID
            self.state = state
            self.since = since
        }
    }

    public static func pick(_ candidates: [Candidate]) -> Candidate? {
        candidates
            .filter { $0.state == .awaiting || $0.state == .error }
            .min { ($0.since, $0.sessionID) < ($1.since, $1.sessionID) }
    }
}
