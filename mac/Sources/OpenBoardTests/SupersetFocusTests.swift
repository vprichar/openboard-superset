import Foundation
import OpenBoardKit
import SQLite3

/**
 Which Superset workspace you are looking at.

 Three signals, none authoritative on its own: Superset's attach time moves when you
 switch workspaces in its sidebar, a prompt is typed into the workspace you are in, and
 a jump from the pad goes to the one you pressed. The newest one wins. The database
 tests run against a real SQLite file with Superset's real `terminal_sessions` schema —
 never against `~/.superset`, which belongs to Superset.
 */
func runSupersetFocusTests() {
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    func tempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-superset-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A writable database with Superset's schema, in WAL mode like the real one.
    func makeHostDB(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE `terminal_sessions` (
            `id` text PRIMARY KEY NOT NULL,
            `origin_workspace_id` text,
            `status` text DEFAULT 'active' NOT NULL,
            `created_at` integer NOT NULL,
            `last_attached_at` integer,
            `ended_at` integer, `dispose_requested_at` integer, `custom_title` text
        );
        CREATE TABLE `workspaces` (
            `id` text PRIMARY KEY NOT NULL,
            `worktree_path` text NOT NULL,
            `branch` text NOT NULL,
            `created_at` integer NOT NULL
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return nil }
        return db
    }

    func exec(_ db: OpaquePointer?, _ sql: String) {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        expectEqual(result, SQLITE_OK, "fixture SQL failed: \(sql)")
    }

    test("the most recent attach wins") {
        var resolver = SupersetFocus.Resolver()
        expect(resolver.winner == nil, "no signal at all is nothing, not a guess")
        resolver.note(.init(workspaceID: "prompted", at: at(5), source: .prompt))
        resolver.note(.init(workspaceID: "frontend", at: at(10), source: .attach))
        expectEqual(resolver.winner?.workspaceID, "frontend", "an older prompt must not win")
        resolver.note(.init(workspaceID: "backend", at: at(20), source: .attach))
        expectEqual(resolver.winner?.workspaceID, "backend")
    }

    test("a later prompt beats the attach it followed") {
        // Switching tabs inside Superset does not move the attach time, but typing into
        // a session does say where you are.
        var resolver = SupersetFocus.Resolver()
        resolver.note(.init(workspaceID: "frontend", at: at(10), source: .attach))
        resolver.note(.init(workspaceID: "backend", at: at(20), source: .prompt))
        expectEqual(resolver.winner?.workspaceID, "backend")

        // The poll re-reads the same row every second; the same old attach must not
        // take it back.
        resolver.note(.init(workspaceID: "frontend", at: at(10), source: .attach))
        expectEqual(resolver.winner?.workspaceID, "backend")

        // A genuinely new attach does.
        resolver.note(.init(workspaceID: "frontend", at: at(30), source: .attach))
        expectEqual(resolver.winner?.workspaceID, "frontend")

        resolver.note(.init(workspaceID: "brain", at: at(40), source: .jump))
        expectEqual(resolver.winner?.workspaceID, "brain", "a pad jump is the newest word")
    }

    test("the context follows Superset, sticks elsewhere, and yields to a terminal") {
        let previous = BoardContext.superset(workspaceID: "frontend")
        expectEqual(
            SupersetFocus.context(scope: .focusedWorkspace, front: .superset,
                                  resolved: "backend", previous: previous),
            .superset(workspaceID: "backend")
        )
        expectEqual(
            SupersetFocus.context(scope: .focusedWorkspace, front: .superset,
                                  resolved: nil, previous: previous),
            .all, "no signal falls back to everything"
        )
        expectEqual(
            SupersetFocus.context(scope: .focusedWorkspace, front: .other,
                                  resolved: "backend", previous: previous),
            previous, "a browser in front keeps the last workspace"
        )
        expectEqual(
            SupersetFocus.context(scope: .focusedWorkspace, front: .terminalHost,
                                  resolved: "backend", previous: previous),
            .all
        )
        expectEqual(
            SupersetFocus.context(scope: .all, front: .superset,
                                  resolved: "backend", previous: previous),
            .all, "the preference turns the whole thing off"
        )
    }

    test("the live org is the one with a manifest") {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("00c24bf8-stale")
        let live = root.appendingPathComponent("55555555-live")
        for org in [stale, live] {
            try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
            try Data().write(to: org.appendingPathComponent("host.db"))
        }
        try Data("{}".utf8).write(to: live.appendingPathComponent("manifest.json"))

        expectEqual(
            SupersetFocus.databaseURL(root: root)?.standardizedFileURL.path,
            live.appendingPathComponent("host.db").standardizedFileURL.path
        )
        try FileManager.default.removeItem(at: live.appendingPathComponent("manifest.json"))
        expect(SupersetFocus.databaseURL(root: root) == nil, "no manifest, no guess")
    }

    test("a database with no attached sessions reads as nothing") {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("host.db")
        let writer = makeHostDB(at: url)
        defer { sqlite3_close(writer) }
        exec(writer, "INSERT INTO terminal_sessions (id, origin_workspace_id, status, created_at) VALUES ('t1', 'ws', 'active', 1)")

        let reader = try Harness.require(SupersetHostDatabase(url: url), "could not open the fixture")
        expect(reader.latestAttach() == nil)
    }

    test("the newest active attach is read from a live WAL database, read-only") {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("host.db")
        let writer = makeHostDB(at: url)
        defer { sqlite3_close(writer) }
        exec(writer, """
        INSERT INTO terminal_sessions (id, origin_workspace_id, status, created_at, last_attached_at) VALUES
          ('old', 'backend', 'active', 1, 1790000000000),
          ('new', 'frontend', 'active', 1, 1790000005000),
          ('gone', 'brain', 'disposed', 1, 1790000009000),
          ('never', 'brain', 'active', 1, NULL);
        INSERT INTO workspaces (id, worktree_path, branch, created_at) VALUES
          ('frontend', '/tmp/feature-branch', 'b', 1);
        """)

        let reader = try Harness.require(SupersetHostDatabase(url: url), "could not open the fixture")
        let first = try Harness.require(reader.latestAttach())
        expectEqual(first.workspaceID, "frontend")
        expectEqual(first.source, .attach)
        expectEqual(first.at, Date(timeIntervalSince1970: 1_790_000_005))
        expectEqual(reader.worktrees(), ["frontend": "/tmp/feature-branch"])

        // Written after the reader opened, into the WAL: an `immutable` open would
        // never see it, and the poll would be stuck on the first answer.
        exec(writer, "UPDATE terminal_sessions SET last_attached_at = 1790000010000 WHERE id = 'old'")
        expectEqual(reader.latestAttach()?.workspaceID, "backend")

        // Read-only means read-only.
        expectEqual(reader.canWrite, false)
    }

    test("terminal liveness is read from a temporary host.db, read-only") {
        // Built by the test in a temp directory — never ~/.superset, which is Superset's.
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("host.db")
        let writer = makeHostDB(at: url)
        defer { sqlite3_close(writer) }
        exec(writer, """
        INSERT INTO terminal_sessions (id, origin_workspace_id, status, created_at, ended_at) VALUES
          ('live', 'ws', 'active', 1, NULL),
          ('gone', 'ws', 'disposed', 1, NULL),
          ('over', 'ws', 'active', 1, 1790000000000),
          ('odd', 'ws', 'hibernating', 1, NULL);
        """)

        let reader = try Harness.require(SupersetHostDatabase(url: url), "could not open the fixture")
        expectEqual(reader.terminalLiveness("live"), .active)
        expectEqual(reader.terminalLiveness("gone"), .disposed)
        expectEqual(reader.terminalLiveness("over"), .ended, "ended_at set means ended")
        expectEqual(reader.terminalLiveness("missing"), nil, "an unknown terminal is not a verdict")
        expectEqual(reader.terminalLiveness("odd"), nil, "an unknown status is not guessed")
        expectEqual(reader.terminalLiveness("x' OR '1'='1"), nil, "the id is bound, not spliced")

        // Written after the reader opened: the WAL must be seen, as for attaches.
        exec(writer, "UPDATE terminal_sessions SET status = 'disposed' WHERE id = 'live'")
        expectEqual(reader.terminalLiveness("live"), .disposed)

        expectEqual(reader.canWrite, false, "liveness must not open Superset's db for writing")
    }

    test("a host.db without ended_at still opens, and liveness reads as unknown") {
        // A schema change in Superset costs the feature, not the attach poll.
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("host.db")
        var db: OpaquePointer?
        expectEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        exec(db, """
        CREATE TABLE terminal_sessions (id text PRIMARY KEY, origin_workspace_id text,
          status text NOT NULL, created_at integer NOT NULL, last_attached_at integer);
        INSERT INTO terminal_sessions VALUES ('t', 'ws', 'active', 1, 1790000000000);
        """)
        defer { sqlite3_close(db) }

        let reader = try Harness.require(SupersetHostDatabase(url: url), "attach poll lost to a schema change")
        expectEqual(reader.latestAttach()?.workspaceID, "ws")
        expectEqual(reader.terminalLiveness("t"), nil)
    }

    workspaceArrivalChecks(base: base)
}

