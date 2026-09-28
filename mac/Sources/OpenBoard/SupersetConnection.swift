import Foundation
import OpenBoardKit

/**
 The sockets behind the host-service client: `URLSession` for `/trpc`, and a
 `URLSessionWebSocketTask` for `/events`.

 Everything that decides anything lives in OpenBoardKit — encoding, the allowlist,
 the version gate, the one retry (`SupersetHostClient`), decoding (`SupersetBus`), URLs,
 reconnect and keepalive timing (`SupersetWire`). This
 file only moves bytes, so it holds no policy worth testing and the Kit tests cover
 what it carries.

 Three rules it keeps on its own:

 - **The token travels in a header.** `/trpc` accepts nothing else (SP formas.md §1).
   `/events` accepts the header too and gets it first; `?token=` is used only after the
   header was refused, and that URL is never logged.
 - **Nothing sensitive is logged.** Lines name the path (`/events`) and the error code,
   never the endpoint or the token. `Log.write` redacts registered secrets as well,
   and every manifest read here registers its token before anything else happens.
 - **The manifest is re-read on every (re)connection.** Superset rewrites it with a new
   port on each start, so a cached endpoint goes stale exactly when it matters.

 Not wired into `BoardController` here; the integrator does that (I-2).
 */
final class SupersetConnection: SupersetTransport, @unchecked Sendable {
    /// Short: the host-service is local, and a hung call would hold a key press.
    static let requestTimeout: TimeInterval = 5

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]  // 127.0.0.1 only; never through a proxy
        session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - Manifest

    /**
     The loader to hand `SupersetHostClient`: resolves the manifest fresh each time and
     registers its token with the log redactor before returning it.
     */
    static func manifestLoader(orgID: String?, root: URL = SupersetFocus.defaultRoot)
        -> SupersetHostClient.ManifestLoader
    {
        { try loadManifest(orgID: orgID, root: root) }
    }

    static func loadManifest(orgID: String?, root: URL = SupersetFocus.defaultRoot) throws -> SupersetManifest {
        let manifest = try SupersetManifestLocator.resolve(root: root, orgID: orgID)
        Log.registerSecret(manifest.token)
        return manifest
    }

    /// A client over this transport, configured from preferences.
    static func makeClient(_ prefs: Preferences.Superset, transport: SupersetConnection) -> SupersetHostClient {
        SupersetHostClient(
            manifest: manifestLoader(orgID: prefs.orgID),
            transport: transport,
            testedVersion: prefs.testedVersion,
            onMismatch: prefs.onVersionMismatch,
            hostClient: prefs.hostClient
        )
    }

    // MARK: - SupersetTransport

    func send(_ request: HTTPRequestSpec, manifest: SupersetManifest) async throws -> (status: Int, body: Data) {
        guard let url = SupersetWire.url(for: request, endpoint: manifest.endpoint) else {
            throw URLError(.badURL)
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if request.bearer {
            manifest.token.withRaw { urlRequest.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization") }
        }
        // Errors propagate as URLError; the client logs method + path, never the URL.
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }

    // MARK: - /events

    func events(
        orgID: String?,
        root: URL = SupersetFocus.defaultRoot,
        onMessage: @escaping @Sendable (SupersetBus.Message) -> Void
    ) -> SupersetEventStream {
        SupersetEventStream(
            session: session,
            loadManifest: Self.manifestLoader(orgID: orgID, root: root),
            onMessage: onMessage
        )
    }
}

/**
 One long-lived `/events` subscription that keeps itself alive.

 `start()` runs a loop: read the manifest, connect, receive until the socket drops,
 then do what `SupersetWire.Reconnect` says — retry at once with `?token=` after a
 refused handshake, otherwise wait out the backoff — until `stop()`.

 While open, `SupersetWire.Keepalive` pings every 20 s; with no pong in 10 s the socket
 is cancelled, which fails the pending `receive` and so goes through the same
 reconnect path as any other drop.
 */
actor SupersetEventStream {
    enum Status: Equatable, Sendable { case stopped, connecting, open, waiting(seconds: Int) }

    /// How often the keepalive is consulted. Its own timing is 20 s / 10 s.
    static let keepaliveTick: TimeInterval = 1

    private let session: URLSession
    private let loadManifest: SupersetHostClient.ManifestLoader
    private let onMessage: @Sendable (SupersetBus.Message) -> Void

    private var loop: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var keepalive: SupersetWire.Keepalive?
    private(set) var status: Status = .stopped

    init(
        session: URLSession,
        loadManifest: @escaping SupersetHostClient.ManifestLoader,
        onMessage: @escaping @Sendable (SupersetBus.Message) -> Void
    ) {
        self.session = session
        self.loadManifest = loadManifest
        self.onMessage = onMessage
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        keepalive = nil
        status = .stopped
    }

    private func run() async {
        var reconnect = SupersetWire.Reconnect()
        while !Task.isCancelled {
            status = .connecting
            var received = 0
            var handshake: Int?
            do {
                let manifest = try loadManifest()
                (received, handshake) = await connect(manifest, tokenInQuery: reconnect.tokenInQuery)
            } catch {
                Log.write("superset: /events — no manifest")
            }
            if Task.isCancelled { break }

            switch reconnect.ended(received: received, handshakeStatus: handshake) {
            case .retryNow:
                continue
            case let .wait(seconds):
                status = .waiting(seconds: Int(seconds))
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
        status = .stopped
    }

    /// Connects and receives until the socket fails. Returns how many messages
    /// arrived and the handshake's HTTP status, if the upgrade got one.
    private func connect(_ manifest: SupersetManifest, tokenInQuery: Bool) async -> (received: Int, handshake: Int?) {
        guard let request = SupersetWire.eventsRequest(
            endpoint: manifest.endpoint, token: manifest.token, tokenInQuery: tokenInQuery)
        else {
            Log.write("superset: /events — bad endpoint in manifest")
            return (0, nil)
        }
        let socket = session.webSocketTask(with: request)
        task = socket
        keepalive = SupersetWire.Keepalive(now: Date())
        socket.resume()
        Log.write("superset: /events connecting\(tokenInQuery ? " (query token)" : "")")

        let pinger = Task { await self.keepAlive(socket) }
        defer {
            pinger.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            if task === socket { task = nil; keepalive = nil }
        }

        var received = 0
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                if received == 0 {
                    status = .open
                    Log.write("superset: /events open")
                }
                received += 1
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                if let decoded = SupersetBus.decode(data, now: Date()) { onMessage(decoded) }
            } catch {
                let http = (socket.response as? HTTPURLResponse)?.statusCode
                // Code only: an NSError's description can include the failing URL.
                let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
                Log.write("superset: /events closed after \(received) messages (\(http.map { "HTTP \($0)" } ?? "error \(code)"))")
                return (received, http)
            }
        }
        return (received, nil)
    }

    /// Runs beside `receive` for one socket; cancels it when a pong is overdue.
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled, task === socket {
            try? await Task.sleep(nanoseconds: UInt64(Self.keepaliveTick * 1_000_000_000))
            guard !Task.isCancelled, task === socket, var k = keepalive else { return }
            let action = k.tick(now: Date())
            keepalive = k
            switch action {
            case .none:
                continue
            case .ping:
                socket.sendPing { [weak self] error in
                    guard error == nil, let self else { return }
                    Task { await self.pong(for: socket) }
                }
            case .timedOut:
                Log.write("superset: /events no pong in \(Int(k.timeout)) s — reconnecting")
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func pong(for socket: URLSessionWebSocketTask) {
        guard task === socket else { return }
        keepalive?.pong(now: Date())
    }
}
