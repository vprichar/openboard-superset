import Foundation

/**
 The shapes every Superset package programs against, and nothing else.

 No behaviour lives here — the client, the bus and the policies are built elsewhere,
 in parallel, against these types. What this file does own is the *fences*: which
 host-service procedures exist at all, which two bytes may be written into a terminal,
 and a token type that cannot be printed. Each is enforced by the type system rather
 than by a check someone has to remember to call, because the check is exactly the
 thing that gets forgotten in the one code path that mattered.
 */

// MARK: - The allowlist

/**
 The closed list of host-service procedures (Plan §4).

 A name outside this enum cannot be constructed, so it cannot be sent. Everything
 destructive the host-service offers — deleting a workspace, pushing, killing a
 session — is absent by design, not by a runtime refusal.
 */
public enum SupersetProcedure: String, CaseIterable, Sendable {
    case healthCheck = "health.check"
    case terminalAgentsList = "terminalAgents.list"
    case terminalAgentsListByWorkspace = "terminalAgents.listByWorkspace"
    case workspaceList = "workspace.list"
    case projectList = "project.list"
    case terminalSnapshot = "terminal.snapshot"
    case terminalTranscript = "terminal.transcript"
    case agentsRun = "agents.run"
    case terminalWriteInput = "terminal.writeInput"
    case terminalSend = "terminal.send"
    case clearWorkspaceStatuses = "terminalAgents.clearWorkspaceStatuses"

    public enum Kind: Sendable { case query, mutation }

    /// tRPC's own split: a query is a GET, a mutation a POST.
    public var kind: Kind { writes ? .mutation : .query }

    /// Whether calling it changes anything in Superset. Read-only mode refuses these.
    public var writes: Bool {
        switch self {
        case .agentsRun, .terminalWriteInput, .terminalSend, .clearWorkspaceStatuses: true
        case .healthCheck, .terminalAgentsList, .terminalAgentsListByWorkspace,
             .workspaceList, .projectList, .terminalSnapshot, .terminalTranscript: false
        }
    }
}

public enum SupersetAllowlist {
    /// True only for a `SupersetProcedure` raw value, exactly — no trimming, no case
    /// folding. For tests and for the log, which sees names as strings.
    public static func permits(_ name: String) -> Bool {
        SupersetProcedure(rawValue: name) != nil
    }
}

/// The only bytes `terminal.writeInput` can carry. By type, not by convention: there is
/// no case to put a command in.
public enum ControlInput: String, CaseIterable, Sendable {
    case escape = "\u{1b}"
    case carriageReturn = "\r"
}

public enum AgentLaunch: Equatable, Sendable {
    /// `agents.run {prompt: ""}` — a fresh agent (F5).
    case bare
    /**
     `agents.run {prompt}` — the handoff (F8): the transcript, wrapped as Superset's
     CLI wraps it (`Handoff.prompt`). There is deliberately no `continueTerminalId`: SP
     showed it reuses the *same* agent and carries no context (formas.md §4).
     */
    case prompt(String)
}

/// One call the client may make, with its arguments. Each maps to exactly one
/// allowlisted procedure.
public enum SupersetCall: Equatable, Sendable {
    case healthCheck
    case listAgents(workspaceID: String?)
    case listWorkspaces
    case listProjects
    case snapshot(terminalID: String, workspaceID: String, maxLines: Int)
    case transcript(terminalID: String, workspaceID: String, maxChars: Int)
    case runAgent(workspaceID: String, agent: String, launch: AgentLaunch)
    case writeInput(terminalID: String, workspaceID: String, data: ControlInput)
    case send(terminalID: String, workspaceID: String, text: String, submit: Bool)
    case clearStatuses(workspaceID: String, terminalID: String)

    public var procedure: SupersetProcedure {
        switch self {
        case .healthCheck: .healthCheck
        case let .listAgents(workspaceID):
            workspaceID == nil ? .terminalAgentsList : .terminalAgentsListByWorkspace
        case .listWorkspaces: .workspaceList
        case .listProjects: .projectList
        case .snapshot: .terminalSnapshot
        case .transcript: .terminalTranscript
        case .runAgent: .agentsRun
        case .writeInput: .terminalWriteInput
        case .send: .terminalSend
        case .clearStatuses: .clearWorkspaceStatuses
        }
    }
}

