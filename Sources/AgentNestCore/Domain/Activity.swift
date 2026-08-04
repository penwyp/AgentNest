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

public struct ProcessStartIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public enum ProcessAttribution: String, Codable, Sendable {
    case agent
    case other
}

public enum ProcessFileEvidenceKind: String, Codable, Sendable {
    case currentlyOpen
    case recentChange
}

public struct ProcessFileEvidence: Codable, Equatable, Sendable {
    public let kind: ProcessFileEvidenceKind
    public let path: String
    public let observedAt: Date

    public init(kind: ProcessFileEvidenceKind, path: String, observedAt: Date) {
        self.kind = kind
        self.path = path
        self.observedAt = observedAt
    }
}

public struct VisibleProcessActivity: Identifiable, Codable, Equatable, Sendable {
    public let id: ProcessStartIdentity
    public let name: String
    public let executablePath: String?
    public let workingDirectoryPath: String?
    public let attribution: ProcessAttribution
    public let productID: String?
    public let homeID: PhysicalResourceIdentity?
    public let evidence: [String]
    public let cpuFraction: MetricValue
    public let requestedReadBytesPerSecond: MetricValue
    public let requestedWriteBytesPerSecond: MetricValue
    public let currentlyOpenFiles: [ProcessFileEvidence]
    public let recentChanges: [ProcessFileEvidence]

    public init(
        id: ProcessStartIdentity,
        name: String,
        executablePath: String?,
        workingDirectoryPath: String? = nil,
        attribution: ProcessAttribution,
        productID: String?,
        homeID: PhysicalResourceIdentity?,
        evidence: [String],
        cpuFraction: MetricValue,
        requestedReadBytesPerSecond: MetricValue,
        requestedWriteBytesPerSecond: MetricValue,
        currentlyOpenFiles: [ProcessFileEvidence] = [],
        recentChanges: [ProcessFileEvidence] = []
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.workingDirectoryPath = workingDirectoryPath
        self.attribution = attribution
        self.productID = productID
        self.homeID = homeID
        self.evidence = evidence
        self.cpuFraction = cpuFraction
        self.requestedReadBytesPerSecond = requestedReadBytesPerSecond
        self.requestedWriteBytesPerSecond = requestedWriteBytesPerSecond
        self.currentlyOpenFiles = currentlyOpenFiles
        self.recentChanges = recentChanges
    }
}

public struct PhysicalDeviceActivity: Identifiable, Codable, Equatable, Sendable {
    public let id: UInt64
    public let name: String
    public let bsdName: String?
    public let readBytesPerSecond: MetricValue
    public let writeBytesPerSecond: MetricValue

    public init(id: UInt64, name: String, bsdName: String?, readBytesPerSecond: MetricValue, writeBytesPerSecond: MetricValue) {
        self.id = id
        self.name = name
        self.bsdName = bsdName
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct VolumeIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let uuid: String?

    public init(device: UInt64, uuid: String?) {
        self.device = device
        self.uuid = uuid
    }
}

public enum DeviceHealthState: String, Codable, Sendable {
    case verified
    case failing
    case unsupported
    case unavailable
    case disconnected
    case stale
}

public struct MountedVolume: Identifiable, Codable, Equatable, Sendable {
    public let id: VolumeIdentity
    public let name: String
    public let mountPath: String
    public let totalBytes: UInt64?
    public let availableBytes: UInt64?
    public let isLocal: Bool?
    public let isWritable: Bool?
    public let isRemovable: Bool?
    public let physicalDeviceIDs: [UInt64]
    public let health: DeviceHealthState

    public init(
        id: VolumeIdentity,
        name: String,
        mountPath: String,
        totalBytes: UInt64?,
        availableBytes: UInt64?,
        isLocal: Bool?,
        isWritable: Bool?,
        isRemovable: Bool?,
        physicalDeviceIDs: [UInt64],
        health: DeviceHealthState
    ) {
        self.id = id
        self.name = name
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isLocal = isLocal
        self.isWritable = isWritable
        self.isRemovable = isRemovable
        self.physicalDeviceIDs = physicalDeviceIDs
        self.health = health
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
    public let processes: [VisibleProcessActivity]
    public let physicalDevices: [PhysicalDeviceActivity]
    public let volumes: [MountedVolume]
    public let droppedEvidenceCount: Int

    public init(
        capturedAt: Date,
        cpuFraction: MetricValue,
        diskReadBytesPerSecond: MetricValue,
        diskWriteBytesPerSecond: MetricValue,
        networkReceiveBytesPerSecond: MetricValue,
        networkSendBytesPerSecond: MetricValue,
        didResetBaseline: Bool,
        processes: [VisibleProcessActivity] = [],
        physicalDevices: [PhysicalDeviceActivity] = [],
        volumes: [MountedVolume] = [],
        droppedEvidenceCount: Int = 0
    ) {
        self.capturedAt = capturedAt
        self.cpuFraction = cpuFraction
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceiveBytesPerSecond = networkReceiveBytesPerSecond
        self.networkSendBytesPerSecond = networkSendBytesPerSecond
        self.didResetBaseline = didResetBaseline
        self.processes = processes
        self.physicalDevices = physicalDevices
        self.volumes = volumes
        self.droppedEvidenceCount = droppedEvidenceCount
    }
}
