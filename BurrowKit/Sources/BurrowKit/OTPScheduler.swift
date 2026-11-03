import Foundation

/// Picks the code to send for a credentials request. It never reuses a time step that was already
/// sent (servers reject a replayed code), and it waits for the next step when the current one is about
/// to expire, so the code does not go stale on the way to the server.
public struct OTPScheduler: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case send(code: String, counter: UInt64)
        case wait(TimeInterval)
    }

    public var lastUsedCounter: UInt64?
    public var minimumRemaining: TimeInterval

    public init(lastUsedCounter: UInt64? = nil, minimumRemaining: TimeInterval = 3) {
        self.lastUsedCounter = lastUsedCounter
        self.minimumRemaining = minimumRemaining
    }

    public func decide(_ totp: TOTP, now: Date) -> Decision {
        let period = TimeInterval(totp.period)
        let seconds = now.timeIntervalSince1970
        let counter = totp.counter(at: now)
        // A last-used step far ahead means the clock was set back; don't wait for it.
        if let last = lastUsedCounter, counter <= last, last - counter <= 1 {
            return .wait(TimeInterval(last + 1) * period - seconds + 0.25)
        }
        let untilNext = TimeInterval(counter + 1) * period - seconds
        if untilNext < minimumRemaining {
            return .wait(untilNext + 0.25)
        }
        return .send(code: totp.code(counter: counter), counter: counter)
    }

    public mutating func markUsed(_ counter: UInt64) {
        lastUsedCounter = max(lastUsedCounter ?? 0, counter)
    }
}
