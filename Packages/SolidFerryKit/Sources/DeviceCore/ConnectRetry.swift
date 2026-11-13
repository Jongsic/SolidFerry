import Foundation

/// Backing off between failed connection attempts to one phone. Spans attempts, so it lives
/// beside a session's connection state rather than in it.
public struct ConnectRetry {
    public init() {}

    public private(set) var failures = 0
    /// No new attempt before this (nil: try now; distantFuture: wait for the phone to change).
    public private(set) var gate: Date?

    /// What the last attempt failed with, kept while the next one runs (so its message doesn't
    /// flicker away during a retry).
    public private(set) var lastError: (any Error)?

    /// When the next attempt is due, for the waiting screens.
    public var retryAt: Date? { gate == .distantFuture ? nil : gate }

    public func allowsAttempt(at now: Date = Date()) -> Bool {
        gate.map { now >= $0 } ?? true
    }

    /// Counts a failure. Returns how long to wait, or nil to wait for the phone to change.
    public mutating func failed(_ error: any Error, waitForChange: Bool, now: Date = Date()) -> TimeInterval? {
        failures += 1
        lastError = error
        guard !waitForChange else {
            gate = .distantFuture
            return nil
        }
        let delay = Self.delay(afterFailures: failures)
        gate = now.addingTimeInterval(delay)
        return delay
    }

    /// The wait is over.
    public mutating func open() { gate = nil }

    /// 3 s, 6 s, 12 s, 24 s, then every 30 s.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        min(3 * pow(2, Double(max(failures, 1) - 1)), 30)
    }
}
