import Foundation

/**
 The host-service client: tRPC over a transport it does not own.

 It turns a `SupersetCall` into an `HTTPRequestSpec` and a response body into values;
 the socket lives behind `SupersetTransport` (in the app), so everything here runs in
 tests against a scripted fake. Shapes verified by the spike (SP, formas.md):

 - Query: `GET /trpc/<proc>?input={"json":{…}}`, no `?input` when there is no input.
 - Mutation: `POST /trpc/<proc>` with body `{"json":{…}}` (by source; not yet live).
 - Reply `{"result":{"data":{"json":…}}}`; error `{"error":{"json":{…,data:{code,…}}}}`.
 - `/trpc` authenticates by `Authorization: Bearer` only, so every spec asks for it.

 Three fences, beyond the closed procedure list the contracts already give:

 - **Version.** The first call runs `health.check`. A version other than the tested
   one under the `read-only` policy (D8) refuses every writing call locally, before
   anything is sent; queries keep working.
 - **One retry.** Superset rewrites the manifest with a new port (and possibly a new
   token) on each start, so a 401 or a refused connection re-reads it once and retries
   once. Never a loop.
 - **Nothing sensitive in the log.** Lines name the method, the tRPC path and the
   status or tRPC error code — never the endpoint, the token, or a server message
   (which could echo input back).
 */
