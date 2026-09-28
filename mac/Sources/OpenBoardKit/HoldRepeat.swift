import Foundation

/**
 The autorepeat a held key produces on its own — and a synthetic hold does not.

 ## Why a held key has to repeat

 A terminal never sees key-up. Claude Code's `hold` voice mode therefore reads
 "Space is held" from the *stream* a physical key produces while down: the press,
 then — after the repeat delay — one repeat per interval. Its thresholds (read from
 the 2.1.283 build):

 - **Start:** five spaces, each less than 120 ms after the last. Only autorepeat
   produces that rhythm; a single press resets the count after 120 ms.
 - **End:** 200 ms without a space. The release is the stream stopping, not key-up.

 A `CGEvent` keyDown posted once is one space, so push-to-talk from the pad started
 nothing. This is the schedule of repeats that makes it a held key again.

 ## Shape

 Offsets are seconds since the initial keyDown. Repeat *n* is due at
 `delay + n × interval`, strictly before `cap` (the hold's timeout — a repeat after
 the backstop's key-up would press the key again). `stop()` ends it for good, and the
 caller stops it *before* posting key-up. A late wake-up fires one repeat and skips
 the missed ones: a catch-up burst types spaces rather than extending a hold, and no
 real keyboard produces one.

 Pure and clock-free so every edge is a plain assertion; `PushToTalk` owns the timer.
 */
public struct HoldRepeat: Equatable, Sendable {
    /// macOS's factory `NSEvent.keyRepeatDelay` (`InitialKeyRepeat` unset).
    public static let defaultDelay: TimeInterval = 0.5
    /// macOS's factory `NSEvent.keyRepeatInterval` (`KeyRepeat` unset): 83 ms.
    public static let defaultInterval: TimeInterval = 1.0 / 12
    /// The slowest repeat that still reads as held: Claude Code resets its warm-up
    /// count after 120 ms without a space. A user whose own keyboard repeats slower
    /// still gets a pad key that works.
    public static let maxInterval: TimeInterval = 0.1
    /// The fastest repeat accepted, so a bad setting cannot flood the event stream.
    /// macOS's fastest `KeyRepeat` is 30 ms.
    public static let minInterval: TimeInterval = 0.015

    public let delay: TimeInterval
    public let interval: TimeInterval
    /// No repeat at or after this offset: the hold's timeout.
    public let cap: TimeInterval
    /// Repeats already due — fired or skipped.
    public private(set) var passed = 0
    public private(set) var isStopped = false

    public init(
        delay: TimeInterval = HoldRepeat.defaultDelay,
        interval: TimeInterval = HoldRepeat.defaultInterval,
        cap: TimeInterval
    ) {
        self.delay = max(0, delay)
        self.interval = min(max(interval, Self.minInterval), Self.maxInterval)
        self.cap = cap
    }

    /// When repeat `n` (0-based) is due, in seconds after the initial keyDown.
    public func offset(ofRepeat n: Int) -> TimeInterval {
        delay + Double(n) * interval
    }

    /// When the next repeat is due, or `nil` if none will be.
    public var nextDue: TimeInterval? {
        guard !isStopped else { return nil }
        let due = offset(ofRepeat: passed)
        return due < cap ? due : nil
    }

    /// Whether a repeat should be posted now, `elapsed` seconds into the hold. Marks
    /// every repeat due by then as passed, so a late wake-up fires once.
    public mutating func fire(at elapsed: TimeInterval) -> Bool {
        guard let due = nextDue, elapsed >= due, elapsed < cap else { return false }
        // At least one past the repeat just due: rounding at an exact multiple must
        // never leave it due again.
        let dueByNow = Int(((elapsed - delay) / interval).rounded(.down)) + 1
        passed = max(passed + 1, dueByNow)
        return true
    }

    /// The hold ended. Nothing fires after this.
    public mutating func stop() {
        isStopped = true
    }
}
