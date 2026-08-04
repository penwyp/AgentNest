import Foundation

public struct LicenseRefreshSchedule: Sendable {
    public private(set) var failureCount: Int
    public private(set) var nextAttemptAt: Date?

    public init(failureCount: Int = 0, nextAttemptAt: Date? = nil) {
        self.failureCount = failureCount
        self.nextAttemptAt = nextAttemptAt
    }

    public func shouldAttempt(now: Date) -> Bool {
        nextAttemptAt.map { now >= $0 } ?? true
    }

    public mutating func recordSuccess(refreshAfter: Date) {
        failureCount = 0
        nextAttemptAt = refreshAfter
    }

    public mutating func recordFailure(now: Date, jitterUnit: Double) {
        failureCount = min(failureCount + 1, 16)
        let exponent = min(failureCount - 1, 8)
        let base = min(60.0 * pow(2, Double(exponent)), 21_600)
        let boundedJitter = min(max(jitterUnit, 0), 1)
        let delay = base * (0.75 + 0.5 * boundedJitter)
        nextAttemptAt = now.addingTimeInterval(delay)
    }

    public mutating func networkBecameAvailable(now: Date) {
        guard failureCount > 0 else { return }
        nextAttemptAt = now
    }
}
