import Foundation
import OpenBoardKit

/*
 The host-service client, against a fake transport.

 Nothing here opens a socket or reads `~/.superset/host`: manifests live in a temp
 directory and every response is scripted. The response bodies are copied from the
 spike's redacted fixtures (the JSON files under `openboard-teclado-evidencia/SP/fixtures`); each
 literal names the fixture it came from.
*/

// MARK: - Helpers

/// A token shaped like the real one (long, opaque) so a leak would be visible.
private let fakeToken = "sk_test_7Q2m9Vx4Lp8Rz1Nw5Ht3Yb6Kc0Jd"

/// Run async work from the synchronous harness. `Task.detached`, not `Task`: top-level
/// code is MainActor-isolated, and a plain Task would wait on the semaphore it blocks.
private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    guard done.wait(timeout: .now() + 5) == .success, let result = box.result else {
        throw HarnessError.requirementFailed
    }
    return try result.get()
}

/// Scripted responses, recorded requests.
private final class FakeTransport: SupersetTransport, @unchecked Sendable {
    enum Reply { case http(Int, String), refuse }
    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var fallback: [String: Reply] = [:]
    private(set) var requests: [HTTPRequestSpec] = []
    private(set) var tokensSeen: [String] = []

    /// Replies for `path`, in order; the last one repeats.
    func script(_ path: String, _ list: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies[path] = Array(list.dropLast())
        fallback[path] = list.last
    }

    var sent: [HTTPRequestSpec] { lock.lock(); defer { lock.unlock() }; return requests }

