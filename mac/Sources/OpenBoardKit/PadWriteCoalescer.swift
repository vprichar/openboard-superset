import Foundation

/**
 At most one pad write per `interval`, and never the same bytes twice in a row.

 The first write after a quiet spell goes out at once — no added latency on a single
 key change. Writes offered inside the window replace one another; `drain` sends the
 last of them once the window is over. A payload equal to what the pad already shows
 is dropped, and it also drops anything held, since that would only put the pad back
 where it is.
 */
public struct PadWriteCoalescer {
    private let interval: TimeInterval
    private var lastSent: Data?
    private var lastSentAt: Date?
    private var held: Data?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// What to write now; nil means held or duplicate.
    public mutating func offer(_ payload: Data, now: Date) -> Data? {
        if payload == lastSent {
            held = nil
            return nil
        }
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < interval {
            held = payload
            return nil
        }
        return send(payload, now: now)
    }

    /// The held write, once its window is over.
    public mutating func drain(now: Date) -> Data? {
        guard let payload = held else { return nil }
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < interval { return nil }
        held = nil
        guard payload != lastSent else { return nil }
        return send(payload, now: now)
    }

    private mutating func send(_ payload: Data, now: Date) -> Data {
        lastSent = payload
        lastSentAt = now
        return payload
    }
}
