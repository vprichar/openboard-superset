import Foundation

/**
 The pure parts of the app's `SupersetConnection`: URLs, the `/events` request, and
 the reconnect and keepalive timing. Here so they can be tested; the socket code in
 the app only follows what these return.
 */
public enum SupersetWire {
    // MARK: - URLs

    /// `endpoint` + `/trpc/<proc>` + the spec's query, with the superjson input
    /// percent-encoded — including `{}"&=/:?#+`, which `URLComponents` would leave
    /// alone or misread. Never carries the token: `/trpc` authenticates by header.
    public static func url(for request: HTTPRequestSpec, endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + request.path
        if !request.query.isEmpty {
            components.percentEncodedQuery = request.query.map { item in
                let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
                return "\(item.name)=\(value)"
            }.joined(separator: "&")
        }
        return components.url
    }

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/:{}\"")
        return set
    }()

    /// The `/events` request: same host and port, `ws`/`wss`. The token goes in
    /// `Authorization` unless `tokenInQuery`, the fallback, which puts it in `?token=`
    /// instead — that URL must never be logged.
    public static func eventsRequest(endpoint: URL, token: SecretToken, tokenInQuery: Bool) -> URLRequest? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/events"
        components.query = nil
        if tokenInQuery {
            components.queryItems = [token.withRaw { URLQueryItem(name: "token", value: $0) }]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        if !tokenInQuery {
            token.withRaw { request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }

    // MARK: - Reconnect

    /// Delay after `failures` consecutive failed connections: 1, 2, 4, 8, then 10 s.
    public static func backoff(afterFailures failures: Int) -> TimeInterval {
        min(10, pow(2, Double(max(0, failures - 1))))
    }

    /**
     What to do when an `/events` connection ends.

     A connection that delivered anything resets the backoff: a Superset restart then
     costs about a second. A handshake refused with 401/403 under the header retries
     at once with `?token=`, once; refused again, it goes back to the header and waits
     — a restarted host has a new token, which the next manifest read picks up.
     */
    public struct Reconnect: Equatable, Sendable {
        public enum Step: Equatable, Sendable {
            case retryNow
            case wait(seconds: TimeInterval)
        }

        public private(set) var failures = 0
        /// Whether the next connection should put the token in the query.
        public private(set) var tokenInQuery = false

        public init() {}

        /// `received` = messages on the connection that just ended; `handshakeStatus` =
        /// the HTTP status of the upgrade response, if any.
        public mutating func ended(received: Int, handshakeStatus: Int?) -> Step {
            if received > 0 { failures = 0 }
            let refused = received == 0 && (handshakeStatus == 401 || handshakeStatus == 403)
            if refused, !tokenInQuery {
                tokenInQuery = true
                return .retryNow
            }
            tokenInQuery = false
            failures += 1
            return .wait(seconds: SupersetWire.backoff(afterFailures: failures))
        }
    }

    // MARK: - Keepalive

    /**
     Ping timing for one connection. A socket that dies without a close frame — the
     laptop slept, the host was killed — otherwise looks open forever.

     `tick` says `.ping` every `interval` (one ping in flight at a time) and
     `.timedOut` when a pong has not come back within `timeout`. Timed out is final
     for the connection: the caller closes it and reconnects on the backoff, with a
     fresh `Keepalive`.
     */
    public struct Keepalive: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case none, ping, timedOut }

        public let interval: TimeInterval
        public let timeout: TimeInterval
        private var lastPing: Date
        private var awaitingSince: Date?
        private var dead = false

        /// 20 s / 10 s by default. `now` is when the connection opened.
        public init(interval: TimeInterval = 20, timeout: TimeInterval = 10, now: Date) {
            self.interval = interval
            self.timeout = timeout
            self.lastPing = now
        }

        public mutating func tick(now: Date) -> Action {
            if dead { return .timedOut }
            if let sent = awaitingSince {
                if now.timeIntervalSince(sent) >= timeout {
                    dead = true
                    return .timedOut
                }
                return .none
            }
            guard now.timeIntervalSince(lastPing) >= interval else { return .none }
            lastPing = now
            awaitingSince = now
            return .ping
        }

        public mutating func pong(now: Date) {
            guard !dead else { return }
            awaitingSince = nil
        }
    }
}