// MARK: - The token

/**
 The host-service bearer token, in a type that will not print it.

 `description`, `debugDescription` and the mirror all say «redacted», so a token nested
 in a struct that gets logged whole — a manifest, an error, a request — still does not
 reach the log. The raw value is reachable only through `withRaw`, which makes every
 use a line you can grep for.
 */
public struct SecretToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let raw: String

    public init(_ raw: String) { self.raw = raw }

    /// The only way in.
    public func withRaw<T>(_ body: (String) throws -> T) rethrows -> T { try body(raw) }

    public var description: String { "«redacted»" }
    public var debugDescription: String { "«redacted»" }
    /// Without this `dump` walks the stored property and prints it.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What `~/.superset/host/<org>/manifest.json` says, read into memory per connection
/// and never written anywhere (Plan §4).
public struct SupersetManifest: Sendable {
    public let endpoint: URL
    public let organizationID: String
    public let token: SecretToken

    public init(endpoint: URL, organizationID: String, token: SecretToken) {
        self.endpoint = endpoint
        self.organizationID = organizationID
        self.token = token
    }
}

// MARK: - Transport

/// A request as data, so the client's encoding is testable without a socket. It never
/// carries the token: `bearer` asks the transport to add `Authorization` itself.
public struct HTTPRequestSpec: Equatable, Sendable {
    /// `GET` or `POST`.
    public var method: String
    /// `/trpc/<procedure>`.
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var bearer: Bool

    public init(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, bearer: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.bearer = bearer
    }
}

public protocol SupersetTransport: Sendable {
    func send(_ request: HTTPRequestSpec, manifest: SupersetManifest) async throws -> (status: Int, body: Data)
}

// MARK: - Agents and their lifecycle

/// Superset's lifecycle event names, as its bus spells them.
public enum LifecycleType: String, Sendable, Codable {
    case start = "Start"
    case stop = "Stop"
    case permissionRequest = "PermissionRequest"
    case failed = "Failed"
    case attached = "Attached"
    case detached = "Detached"
}

/// Which agent runs in which terminal, as `terminalAgents.list` reports it.
public struct AgentBinding: Equatable, Sendable {
    public var terminalID: String
    public var workspaceID: String
    /// `claude`, `codex`, …
    public var agent: String
    public var lastEventType: LifecycleType?
    public var lastEventAt: Date?

    public init(
        terminalID: String,
        workspaceID: String,
        agent: String,
        lastEventType: LifecycleType? = nil,
        lastEventAt: Date? = nil
    ) {
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.agent = agent
        self.lastEventType = lastEventType
        self.lastEventAt = lastEventAt
    }
}

/// No `preview`: the terminal text the bus sends along is dropped at decode time, so it
/// is never stored and never logged.
public struct LifecycleEvent: Equatable, Sendable {
    public var type: LifecycleType
    public var terminalID: String
    public var workspaceID: String
    public var agent: String
    public var at: Date

    public init(type: LifecycleType, terminalID: String, workspaceID: String, agent: String, at: Date) {
        self.type = type
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.agent = agent
        self.at = at
    }
}

// MARK: - The client

/// What the settings window shows about the connection.
public enum SupersetLinkState: Equatable, Sendable {
    case off
    case searching
    case connected(version: String, readOnly: Bool)
    case versionMismatch(found: String, tested: String)
    /// Neither the URL nor the token ever goes in `reason`.
    case unreachable(reason: String)
}

public protocol SupersetHostAPI: Sendable {
    var state: SupersetLinkState { get async }
    /// The version `health.check` reports.
    func health() async throws -> String
    func agents(workspaceID: String?) async throws -> [AgentBinding]
    func snapshot(terminalID: String, workspaceID: String, maxLines: Int) async throws -> String
    /// `terminal.transcript` — the terminal's recent output, for the handoff (F8).
    func transcript(terminalID: String, workspaceID: String, maxChars: Int) async throws -> String
    /// Throws `.readOnly` for a writing call while in read-only mode.
    func perform(_ call: SupersetCall) async throws
}

public enum SupersetClientError: Error, Equatable {
    case readOnly(SupersetProcedure)
    case versionMismatch(found: String, tested: String)
    case unauthorized
    case unreachable
    case decoding(String)
    case disabled
}
