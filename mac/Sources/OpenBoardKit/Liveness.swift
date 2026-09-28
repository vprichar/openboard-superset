import Foundation

/**
 Whether the process behind a key is still there, and where a session went when it moved.

 Two ways the board lied, both seen live. A session whose process died without
 `SessionEnd` kept an idle key until its slot was needed or twelve hours passed, and
 pressing it raised a tab with no Claude in it. And a session resumed in another
 terminal (`claude --resume <id>`) kept the old pid and terminal, because `enrich` only
 fills what is missing — so a jump went to the tab the session had left.

 Pure: every check takes `isAlive`, so the rules are testable without a process to kill.
 A session without a pid is never judged (there is nothing to watch), and neither is one
 born on Superset's bus, which says itself when those end (`releaseBus`, `syncBus`).
 */
public enum Liveness {
    /// How often the app sweeps. `kill(pid, 0)` per session is cheap enough that the
    /// interval is about how long a dead key may stay lit, not about cost.
    public static let checkInterval: TimeInterval = 5

    /// A session ended because its process was gone.
    public struct Ended: Equatable, Sendable {
        public let sessionID: String
        public let pid: Int
        public let slot: Int
    }

    /// A known session that spoke from another process or terminal.
    public struct Move: Equatable, Sendable {
        public let sessionID: String
        public let fromPID: Int?
        public let toPID: Int?
        public let fromTerminal: String?
        public let toTerminal: String?
        /// It had been ended (its old process was gone) and is back on its key.
        public let revived: Bool
    }

    /// What a jump should do.
    public enum JumpCheck: Equatable, Sendable {
        case go
        /// The process is gone: do not raise anything; the session is now ended.
        case dead(Ended)
    }

    /// Whether this entry's process is one the check may judge.
    public static func isWatched(_ entry: SessionRegistry.Entry) -> Bool {
        entry.pid != nil && !entry.isBusBorn && entry.state != .ended
    }

    /**
     Whether a hook with this pid and terminal says the session has moved.

     A different value on either side, both present — a hook that omits one proves
     nothing. An ended entry hearing from any pid other than its own has been resumed:
     it was ended because that old process was gone.
     */
    public static func hasMoved(
        _ entry: SessionRegistry.Entry, pid: Int?, supersetTerminalID: String?
    ) -> Bool {
        if let pid, entry.pid != pid, entry.pid != nil || entry.state == .ended { return true }
        if let terminal = supersetTerminalID, let current = entry.supersetTerminalID,
           terminal != current { return true }
        return false
    }

    public static func endedLogLine(_ ended: Ended) -> String {
        "session \(ended.sessionID.prefix(8)) ended: process \(ended.pid) is gone"
    }

    public static func movedLogLine(_ move: Move) -> String {
        let pid = { (value: Int?) in value.map(String.init) ?? "none" }
        let terminal = { (value: String?) in value.map { String($0.prefix(8)) } ?? "none" }
        return "session \(move.sessionID.prefix(8)) moved: "
            + "pid \(pid(move.fromPID)) → \(pid(move.toPID)), "
            + "terminal \(terminal(move.fromTerminal)) → \(terminal(move.toTerminal))"
            + (move.revived ? " (revived)" : "")
    }
}

extension SessionRegistry {
    /**
     End every watched session whose process is gone. Its key goes dark and, being
     `ended`, is reclaimable at once — but the entry stays, so a resume of the same
     session can come back on the same key. Returns what it ended, for the log.
     */
    @discardableResult
    public mutating func endGoneSessions(
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> [Liveness.Ended] {
        var ended: [Liveness.Ended] = []
        for entry in entries where Liveness.isWatched(entry) && !isAlive(entry.pid) {
            guard let pid = entry.pid else { continue }
            markEnded(sessionID: entry.sessionID, now: now)
            ended.append(Liveness.Ended(sessionID: entry.sessionID, pid: pid, slot: entry.slot))
        }
        return ended
    }

    /// The same check for one session, right before raising it: a dead process is
    /// ended here rather than jumped to.
    public mutating func checkBeforeJump(
        sessionID: String,
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> Liveness.JumpCheck {
        guard let entry = entry(forSession: sessionID), Liveness.isWatched(entry),
              let pid = entry.pid, !isAlive(pid)
        else { return .go }
        markEnded(sessionID: sessionID, now: now)
        return .dead(Liveness.Ended(sessionID: sessionID, pid: pid, slot: entry.slot))
    }

    /**
     A known session heard from another pid or terminal takes the new ones — replaced,
     not filled in as `enrich` does — and leaves `ended` if it was. Same slot, same
     place on the pad. Nil when nothing moved.

     The tty goes with the pid: a new process's old tty would raise the wrong tab. The
     host is asked again (`enrich`) for the same reason.
     */
    @discardableResult
    public mutating func relocate(
        sessionID: String,
        pid: Int?,
        tty: String?,
        supersetTerminalID: String?,
        supersetWorkspaceID: String? = nil,
        now: Date = Date()
    ) -> Liveness.Move? {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        let before = entries[index]
        guard Liveness.hasMoved(before, pid: pid, supersetTerminalID: supersetTerminalID) else { return nil }

        if let pid, pid != before.pid {
            entries[index].pid = pid
            entries[index].tty = tty
            entries[index].host = .unknown
        } else if let tty {
            entries[index].tty = tty
        }
        if let supersetTerminalID { entries[index].supersetTerminalID = supersetTerminalID }
        if let supersetWorkspaceID { entries[index].supersetWorkspaceID = supersetWorkspaceID }

        let revived = before.state == .ended
        if revived {
            // Back at rest; the hook that brought it applies its own state next.
            entries[index].state = .idle
            entries[index].stateSince = now
            entries[index].pendingTool = nil
            entries[index].delegatingAgentIDs = []
        }
        entries[index].isUnconfirmed = false
        entries[index].updatedAt = now
        return Liveness.Move(
            sessionID: sessionID,
            fromPID: before.pid, toPID: entries[index].pid,
            fromTerminal: before.supersetTerminalID, toTerminal: entries[index].supersetTerminalID,
            revived: revived
        )
    }
}