public actor SupersetHostClient: SupersetHostAPI {
    public typealias ManifestLoader = @Sendable () throws -> SupersetManifest

    private let loadManifest: ManifestLoader
    private let transport: SupersetTransport
    private let testedVersion: String
    private let onMismatch: Preferences.Superset.MismatchPolicy
    private let enabled: Bool
    private let log: @Sendable (String) -> Void

    private var manifest: SupersetManifest?
    private var version: String?
    private var linkState: SupersetLinkState

    /// `hostClient` and `log` are additions to the §1.2 contract, both defaulted: `off`
    /// makes every call `.disabled` without reading the manifest, and `log` lets tests
    /// capture what would reach `app.log`.
    public init(
        manifest: @escaping ManifestLoader,
        transport: SupersetTransport,
        testedVersion: String,
        onMismatch: Preferences.Superset.MismatchPolicy,
        hostClient: Preferences.Superset.HostClient = .auto,
        log: @escaping @Sendable (String) -> Void = { Log.write($0) }
    ) {
        self.loadManifest = manifest
        self.transport = transport
        self.testedVersion = testedVersion
        self.onMismatch = onMismatch
        self.enabled = hostClient == .auto
        self.log = log
        self.linkState = hostClient == .auto ? .searching : .off
    }

    public var state: SupersetLinkState { linkState }

    /// True once `health.check` has reported a version this client must not write to.
    public var readOnly: Bool {
        guard let version else { return false }
        return version != testedVersion && onMismatch == .readOnly
    }

    // MARK: - API

    public func health() async throws -> String {
        guard enabled else { throw SupersetClientError.disabled }
        let payload = try await execute(.healthCheck)
        guard let object = payload as? [String: Any], let found = object["version"] as? String else {
            throw fail(.decoding("health.check: no version"))
        }
        version = found
        if found == testedVersion {
            linkState = .connected(version: found, readOnly: false)
        } else if onMismatch == .readOnly {
            linkState = .versionMismatch(found: found, tested: testedVersion)
            log("superset: version \(found) ≠ tested \(testedVersion) — read-only until confirmed")
        } else {
            linkState = .connected(version: found, readOnly: false)
            log("superset: version \(found) ≠ tested \(testedVersion) — writes allowed by policy")
        }
        return found
    }

    public func agents(workspaceID: String?) async throws -> [AgentBinding] {
        let payload = try await run(.listAgents(workspaceID: workspaceID))
        guard let rows = payload as? [[String: Any]] else {
            throw fail(.decoding("terminalAgents: not a list"))
        }
        return rows.compactMap(Self.binding)
    }

    /// shape: unverified — SP did not call `terminal.snapshot`. A bare string or an
    /// object with `text` is accepted; anything else is a decoding error, not a guess.
    public func snapshot(terminalID: String, workspaceID: String, maxLines: Int) async throws -> String {
        let payload = try await run(.snapshot(terminalID: terminalID, workspaceID: workspaceID, maxLines: maxLines))
        if let text = payload as? String { return text }
        if let object = payload as? [String: Any], let text = object["text"] as? String { return text }
        throw fail(.decoding("terminal.snapshot: no text"))
    }

    /// `{terminalId, text, …}` (formas.md §2). A bare string is accepted as well.
    public func transcript(terminalID: String, workspaceID: String, maxChars: Int) async throws -> String {
        let payload = try await run(.transcript(terminalID: terminalID, workspaceID: workspaceID, maxChars: maxChars))
        if let text = payload as? String { return text }
        if let object = payload as? [String: Any], let text = object["text"] as? String { return text }
        throw fail(.decoding("terminal.transcript: no text"))
    }

    public func perform(_ call: SupersetCall) async throws {
        _ = try await run(call)
    }

    // MARK: - Pipeline

    /// Gate, then send. The version is known before the first write, always.
    private func run(_ call: SupersetCall) async throws -> Any {
        guard enabled else { throw SupersetClientError.disabled }
        if case .healthCheck = call { return try await health() }
        if version == nil { _ = try await health() }
        if call.procedure.writes, readOnly {
            log("superset: refused \(call.procedure.rawValue) — read-only (version \(version ?? "?"))")
            throw SupersetClientError.readOnly(call.procedure)
        }
        return try await execute(call)
    }

    private func execute(_ call: SupersetCall) async throws -> Any {
        let spec = try Self.request(for: call)
        var retried = false
        while true {
            let current: SupersetManifest
            do {
                current = try manifest ?? loadManifest()
                manifest = current
            } catch {
                linkState = .unreachable(reason: "no manifest")
                log("superset: \(spec.method) \(spec.path) — no manifest")
                throw SupersetClientError.unreachable
            }

            let status: Int
            let body: Data
            do {
                (status, body) = try await transport.send(spec, manifest: current)
            } catch {
                log("superset: \(spec.method) \(spec.path) — connection failed\(retried ? "" : ", re-reading manifest")")
                if !retried { retried = true; forgetManifest(); continue }
                linkState = .unreachable(reason: "connection failed")
                throw SupersetClientError.unreachable
            }

            if status == 401 {
                log("superset: \(spec.method) \(spec.path) → 401\(retried ? "" : ", re-reading manifest")")
                if !retried { retried = true; forgetManifest(); continue }
                linkState = .unreachable(reason: "unauthorized")
                throw SupersetClientError.unauthorized
            }
            guard (200..<300).contains(status) else {
                let code = Self.errorCode(body) ?? "unknown"
                log("superset: \(spec.method) \(spec.path) → \(status) \(code)")
                throw SupersetClientError.decoding("\(call.procedure.rawValue): HTTP \(status) \(code)")
            }
            guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let data = result["data"] as? [String: Any],
                  let payload = data["json"]
            else {
                log("superset: \(spec.method) \(spec.path) → \(status), unreadable reply")
                throw SupersetClientError.decoding("\(call.procedure.rawValue): unreadable reply")
            }
            return payload
        }
    }

    /// A new manifest may be a restarted host with another version: check again.
    private func forgetManifest() {
        manifest = nil
        version = nil
    }

    private func fail(_ error: SupersetClientError) -> SupersetClientError {
        if case let .decoding(detail) = error { log("superset: \(detail)") }
        return error
    }

    // MARK: - Encoding (pure)

    /// The request for a call: path, method, and the superjson-wrapped input.
    static func request(for call: SupersetCall) throws -> HTTPRequestSpec {
        let procedure = call.procedure
        let path = "/trpc/\(procedure.rawValue)"
        let input = Self.input(for: call)
        switch procedure.kind {
        case .query:
            guard let input else { return HTTPRequestSpec(method: "GET", path: path) }
            let text = String(decoding: try wrap(input), as: UTF8.self)
            return HTTPRequestSpec(method: "GET", path: path, query: [URLQueryItem(name: "input", value: text)])
        case .mutation:
            return HTTPRequestSpec(method: "POST", path: path, body: try wrap(input ?? [:]))
        }
    }

    /// zod inputs as SP read them from the host-service source (formas.md §2).
    static func input(for call: SupersetCall) -> [String: Any]? {
        switch call {
        case .healthCheck, .listWorkspaces, .listProjects:
            return nil
        case let .listAgents(workspaceID):
            return workspaceID.map { ["workspaceId": $0] }
        case let .snapshot(terminalID, workspaceID, maxLines):
            return ["terminalId": terminalID, "workspaceId": workspaceID, "maxLines": max(1, maxLines)]
        case let .transcript(terminalID, workspaceID, maxChars):
            // `.max(TERMINAL_HANDOFF_MAX_CHARS)` server-side (SP: 36 000).
            return ["terminalId": terminalID, "workspaceId": workspaceID,
                    "maxChars": min(max(1, maxChars), transcriptMaxChars)]
        case let .runAgent(workspaceID, agent, launch):
            // Never `continueTerminalId`: it carries no context (formas.md §4).
            let prompt: String = switch launch {
            case .bare: ""
            case let .prompt(text): text
            }
            return ["workspaceId": workspaceID, "agent": agent, "prompt": prompt]
        case let .writeInput(terminalID, workspaceID, data):
            return ["terminalId": terminalID, "workspaceId": workspaceID, "data": data.rawValue]
        case let .send(terminalID, workspaceID, text, submit):
            return ["terminalId": terminalID, "workspaceId": workspaceID, "text": text, "submit": submit]
        case let .clearStatuses(workspaceID, terminalID):
            return ["workspaceId": workspaceID, "terminalId": terminalID]
        }
    }

    /// `TERMINAL_HANDOFF_MAX_CHARS` in Superset 1.30.0.
    public static let transcriptMaxChars = 36_000

    private static func wrap(_ input: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: ["json": input], options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw SupersetClientError.decoding("could not encode input")
        }
    }

    // MARK: - Decoding (pure)

    /// One row of `terminalAgents.list`. Rows without the three ids are skipped; an
    /// unknown `lastEventType` reads as nil rather than a guess.
    static func binding(_ row: [String: Any]) -> AgentBinding? {
        guard let terminal = row["terminalId"] as? String,
              let workspace = row["workspaceId"] as? String,
              let agent = row["agentId"] as? String
        else { return nil }
        let type = (row["lastEventType"] as? String).flatMap(LifecycleType.init(rawValue:))
        let at = (row["lastEventAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return AgentBinding(terminalID: terminal, workspaceID: workspace, agent: agent,
                            lastEventType: type, lastEventAt: at)
    }

    /// `error.json.data.code` — `UNAUTHORIZED`, `INTERNAL_SERVER_ERROR`… Only the code:
    /// the message is free text from the server.
    static func errorCode(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let json = error["json"] as? [String: Any],
              let data = json["data"] as? [String: Any],
              let code = data["code"] as? String,
              code.allSatisfy({ $0.isUppercase || $0 == "_" })
        else { return nil }
        return code
    }
}