/**
 APPR/REJ into a session in another workspace. The deep link brings Superset to the
 front at once, but the workspace switch lands later: an ⏎ sent when Superset was merely
 in front went into the workspace being left. Seen live — "approve sent to key 6" and
 the prompt still open — so the key is held until Superset's own attach names the
 session's workspace, and never sent if it does not.
 */
private func workspaceArrivalChecks(base: Date) {
    func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
    let target = "other-workspace-ws"
    let here = "feature-branch-ws"

    test("arrival: the same workspace, or a session without one, does not wait") {
        expect(!SupersetFocus.mustAwaitWorkspace(target: here, active: here))
        expect(!SupersetFocus.mustAwaitWorkspace(target: nil, active: here))
        expect(SupersetFocus.mustAwaitWorkspace(target: target, active: here))
        expect(SupersetFocus.mustAwaitWorkspace(target: target, active: nil))
    }

    test("arrival: only an attach of that workspace, from this press on, confirms it") {
        let wait = SupersetFocus.WorkspaceWait(workspaceID: target, since: at(0), timeout: 1.5)
        // Superset in front but still on the old workspace: keep waiting.
        expectEqual(wait.step(attach: .init(workspaceID: here, at: at(0.2), source: .attach), now: at(0.3)), .wait)
        // An old attach of the target is not this switch.
        expectEqual(wait.step(attach: .init(workspaceID: target, at: at(-30), source: .attach), now: at(0.3)), .wait)
        expectEqual(wait.step(attach: nil, now: at(0.3)), .wait)
        expectEqual(wait.step(attach: .init(workspaceID: target, at: at(0.4), source: .attach), now: at(0.5)), .send)
        expectEqual(wait.step(attach: .init(workspaceID: here, at: at(0.2), source: .attach), now: at(1.6)), .giveUp)
    }

    test("arrival: the key is not sent until the attach confirms the workspace") {
        let log = EventLog()
        let clock = FakeClock(base)
        // The attach names the target from the third read on.
        let confirmed = blockingArrival {
            await SupersetFocus.awaitWorkspace(
                .init(workspaceID: target, since: base, timeout: 1.5), poll: 0.1,
                now: { clock.now },
                latestAttach: {
                    log.events.append("read")
                    let reads = log.events.filter { $0 == "read" }.count
                    return reads >= 3
                        ? .init(workspaceID: target, at: clock.now, source: .attach)
                        : .init(workspaceID: here, at: base.addingTimeInterval(-5), source: .attach)
                },
                sleep: { clock.advance($0) }
            ) {
                log.events.append("send")
            }
        }
        expect(confirmed)
        expectEqual(log.events, ["read", "read", "read", "send"])
    }

    test("arrival: without a confirmation in time, nothing is sent") {
        let log = EventLog()
        let clock = FakeClock(base)
        let confirmed = blockingArrival {
            await SupersetFocus.awaitWorkspace(
                .init(workspaceID: target, since: base, timeout: 1.5), poll: 0.1,
                now: { clock.now },
                latestAttach: {
                    log.events.append("read")
                    return .init(workspaceID: here, at: clock.now, source: .attach)
                },
                sleep: { clock.advance($0) }
            ) {
                log.events.append("send")
            }
        }
        expect(!confirmed)
        expect(!log.events.contains("send"), "the key must not reach a workspace that never came forward")
        expect(clock.now <= base.addingTimeInterval(1.6), "bounded by the timeout")
        expectEqual(
            SupersetFocus.didNotComeForwardLogLine(workspaceID: target),
            "respond: workspace other-wo did not come forward — not sent"
        )
    }
}

private final class EventLog: @unchecked Sendable { var events: [String] = [] }
private final class FakeClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
private final class ArrivalBox: @unchecked Sendable { var value = false }
private func blockingArrival(_ body: @escaping @Sendable () async -> Bool) -> Bool {
    let done = DispatchSemaphore(value: 0)
    let box = ArrivalBox()
    Task.detached { box.value = await body(); done.signal() }
    _ = done.wait(timeout: .now() + 5)
    return box.value
}
