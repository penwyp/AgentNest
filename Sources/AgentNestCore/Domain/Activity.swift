import Foundation

public enum MetricAvailability: String, Codable, Sendable {
    case available
    case partial
    case unavailable
}

public struct MetricValue: Codable, Equatable, Sendable {
    public let value: Double?
    public let availability: MetricAvailability
    public let observedSeconds: TimeInterval
    public let coverage: Double

    public init(value: Double?, availability: MetricAvailability, observedSeconds: TimeInterval, coverage: Double) {
        self.value = value
        self.availability = availability
        self.observedSeconds = observedSeconds
        self.coverage = coverage
    }
}

public struct CumulativeActivityCounters: Equatable, Sendable {
    public let userCPUTicks: UInt64
    public let systemCPUTicks: UInt64
    public let idleCPUTicks: UInt64
    public let diskReadBytes: UInt64?
    public let diskWriteBytes: UInt64?
    public let networkReceiveBytes: UInt64?
    public let networkSendBytes: UInt64?

    public init(
        userCPUTicks: UInt64,
        systemCPUTicks: UInt64,
        idleCPUTicks: UInt64,
        diskReadBytes: UInt64?,
        diskWriteBytes: UInt64?,
        networkReceiveBytes: UInt64?,
        networkSendBytes: UInt64?
    ) {
        self.userCPUTicks = userCPUTicks
        self.systemCPUTicks = systemCPUTicks
        self.idleCPUTicks = idleCPUTicks
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
    }
}

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let cpuFraction: MetricValue
    public let diskReadBytesPerSecond: MetricValue
    public let diskWriteBytesPerSecond: MetricValue
    public let networkReceiveBytesPerSecond: MetricValue
    public let networkSendBytesPerSecond: MetricValue
    public let didResetBaseline: Bool

    public init(
        capturedAt: Date,
        cpuFraction: MetricValue,
        diskReadBytesPerSecond: MetricValue,
        diskWriteBytesPerSecond: MetricValue,
        networkReceiveBytesPerSecond: MetricValue,
        networkSendBytesPerSecond: MetricValue,
        didResetBaseline: Bool
    ) {
        self.capturedAt = capturedAt
        self.cpuFraction = cpuFraction
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceiveBytesPerSecond = networkReceiveBytesPerSecond
        self.networkSendBytesPerSecond = networkSendBytesPerSecond
        self.didResetBaseline = didResetBaseline
    }
}