    func send(_ request: HTTPRequestSpec, manifest: SupersetManifest) async throws -> (status: Int, body: Data) {
        let reply: Reply? = {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            tokensSeen.append(manifest.token.withRaw { $0 })
            if var queue = replies[request.path], !queue.isEmpty {
                let next = queue.removeFirst()
                replies[request.path] = queue
                return next
            }
            return fallback[request.path]
        }()
        switch reply {
        case let .http(status, body): return (status, Data(body.utf8))
        case .refuse, nil: throw URLError(.cannotConnectToHost)
        }
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// Fixture: SP/fixtures/health.check.json (body), version as served by 1.30.0.
private func healthBody(_ version: String) -> String {
    """
    {"result":{"data":{"json":{"status":"ok","pid":2738,"version":"\(version)","installSource":"desktop",\
    "cloudRegistered":false,"registrationError":null,"sandboxBoot":null},\
    "meta":{"values":{"sandboxBoot":["undefined"]},"v":1}}}}
    """
}

// Fixture: SP/fixtures/terminalAgents.list.noauth.json (body).
private let unauthorizedBody = """
{"error":{"json":{"message":"Invalid or missing authentication token.","code":-32001,\
"data":{"code":"UNAUTHORIZED","httpStatus":401,"path":"terminalAgents.list","teardownFailure":null,\
"projectNotSetup":null,"deleteInProgress":null}},"meta":{"values":{"data.teardownFailure":["undefined"],\
"data.projectNotSetup":["undefined"],"data.deleteInProgress":["undefined"]},"v":1}}}
"""

// Fixture: SP/fixtures/terminalAgents.list.json (body), three of its nine bindings
// verbatim (account identity/email already redacted by SP), one per lastEventType seen.
private let agentsListBody = """
{"result":{"data":{"json":[\
{"terminalId":"7f8e5859-8a3b-4979-ba3e-b2698dfbc835","workspaceId":"11111111-1111-4111-8111-111111111111",\
"agentId":"claude","agentSessionId":"d683f20f-083c-49b9-a412-7642a4776d38","startedAt":1790439676649,\
"lastEventAt":1790544768218,"lastEventType":"Stop","account":{"agent":"claude","selection":null,\
"credentialKind":"subscription","identity":"«identity»","email":"«email»","directory":"/Users/someone/.claude"},\
"launchId":"4426-1790307058"},\
{"terminalId":"33333333-3333-4333-8333-333333333333","workspaceId":"11111111-1111-4111-8111-111111111111",\
"agentId":"claude","agentSessionId":"b7e3fe04-e547-49ab-b8c2-74ca76eb47f1","startedAt":1790549030346,\
"lastEventAt":1790549030346,"lastEventType":"Start","account":null,"launchId":"63033-1790541883"},\
{"terminalId":"d759550f-03c7-4558-b6cc-d46ef5e3f86c","workspaceId":"11111111-1111-4111-8111-111111111111",\
"agentId":"claude","agentSessionId":"c0c81f81-fb44-4cee-ad88-f2768276324e","startedAt":1790544616594,\
"lastEventAt":1790544619641,"lastEventType":"Attached","account":null,"launchId":"x"}\
]}}}
"""

private let okBody = #"{"result":{"data":{"json":{"success":true}}}}"#

private let manifestOrg = "55555555-5555-4555-8555-555555555555"

private func manifest(port: Int = 51_234) -> SupersetManifest {
    SupersetManifest(
        endpoint: URL(string: "http://127.0.0.1:\(port)")!,
        organizationID: manifestOrg,
        token: SecretToken(fakeToken)
    )
}

private func tempRoot() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ob-k3-host-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Shape of the real manifest's keys (orquestación §0, hallazgo 7): endpoint,
/// authToken, organizationId, pid, startedAt. Values here are fake.
private func writeManifest(in root: URL, org: String, port: Int = 51_234) {
    let dir = root.appendingPathComponent(org)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = """
    {"endpoint":"http://127.0.0.1:\(port)","authToken":"\(fakeToken)","organizationId":"\(org)",\
    "pid":4242,"startedAt":1790549000000}
    """
    try? Data(json.utf8).write(to: dir.appendingPathComponent("manifest.json"))
}

/// Decode `{"json":…}` from a query item or a body and hand back the inner object.
private func innerJSON(_ text: String?) -> [String: Any]? {
    guard let text, let data = text.data(using: .utf8),
          let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return outer["json"] as? [String: Any]
}

// MARK: - Manifest

func runSupersetManifestTests() {
    test("manifest: parses endpoint, organizationId and authToken") {
        let root = tempRoot()
        writeManifest(in: root, org: manifestOrg, port: 50_001)
        let m = try SupersetManifestLocator.resolve(root: root, orgID: manifestOrg)
        expectEqual(m.endpoint.absoluteString, "http://127.0.0.1:50001")
        expectEqual(m.organizationID, manifestOrg)
        expectEqual(m.token.withRaw { $0 }, fakeToken)
    }

    test("manifest: orgID nil with exactly one manifest picks it") {
        let root = tempRoot()
        writeManifest(in: root, org: manifestOrg)
        // A folder without a manifest does not count as a second org.
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("00c24bf8-empty"), withIntermediateDirectories: true)
        let m = try SupersetManifestLocator.resolve(root: root, orgID: nil)
        expectEqual(m.organizationID, manifestOrg)
    }

    test("manifest: orgID nil with two manifests is .ambiguous") {
        let root = tempRoot()
        writeManifest(in: root, org: manifestOrg)
        writeManifest(in: root, org: "00c24bf8-0000-4000-8000-000000000002")
        do {
            _ = try SupersetManifestLocator.resolve(root: root, orgID: nil)
            expect(false, "expected .ambiguous")
        } catch let error as SupersetManifestLocator.Failure {
            expectEqual(error, .ambiguous)
        }
    }

    test("manifest: none at all, or the named org absent, is .missing") {
        let root = tempRoot()
        for org in [nil, "nope"] as [String?] {
            do {
                _ = try SupersetManifestLocator.resolve(root: root, orgID: org)
                expect(false, "expected .missing for \(org ?? "nil")")
            } catch let error as SupersetManifestLocator.Failure {
                expectEqual(error, .missing)
            }
        }
        writeManifest(in: root, org: manifestOrg)
        do {
            _ = try SupersetManifestLocator.resolve(root: root, orgID: "other-org")
            expect(false, "expected .missing for an org that is not there")
        } catch let error as SupersetManifestLocator.Failure {
            expectEqual(error, .missing)
        }
    }

    test("manifest: a manifest without a token is .malformed, and the error does not echo the file") {
        let root = tempRoot()
        let dir = root.appendingPathComponent(manifestOrg)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(#"{"endpoint":"http://127.0.0.1:1","organizationId":"x"}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        do {
            _ = try SupersetManifestLocator.resolve(root: root, orgID: manifestOrg)
            expect(false, "expected .malformed")
        } catch let error as SupersetManifestLocator.Failure {
            expectEqual(error, .malformed)
        }
    }

    test("manifest: printing, dumping or interpolating it never shows the token") {
        let root = tempRoot()
        writeManifest(in: root, org: manifestOrg)
        let m = try SupersetManifestLocator.resolve(root: root, orgID: nil)
        var dumped = ""
        dump(m, to: &dumped)
        for text in ["\(m)", String(describing: m), String(reflecting: m), dumped] {
            expect(!text.contains(fakeToken), "token leaked: \(text.prefix(60))…")
        }
        expect("\(m)".contains("redacted"))
    }
}

// MARK: - Host client

func runSupersetHostClientTests() {
    func client(
        _ transport: FakeTransport,
        tested: String = "1.30.0",
        policy: Preferences.Superset.MismatchPolicy = .readOnly,
        hostClient: Preferences.Superset.HostClient = .auto,
        loads: Counter = Counter(),
        sink: LineSink = LineSink(),
        port: @escaping @Sendable () -> Int = { 51_234 }
    ) -> SupersetHostClient {
        SupersetHostClient(
            manifest: { loads.bump(); return manifest(port: port()) },
            transport: transport,
            testedVersion: tested,
            onMismatch: policy,
            hostClient: hostClient,
            log: { sink.append($0) }
        )
    }

    test("client: a query is GET /trpc/<proc>?input={\"json\":…} with bearer") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        t.script("/trpc/terminal.snapshot", [.http(200, #"{"result":{"data":{"json":"line 1\nline 2"}}}"#)])
        let c = client(t)
        let text = try blocking { try await c.snapshot(terminalID: "t-1", workspaceID: "w-1", maxLines: 20) }
        expectEqual(text, "line 1\nline 2")
        let req = try Harness.require(t.sent.last)
        expectEqual(req.method, "GET")
        expectEqual(req.path, "/trpc/terminal.snapshot")
        expect(req.bearer, "queries need the bearer header — /trpc accepts nothing else")
        expectEqual(req.body, nil)
        expectEqual(req.query.map(\.name), ["input"])
        let input = try Harness.require(innerJSON(req.query.first?.value))
        expectEqual(input["terminalId"] as? String, "t-1")
        expectEqual(input["workspaceId"] as? String, "w-1")
        expectEqual(input["maxLines"] as? Int, 20)
    }

    test("client: a query without input sends no ?input (health.check, terminalAgents.list)") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        t.script("/trpc/terminalAgents.list", [.http(200, agentsListBody)])
        let c = client(t)
        _ = try blocking { try await c.agents(workspaceID: nil) }
        expectEqual(t.sent.map(\.path), ["/trpc/health.check", "/trpc/terminalAgents.list"])
        expect(t.sent.allSatisfy { $0.method == "GET" && $0.query.isEmpty && $0.body == nil })
    }

    test("client: terminalAgents.list decodes into bindings, Attached included") {
        // Fixture: SP/fixtures/terminalAgents.list.json
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        t.script("/trpc/terminalAgents.list", [.http(200, agentsListBody)])
        let c = client(t)
        let list = try blocking { try await c.agents(workspaceID: nil) }
        expectEqual(list.count, 3)
        expectEqual(list.map(\.lastEventType), [.stop, .start, .attached])
        expectEqual(list.first?.terminalID, "7f8e5859-8a3b-4979-ba3e-b2698dfbc835")
        expectEqual(list.first?.workspaceID, "11111111-1111-4111-8111-111111111111")
        expectEqual(list.first?.agent, "claude")
        expectEqual(list.first?.lastEventAt, Date(timeIntervalSince1970: 1_790_544_768.218))
    }

    test("client: agents(workspaceID:) uses terminalAgents.listByWorkspace with {workspaceId}") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        t.script("/trpc/terminalAgents.listByWorkspace", [.http(200, #"{"result":{"data":{"json":[]}}}"#)])
        let c = client(t)
        _ = try blocking { try await c.agents(workspaceID: "w-9") }
        let req = try Harness.require(t.sent.last)
        expectEqual(req.path, "/trpc/terminalAgents.listByWorkspace")
        expectEqual(innerJSON(req.query.first?.value)?["workspaceId"] as? String, "w-9")
    }

    test("client: a mutation is POST /trpc/<proc> with body {\"json\":…}") {
        // Shape confirmed by source in SP (formas.md §1, resolveResponse.mjs:80-90); not
        // exercised live — SP-R made no mutations.
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        t.script("/trpc/terminal.writeInput", [.http(200, okBody)])
        t.script("/trpc/terminal.send", [.http(200, #"{"result":{"data":{"json":{"terminalId":"t","submitted":true}}}}"#)])
        t.script("/trpc/agents.run", [.http(200, #"{"result":{"data":{"json":{"kind":"terminal","sessionId":"s","label":"l"}}}}"#)])
        t.script("/trpc/terminalAgents.clearWorkspaceStatuses", [.http(200, okBody)])
        let c = client(t)
        try blocking {
            try await c.perform(.writeInput(terminalID: "t-1", workspaceID: "w-1", data: .escape))
            try await c.perform(.send(terminalID: "t-1", workspaceID: "w-1", text: "sigue", submit: true))
            try await c.perform(.runAgent(workspaceID: "w-1", agent: "claude", launch: .bare))
            try await c.perform(.clearStatuses(workspaceID: "w-1", terminalID: "t-1"))
        }
        let posts = t.sent.filter { $0.method == "POST" }
        expectEqual(posts.map(\.path), [
            "/trpc/terminal.writeInput", "/trpc/terminal.send",
            "/trpc/agents.run", "/trpc/terminalAgents.clearWorkspaceStatuses",
        ])
        expect(posts.allSatisfy { $0.bearer && $0.query.isEmpty })
        let bodies = posts.map { innerJSON($0.body.flatMap { String(data: $0, encoding: .utf8) }) }
        expectEqual(bodies[0]?["data"] as? String, "\u{1b}")
        expectEqual(bodies[0]?["terminalId"] as? String, "t-1")
        expectEqual(bodies[1]?["text"] as? String, "sigue")
        expectEqual(bodies[1]?["submit"] as? Bool, true)
        expectEqual(bodies[2]?["agent"] as? String, "claude")
        expectEqual(bodies[2]?["prompt"] as? String, "")
        expectEqual(bodies[2]?["workspaceId"] as? String, "w-1")
        expect(bodies[2]?["continueTerminalId"] == nil)
        expectEqual(bodies[3]?["workspaceId"] as? String, "w-1")
        expectEqual(bodies[3]?["terminalId"] as? String, "t-1")
    }

    test("client: the handoff runs with a prompt and never with continueTerminalId; transcript is read and capped") {
        // SP refuted continueTerminalId as a handoff (formas.md §4): the CLI reads the
        // transcript and sends it as the prompt. So does the pad.
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        t.script("/trpc/terminal.transcript", [.http(200, #"{"result":{"data":{"json":{"terminalId":"t-1","text":"hello\nworld"}}}}"#)])
        t.script("/trpc/agents.run", [.http(200, #"{"result":{"data":{"json":{"kind":"terminal","sessionId":"s","label":"l"}}}}"#)])
        let c = client(t)
        let text = try blocking { try await c.transcript(terminalID: "t-1", workspaceID: "w-1", maxChars: 99_999) }
        expectEqual(text, "hello\nworld")
        try blocking { try await c.perform(.runAgent(workspaceID: "w-1", agent: "codex", launch: .prompt("PROMPT"))) }
        let get = try Harness.require(t.sent.first { $0.path == "/trpc/terminal.transcript" })
        let input = innerJSON(get.query.first { $0.name == "input" }?.value)
        expectEqual(input?["maxChars"] as? Int, 36_000, "capped to TERMINAL_HANDOFF_MAX_CHARS")
        let post = try Harness.require(t.sent.first { $0.path == "/trpc/agents.run" })
        let body = innerJSON(post.body.flatMap { String(data: $0, encoding: .utf8) })
        expectEqual(body?["agent"] as? String, "codex")
        expectEqual(body?["prompt"] as? String, "PROMPT")
        expectEqual(body?["workspaceId"] as? String, "w-1")
        expect(body?["continueTerminalId"] == nil, "the handoff must not use continueTerminalId")
    }

    test("client: version ≠ testedVersion with read-only refuses writes and keeps queries") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.31.0"))])
        t.script("/trpc/terminalAgents.list", [.http(200, agentsListBody)])
        t.script("/trpc/terminal.writeInput", [.http(200, okBody)])
        let sink = LineSink()
        let c = client(t, sink: sink)
        let version = try blocking { try await c.health() }
        expectEqual(version, "1.31.0")
        let state = try blocking { await c.state }
        expectEqual(state, .versionMismatch(found: "1.31.0", tested: "1.30.0"))
        do {
            try blocking { try await c.perform(.writeInput(terminalID: "t", workspaceID: "w", data: .escape)) }
            expect(false, "a write must not go through in read-only mode")
        } catch let error as SupersetClientError {
            expectEqual(error, .readOnly(.terminalWriteInput))
        }
        expect(!t.sent.contains { $0.path == "/trpc/terminal.writeInput" }, "nothing was sent")
        let list = try blocking { try await c.agents(workspaceID: nil) }
        expectEqual(list.count, 3, "queries still work")
        expect(sink.lines.contains { $0.contains("1.31.0") && $0.contains("1.30.0") }, "the mismatch is logged")
    }

    test("client: a write before any health check checks the version first") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("2.0.0"))])
        t.script("/trpc/terminal.send", [.http(200, okBody)])
        let c = client(t)
        do {
            try blocking { try await c.perform(.send(terminalID: "t", workspaceID: "w", text: "x", submit: true)) }
            expect(false, "expected .readOnly")
        } catch let error as SupersetClientError {
            expectEqual(error, .readOnly(.terminalSend))
        }
        expectEqual(t.sent.map(\.path), ["/trpc/health.check"])
    }

    test("client: version mismatch with policy full lets writes through") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.31.0"))])
        t.script("/trpc/terminal.writeInput", [.http(200, okBody)])
        let c = client(t, policy: .full)
        try blocking { try await c.perform(.writeInput(terminalID: "t", workspaceID: "w", data: .carriageReturn)) }
        expect(t.sent.contains { $0.path == "/trpc/terminal.writeInput" })
        let state = try blocking { await c.state }
        expectEqual(state, .connected(version: "1.31.0", readOnly: false))
    }

    test("client: matching version is connected, not read-only") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        let c = client(t)
        _ = try blocking { try await c.health() }
        let state = try blocking { await c.state }
        expectEqual(state, .connected(version: "1.30.0", readOnly: false))
    }

    test("client: a 401 re-reads the manifest once and retries once") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(401, unauthorizedBody), .http(200, healthBody("1.30.0"))])
        let loads = Counter()
        let c = client(t, loads: loads)
        let version = try blocking { try await c.health() }
        expectEqual(version, "1.30.0")
        expectEqual(loads.value, 2, "initial read + one re-read")
        expectEqual(t.sent.count, 2, "the call + one retry")
    }

    test("client: a second 401 gives up with .unauthorized after one retry") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(401, unauthorizedBody)])
        let loads = Counter()
        let c = client(t, loads: loads)
        do {
            _ = try blocking { try await c.health() }
            expect(false, "expected .unauthorized")
        } catch let error as SupersetClientError {
            expectEqual(error, .unauthorized)
        }
        expectEqual(loads.value, 2)
        expectEqual(t.sent.count, 2)
    }

    test("client: a refused connection re-reads the manifest (the port moved) and retries") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.refuse, .http(200, healthBody("1.30.0"))])
        let loads = Counter()
        let c = client(t, loads: loads)
        _ = try blocking { try await c.health() }
        expectEqual(loads.value, 2)
        // Refused twice: unreachable, with no URL in the reason.
        let t2 = FakeTransport()
        t2.script("/trpc/health.check", [.refuse])
        let c2 = client(t2)
        do {
            _ = try blocking { try await c2.health() }
            expect(false, "expected .unreachable")
        } catch let error as SupersetClientError {
            expectEqual(error, .unreachable)
        }
        let state = try blocking { await c2.state }
        if case let .unreachable(reason) = state {
            expect(!reason.contains("127.0.0.1") && !reason.contains(fakeToken), "reason: \(reason)")
        } else {
            expect(false, "expected .unreachable state, got \(state)")
        }
    }

