import Foundation

public struct TimedActivityCounters: Sendable {
    public let monotonicTime: TimeInterval
    public let wallTime: Date
    public let counters: CumulativeActivityCounters

    public init(monotonicTime: TimeInterval, wallTime: Date, counters: CumulativeActivityCounters) {
        self.monotonicTime = monotonicTime
        self.wallTime = wallTime
        self.counters = counters
    }
}

public struct ActivityRateCalculator: Sendable {
    private var previous: TimedActivityCounters?
    private let maximumComparableInterval: TimeInterval

    public init(maximumComparableInterval: TimeInterval = 120) {
        self.maximumComparableInterval = maximumComparableInterval
    }

    public mutating func record(_ sample: TimedActivityCounters) -> ActivitySnapshot {
        guard let previous else {
            self.previous = sample
            return baseline(at: sample.wallTime, reset: true)
        }
        let interval = sample.monotonicTime - previous.monotonicTime
        guard interval > 0, interval <= maximumComparableInterval,
              sample.counters.userCPUTicks >= previous.counters.userCPUTicks,
              sample.counters.systemCPUTicks >= previous.counters.systemCPUTicks,
              sample.counters.idleCPUTicks >= previous.counters.idleCPUTicks else {
            self.previous = sample
            return baseline(at: sample.wallTime, reset: true)
        }

        let userDelta = sample.counters.userCPUTicks - previous.counters.userCPUTicks
        let systemDelta = sample.counters.systemCPUTicks - previous.counters.systemCPUTicks
        let idleDelta = sample.counters.idleCPUTicks - previous.counters.idleCPUTicks
        let totalTicks = userDelta &+ systemDelta &+ idleDelta
        let cpu = totalTicks == 0 ? 0 : Double(userDelta &+ systemDelta) / Double(totalTicks)
        let snapshot = ActivitySnapshot(
            capturedAt: sample.wallTime,
            cpuFraction: MetricValue(value: cpu, availability: .available, observedSeconds: interval, coverage: 1),
            diskReadBytesPerSecond: rate(current: sample.counters.diskReadBytes, previous: previous.counters.diskReadBytes, interval: interval),
            diskWriteBytesPerSecond: rate(current: sample.counters.diskWriteBytes, previous: previous.counters.diskWriteBytes, interval: interval),
            networkReceiveBytesPerSecond: rate(current: sample.counters.networkReceiveBytes, previous: previous.counters.networkReceiveBytes, interval: interval),
            networkSendBytesPerSecond: rate(current: sample.counters.networkSendBytes, previous: previous.counters.networkSendBytes, interval: interval),
            didResetBaseline: false
        )
        self.previous = sample
        return snapshot
    }

    private func rate(current: UInt64?, previous: UInt64?, interval: TimeInterval) -> MetricValue {
        guard let current, let previous else {
            return MetricValue(value: nil, availability: .unavailable, observedSeconds: interval, coverage: 0)
        }
        guard current >= previous else {
            return MetricValue(value: nil, availability: .partial, observedSeconds: interval, coverage: 0)
        }
        return MetricValue(value: Double(current - previous) / interval, availability: .available, observedSeconds: interval, coverage: 1)
    }

    private func baseline(at date: Date, reset: Bool) -> ActivitySnapshot {
        let unavailable = MetricValue(value: nil, availability: .unavailable, observedSeconds: 0, coverage: 0)
        return ActivitySnapshot(
            capturedAt: date,
            cpuFraction: unavailable,
            diskReadBytesPerSecond: unavailable,
            diskWriteBytesPerSecond: unavailable,
            networkReceiveBytesPerSecond: unavailable,
            networkSendBytesPerSecond: unavailable,
            didResetBaseline: reset
        )
    }
}
