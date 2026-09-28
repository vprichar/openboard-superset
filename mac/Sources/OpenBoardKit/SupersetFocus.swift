import Foundation
import SQLite3

/**
 Which Superset workspace you are looking at.

 Superset does not say. What it does leave behind is `terminal_sessions.last_attached_at`
 in its host database: switching workspaces in the sidebar attaches that workspace's
 terminals, and the newest attach moved within a second every time it was checked by
 hand. Switching *tabs* inside a workspace does not move it — every tab of the workspace
 is already attached — so it names the workspace and never the terminal.

 Two more signals fill the gaps it leaves: a prompt submitted from a session says you
 are in that session's workspace, and a jump from the pad says you are about to be.
 None of the three is authoritative, so the rule is simply **the newest one wins**.
 */
public enum SupersetFocus {
    public enum Source: String, Sendable { case attach, prompt, jump }

    public struct Signal: Equatable, Sendable {
        public var workspaceID: String
        public var at: Date
        public var source: Source
        public init(workspaceID: String, at: Date, source: Source) {
            self.workspaceID = workspaceID
            self.at = at
            self.source = source
        }
    }

    /// Newest signal wins. Kept per source so the log can say why, and so the poll
    /// re-reading the same attach row every second cannot take the lead back from a
    /// prompt that came after it: an equal-or-older signal never displaces a newer one.
    public struct Resolver: Equatable, Sendable {
        public private(set) var latest: [Source: Signal] = [:]

        public init() {}

        public mutating func note(_ signal: Signal) {
            if let known = latest[signal.source], known.at >= signal.at { return }
            latest[signal.source] = signal
        }

        public var winner: Signal? {
            latest.values.max { a, b in
                a.at != b.at ? a.at < b.at : a.source.rawValue < b.source.rawValue
            }
        }
    }

    /// What is in front, as far as the pad's context is concerned.
    public enum Front: Sendable {
        case superset
        /// Terminal, cmux, VS Code: surfaces with sessions of their own that are not in
        /// any Superset workspace, so filtering by one would hide what you are using.
        case terminalHost
        /// Anything else — a browser, the docs. You have stepped away from Superset,
        /// not gone somewhere else to work, so the pad keeps the workspace you left.
        case other
    }

    /**
     The pad's context, given what is in front.

     - Parameter resolved: the resolver's winning workspace, if any. Nil while
       Superset is in front means nothing could be read, and the pad falls back to
       everything rather than guessing a workspace.
     */
    public static func context(
        scope: PadScope, front: Front, resolved: String?, previous: BoardContext
    ) -> BoardContext {
        guard scope == .focusedWorkspace else { return .all }
        switch front {
        case .superset: return resolved.map { .superset(workspaceID: $0) } ?? .all
        case .terminalHost: return .all
        case .other: return previous
        }
    }

    /// `~/.superset/host`, where each organization gets a folder.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".superset/host", isDirectory: true)
    }

    /**
     The live organization's `host.db`.

     There can be several org folders, and a stale one still has a `host.db`. The live
     one is the one Superset's host service has written a `manifest.json` into, so that
     is what is looked for rather than an id being hardcoded. With more than one, the
     newest manifest wins.
     */
    public static func databaseURL(root: URL = defaultRoot) -> URL? {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        let candidates = orgs.compactMap { org -> (db: URL, modified: Date)? in
            let manifest = org.appendingPathComponent("manifest.json")
            let db = org.appendingPathComponent("host.db")
            guard fm.fileExists(atPath: manifest.path), fm.fileExists(atPath: db.path) else {
                return nil
            }
            let modified = (try? fm.attributesOfItem(atPath: manifest.path))?[.modificationDate]
                as? Date ?? .distantPast
            return (db, modified)
        }
        return candidates.max { $0.modified < $1.modified }?.db
    }
}

/**
 Answering a prompt in another workspace.

 The deep link brings Superset to the front at once; the workspace switch lands a
 moment later. `Actions.respond` used to count "Superset is in front" as landed, so an
 ⏎ pressed on a borrowed key went into the workspace being left — logged as sent, the
 prompt still open. Superset's own attach (`SupersetHostDatabase.latestAttach`) is the
 signal that the switch happened, so the key waits for it, briefly, and is not sent at
 all if it never comes.
 */
extension SupersetFocus {
    /// Whether answering this session has to wait for its workspace. A session with no
    /// workspace, or in the one already in front, answers as before.
    public static func mustAwaitWorkspace(target: String?, active: String?) -> Bool {
        guard let target else { return false }
        return target != active
    }

    public struct WorkspaceWait: Equatable, Sendable {
        public enum Step: Equatable, Sendable { case send, wait, giveUp }

        public let workspaceID: String
        /// When the key was pressed. Only an attach from then on is this switch.
        public let since: Date
        public let timeout: TimeInterval
        /// Superset stamps the attach with its own clock; a little slack keeps a switch
        /// that landed just as the key went down from being missed.
        public static let clockSlack: TimeInterval = 0.25

        public init(workspaceID: String, since: Date, timeout: TimeInterval = 1.5) {
            self.workspaceID = workspaceID
            self.since = since
            self.timeout = timeout
        }

        public func step(attach: Signal?, now: Date) -> Step {
            if let attach, attach.workspaceID == workspaceID,
               attach.at >= since.addingTimeInterval(-Self.clockSlack) {
                return .send
            }
            return now.timeIntervalSince(since) >= timeout ? .giveUp : .wait
        }
    }