    test("client: hostClient off → every call is .disabled and nothing is sent") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        let loads = Counter()
        let c = client(t, hostClient: .off, loads: loads)
        for call in [SupersetCall.healthCheck, .listWorkspaces] {
            do {
                try blocking { try await c.perform(call) }
                expect(false, "expected .disabled")
            } catch let error as SupersetClientError {
                expectEqual(error, .disabled)
            }
        }
        do {
            _ = try blocking { try await c.health() }
            expect(false, "expected .disabled")
        } catch let error as SupersetClientError {
            expectEqual(error, .disabled)
        }
        expectEqual(t.sent.count, 0)
        expectEqual(loads.value, 0, "the manifest is not even read")
        let state = try blocking { await c.state }
        expectEqual(state, .off)
    }

    test("client: no captured log line contains the token") {
        let sink = LineSink()
        let t = FakeTransport()
        // A server error that echoes the token back must not reach the log either.
        t.script("/trpc/health.check", [.http(401, unauthorizedBody), .http(200, healthBody("1.31.0"))])
        t.script("/trpc/terminalAgents.list", [.http(500, #"{"error":{"json":{"message":"bad \#(fakeToken)","code":-32603,"data":{"code":"INTERNAL_SERVER_ERROR","httpStatus":500,"path":"terminalAgents.list"}}}}"#)])
        t.script("/trpc/terminal.send", [.http(200, okBody)])
        t.script("/trpc/workspace.list", [.refuse])
        let c = client(t, sink: sink)
        _ = try? blocking { try await c.health() }
        _ = try? blocking { try await c.agents(workspaceID: nil) }
        _ = try? blocking { try await c.perform(.send(terminalID: "t", workspaceID: "w", text: "x", submit: true)) }
        _ = try? blocking { try await c.perform(.listWorkspaces) }
        expect(!sink.lines.isEmpty, "the client logged something — otherwise this proves nothing")
        for line in sink.lines {
            expect(!line.contains(fakeToken), "token in log: \(line.prefix(80))")
            expect(!line.contains("Bearer"), "auth header in log: \(line.prefix(80))")
            expect(!line.contains("127.0.0.1"), "full URL in log: \(line.prefix(80))")
        }
        // The token did reach the transport: the check above is not vacuous.
        expect(t.tokensSeen.contains(fakeToken))
    }

    test("client: a non-2xx that is not 401 is an error naming only the tRPC code") {
        let t = FakeTransport()
        t.script("/trpc/health.check", [.http(200, healthBody("1.30.0"))])
        t.script("/trpc/terminalAgents.list", [.http(500, #"{"error":{"json":{"message":"secret stuff","code":-32603,"data":{"code":"INTERNAL_SERVER_ERROR","httpStatus":500,"path":"terminalAgents.list"}}}}"#)])
        let c = client(t)
        do {
            _ = try blocking { try await c.agents(workspaceID: nil) }
            expect(false, "expected an error")
        } catch let error as SupersetClientError {
            if case let .decoding(detail) = error {
                expect(detail.contains("INTERNAL_SERVER_ERROR"), detail)
                expect(!detail.contains("secret stuff"), "server message must not be carried: \(detail)")
            } else {
                expect(false, "expected .decoding, got \(error)")
            }
        }
    }

    runSupersetWireTests()
}

// MARK: - Wire (the pure parts of the app's SupersetConnection)

/// Called from `runSupersetHostClientTests`, so main.swift's list does not change.
private func runSupersetWireTests() {
    let endpoint = URL(string: "http://127.0.0.1:51234")!
    let t0 = Date(timeIntervalSince1970: 1_790_549_000)

    test("wire: a query URL carries ?input percent-encoded, and no token") {
        let spec = HTTPRequestSpec(method: "GET", path: "/trpc/terminal.snapshot",
                                   query: [URLQueryItem(name: "input", value: #"{"json":{"a":"x&y=z/1"}}"#)])
        let url = try Harness.require(SupersetWire.url(for: spec, endpoint: endpoint))
        let text = url.absoluteString
        expect(text.hasPrefix("http://127.0.0.1:51234/trpc/terminal.snapshot?input="), text)
        let raw = try Harness.require(text.split(separator: "?", maxSplits: 1).last.map(String.init))
        for c in ["{", "}", "\"", "&y", "=z", "/1"] {
            expect(!raw.dropFirst("input=".count).contains(c), "unencoded \(c) in \(raw)")
        }
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first
        expectEqual(decoded?.name, "input")
        expectEqual(decoded?.value, #"{"json":{"a":"x&y=z/1"}}"#, "round-trips")
        expect(!text.contains(fakeToken))
    }

    test("wire: a request without input has no query at all") {
        let url = SupersetWire.url(for: HTTPRequestSpec(method: "GET", path: "/trpc/health.check"), endpoint: endpoint)
        expectEqual(url?.absoluteString, "http://127.0.0.1:51234/trpc/health.check")
    }

    test("wire: /events with the header has the token in Authorization only, never in the URL") {
        let request = try Harness.require(
            SupersetWire.eventsRequest(endpoint: endpoint, token: SecretToken(fakeToken), tokenInQuery: false))
        expectEqual(request.url?.absoluteString, "ws://127.0.0.1:51234/events")
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeToken)")
        let https = SupersetWire.eventsRequest(endpoint: URL(string: "https://h:1")!, token: SecretToken("x"), tokenInQuery: false)
        expectEqual(https?.url?.scheme, "wss")
    }

    test("wire: /events with the query fallback has ?token= and no header") {
        let request = try Harness.require(
            SupersetWire.eventsRequest(endpoint: endpoint, token: SecretToken(fakeToken), tokenInQuery: true))
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
        let item = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first
        expectEqual(item?.name, "token")
        expectEqual(item?.value, fakeToken)
    }

    test("wire: backoff runs 1, 2, 4, 8, 10, 10 and resets to 1 after a message") {
        var r = SupersetWire.Reconnect()
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            if case let .wait(seconds) = r.ended(received: 0, handshakeStatus: nil) { delays.append(seconds) }
        }
        expectEqual(delays, [1, 2, 4, 8, 10, 10])
        expectEqual(r.ended(received: 3, handshakeStatus: nil), .wait(seconds: 1))
        expectEqual(r.ended(received: 0, handshakeStatus: nil), .wait(seconds: 2))
        expect(!r.tokenInQuery)
    }

    test("wire: the ?token= fallback only follows a 401/403 handshake, once, then back to the header") {
        var r = SupersetWire.Reconnect()
        for status in [nil, 500, 404] as [Int?] {
            _ = r.ended(received: 0, handshakeStatus: status)
            expect(!r.tokenInQuery, "no fallback after \(status.map(String.init) ?? "error")")
        }
        var s = SupersetWire.Reconnect()
        expectEqual(s.ended(received: 0, handshakeStatus: 401), .retryNow)
        expect(s.tokenInQuery)
        // Refused under the query token too: back to the header, on backoff.
        expectEqual(s.ended(received: 0, handshakeStatus: 401), .wait(seconds: 1))
        expect(!s.tokenInQuery)
        var f = SupersetWire.Reconnect()
        expectEqual(f.ended(received: 0, handshakeStatus: 403), .retryNow)
        // A 401 after messages arrived is a dropped socket, not a refused handshake.
        var g = SupersetWire.Reconnect()
        expectEqual(g.ended(received: 5, handshakeStatus: 401), .wait(seconds: 1))
        expect(!g.tokenInQuery)
    }

    test("keepalive: a ping every 20 s, nothing in between") {
        var k = SupersetWire.Keepalive(interval: 20, timeout: 10, now: t0)
        expectEqual(k.tick(now: t0.addingTimeInterval(19)), .none)
        expectEqual(k.tick(now: t0.addingTimeInterval(20)), .ping)
        expectEqual(k.tick(now: t0.addingTimeInterval(21)), .none, "one ping in flight at a time")
        k.pong(now: t0.addingTimeInterval(21))
        expectEqual(k.tick(now: t0.addingTimeInterval(39)), .none, "20 s counts from the last ping")
        expectEqual(k.tick(now: t0.addingTimeInterval(40)), .ping)
    }

    test("keepalive: no pong within 10 s → timed out; a late pong does not revive it") {
        var k = SupersetWire.Keepalive(interval: 20, timeout: 10, now: t0)
        expectEqual(k.tick(now: t0.addingTimeInterval(20)), .ping)
        expectEqual(k.tick(now: t0.addingTimeInterval(29.9)), .none)
        expectEqual(k.tick(now: t0.addingTimeInterval(30)), .timedOut)
        k.pong(now: t0.addingTimeInterval(31))
        expectEqual(k.tick(now: t0.addingTimeInterval(32)), .timedOut, "stays dead until a new connection")
    }
}
