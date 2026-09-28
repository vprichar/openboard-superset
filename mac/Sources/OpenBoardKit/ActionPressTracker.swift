import Foundation

/**
 Tells a tap from a hold on the action caps (F2).

 Time is injected, so it is tested without a stopwatch. The rules:
 - a cap with no long binding taps on the way down, exactly as before — APPR and REJ
   must not get slower because holding *some* cap now means something;
 - a cap with one taps on release if it was short, or holds once when the threshold
   passes (`poll`) — never both;
 - a release with no press, or after the hold, is nothing.

 The encoder keeps its own `EncoderClick`; this is for the caps only.
 */
public struct ActionPressTracker {
    public enum Emit: Equatable, Sendable { case tap(String), hold(String) }

    public var threshold: TimeInterval

    private struct Press {
        var at: Date
        var held: Bool
    }
    private var pressed: [String: Press] = [:]

    public init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    /// With the threshold from `actionLongPressMs`.
    public init(prefs: Preferences) {
        self.init(threshold: Double(prefs.actionLongPressMs) / 1000)
    }

    public mutating func press(_ key: String, hasLongBinding: Bool, now: Date) -> Emit? {
        guard hasLongBinding else {
            // Nothing to wait for. Forget any stale timing so its release stays silent.
            pressed[key] = nil
            return .tap(key)
        }
        pressed[key] = Press(at: now, held: false)
        return nil
    }

    /// The hold of the earliest pressed cap that crossed the threshold, once. Call
    /// again until nil when several caps are down.
    public mutating func poll(now: Date) -> Emit? {
        let due = pressed
            .filter { !$0.value.held && now.timeIntervalSince($0.value.at) >= threshold }
            .min { $0.value.at < $1.value.at }
        guard let (key, _) = due else { return nil }
        pressed[key]?.held = true
        return .hold(key)
    }

    public mutating func release(_ key: String, now: Date) -> Emit? {
        guard let press = pressed.removeValue(forKey: key) else { return nil }
        if press.held { return nil }
        // A poll that ran late must not turn a long press into a short one.
        return now.timeIntervalSince(press.at) >= threshold ? .hold(key) : .tap(key)
    }

    /// Forget every press in flight — used when bindings change.
    public mutating func reset() { pressed.removeAll() }
}