    /**
     Poll the attach until it names the workspace, then `send`; give up at the timeout
     without sending. Suspends between reads rather than sleeping the thread, and runs
     in the caller's isolation, so the main actor keeps serving while it waits.
     Returns whether it sent.
     */
    public static func awaitWorkspace(
        _ wait: WorkspaceWait,
        poll: TimeInterval = 0.08,
        now: () -> Date = Date.init,
        latestAttach: () -> Signal?,
        sleep: (TimeInterval) async -> Void,
        isolation: isolated (any Actor)? = #isolation,
        send: () -> Void
    ) async -> Bool {
        while true {
            switch wait.step(attach: latestAttach(), now: now()) {
            case .send:
                send()
                return true
            case .giveUp:
                return false
            case .wait:
                await sleep(poll)
            }
        }
    }

    public static func didNotComeForwardLogLine(workspaceID: String) -> String {
        "respond: workspace \(workspaceID.prefix(8)) did not come forward — not sent"
    }
}

/// What Superset's own table says about a terminal. Read-only evidence for the
/// restore: a restored session whose terminal is disposed or ended is not coming back.
public enum TerminalLiveness: String, Equatable, Sendable {
    case active, disposed, ended
}

/**
 Superset's host database, opened read-only.

 **It belongs to Superset.** `SQLITE_OPEN_READONLY`, never `immutable=1`: the database
 is in WAL mode and live, and an immutable open ignores the WAL — it would read the
 last checkpoint and never see a workspace switch.

 One connection, opened once, and prepared statements reused for every poll. Each read
 resets its statement as soon as the row is out: a statement left mid-step holds a read
 transaction open, and an open reader pins the WAL so Superset's checkpoints cannot
 finish and its log grows for as long as this app runs.
 */
public final class SupersetHostDatabase {
    public let url: URL
    private var db: OpaquePointer?
    private var attachStatement: OpaquePointer?
    private var worktreeStatement: OpaquePointer?
    private var livenessStatement: OpaquePointer?

    private static let attachSQL = """
        SELECT origin_workspace_id, last_attached_at FROM terminal_sessions
        WHERE status = 'active' AND last_attached_at IS NOT NULL
          AND origin_workspace_id IS NOT NULL
        ORDER BY last_attached_at DESC LIMIT 1
        """
    private static let worktreeSQL = "SELECT id, worktree_path FROM workspaces"
    private static let livenessSQL =
        "SELECT status, ended_at FROM terminal_sessions WHERE id = ? LIMIT 1"

    /// Nil when the file is missing, cannot be opened, or has no `terminal_sessions`
    /// with the columns the attach query needs — a schema change in Superset should
    /// cost the feature, not the app.
    public init?(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        // Superset writes constantly; a brief lock is waited out, not reported.
        sqlite3_busy_timeout(handle, 100)
        guard sqlite3_prepare_v2(handle, Self.attachSQL, -1, &attachStatement, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            db = nil
            return nil
        }
        // Optional: without it, entries without a workspace id simply are not matched
        // by directory.
        if sqlite3_prepare_v2(handle, Self.worktreeSQL, -1, &worktreeStatement, nil) != SQLITE_OK {
            worktreeStatement = nil
        }
        // Optional too: a schema without `ended_at` costs the restore check, not the
        // attach poll.
        if sqlite3_prepare_v2(handle, Self.livenessSQL, -1, &livenessStatement, nil) != SQLITE_OK {
            livenessStatement = nil
        }
    }

    deinit {
        sqlite3_finalize(attachStatement)
        sqlite3_finalize(worktreeStatement)
        sqlite3_finalize(livenessStatement)
        sqlite3_close(db)
    }

    /// The workspace of the most recently attached live terminal, stamped with when.
    public func latestAttach() -> SupersetFocus.Signal? {
        guard let statement = attachStatement else { return nil }
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        let millis = sqlite3_column_int64(statement, 1)
        return SupersetFocus.Signal(
            workspaceID: String(cString: raw),
            at: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
            source: .attach
        )
    }

    /// Workspace id → worktree path.
    public func worktrees() -> [String: String] {
        guard let statement = worktreeStatement else { return [:] }
        defer { sqlite3_reset(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0),
                  let path = sqlite3_column_text(statement, 1) else { continue }
            result[String(cString: id)] = String(cString: path)
        }
        return result
    }

    /**
     Whether a terminal still exists, as far as Superset's table says.

     Nil for a terminal the table does not have, for a status this code does not know,
     or when the query could not be prepared: none of those is evidence either way, and
     the caller must not end a session on a guess. `ended_at` wins over the status —
     a terminal that ended is gone whatever its row still says.
     */
    public func terminalLiveness(_ terminalID: String) -> TerminalLiveness? {
        guard let statement = livenessStatement else { return nil }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, terminalID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 1) != SQLITE_NULL { return .ended }
        guard let raw = sqlite3_column_text(statement, 0) else { return nil }
        switch String(cString: raw) {
        case "active": return .active
        case "disposed": return .disposed
        default: return nil
        }
    }

    /// Whether this connection could write. Always false; checked by the tests so a
    /// change to the open flags cannot quietly start touching Superset's database.
    public var canWrite: Bool {
        guard let db else { return false }
        return sqlite3_db_readonly(db, "main") == 0
    }
}
