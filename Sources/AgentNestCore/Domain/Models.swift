import Foundation

public enum ScanPhase: String, Codable, CaseIterable, Sendable {
    case discoveringAgents
    case validatingHomes
    case indexingSkills
    case measuringSpace
    case generatingFindings
    case reconciling

    public var localizationKey: String {
        switch self {
        case .discoveringAgents: "scan.phase.discoveringAgents"
        case .validatingHomes: "scan.phase.validatingHomes"
        case .indexingSkills: "scan.phase.indexingSkills"
        case .measuringSpace: "scan.phase.measuringSpace"
        case .generatingFindings: "scan.phase.generatingFindings"
        case .reconciling: "scan.phase.reconciling"
        }
    }
}

public struct ScanProgress: Equatable, Sendable {
    public let generation: UUID
    public let phase: ScanPhase
    public let currentLocation: String?
    public let discoveredCount: Int
    public let processedCount: Int
    public let processedBytes: UInt64

    public init(
        generation: UUID,
        phase: ScanPhase,
        currentLocation: String? = nil,
        discoveredCount: Int = 0,
        processedCount: Int = 0,
        processedBytes: UInt64 = 0
    ) {
        self.generation = generation
        self.phase = phase
        self.currentLocation = currentLocation
        self.discoveredCount = discoveredCount
        self.processedCount = processedCount
        self.processedBytes = processedBytes
    }
}

public enum DiscoverySource: String, Codable, Sendable {
    case defaultPath
    case environment
    case custom
    case deepScan
    case userConfirmed
}

public enum AgentHomeConfidence: String, Codable, Sendable {
    case confirmed
    case possible
}

public enum ResourceKind: String, Codable, Sendable {
    case file
    case directory
    case other
}

public struct PhysicalResourceIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: ResourceKind

    public init(device: UInt64, inode: UInt64, kind: ResourceKind) {
        self.device = device
        self.inode = inode
        self.kind = kind
    }
}

public struct StorageMeasurement: Codable, Equatable, Sendable {
    public let logicalBytes: UInt64
    public let physicalBytes: UInt64
    public let itemCount: Int

    public init(logicalBytes: UInt64 = 0, physicalBytes: UInt64 = 0, itemCount: Int = 0) {
        self.logicalBytes = logicalBytes
        self.physicalBytes = physicalBytes
        self.itemCount = itemCount
    }
}

public struct AgentHome: Identifiable, Codable, Equatable, Sendable {
    public let id: PhysicalResourceIdentity
    public let productID: String
    public let displayName: String
    public let path: String
    public let source: DiscoverySource
    public let confidence: AgentHomeConfidence
    public let evidence: [String]
    public let storage: StorageMeasurement

    public init(
        id: PhysicalResourceIdentity,
        productID: String,
        displayName: String,
        path: String,
        source: DiscoverySource,
        confidence: AgentHomeConfidence,
        evidence: [String],
        storage: StorageMeasurement
    ) {
        self.id = id
        self.productID = productID
        self.displayName = displayName
        self.path = path
        self.source = source
        self.confidence = confidence
        self.evidence = evidence
        self.storage = storage
    }
}

public enum CoverageState: String, Codable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct SnapshotCoverage: Codable, Equatable, Sendable {
    public let directories: CoverageState
    public let agents: CoverageState
    public let space: CoverageState
    public let skills: CoverageState
    public let activity: CoverageState
    public let unreadableLocationCount: Int

    public init(
        directories: CoverageState,
        agents: CoverageState,
        space: CoverageState,
        skills: CoverageState,
        activity: CoverageState,
        unreadableLocationCount: Int
    ) {
        self.directories = directories
        self.agents = agents
        self.space = space
        self.skills = skills
        self.activity = activity
        self.unreadableLocationCount = unreadableLocationCount
    }
}

public struct Finding: Identifiable, Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case information
        case warning
        case blocked
    }

    public let id: UUID
    public let code: String
    public let severity: Severity
    public let arguments: [String]

    public init(id: UUID = UUID(), code: String, severity: Severity, arguments: [String] = []) {
        self.id = id
        self.code = code
        self.severity = severity
        self.arguments = arguments
    }
}

public struct DeviceSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let generation: UUID
    public let createdAt: Date
    public let isPartial: Bool
    public let products: [AgentProduct]
    public let storageLedger: StorageLedger
    public let coverage: SnapshotCoverage
    public let findings: [Finding]

    public var homes: [AgentHome] { products.flatMap(\.homes) }
    public var totalStorage: StorageMeasurement { storageLedger.total }

    public init(
        id: UUID = UUID(),
        generation: UUID,
        createdAt: Date,
        isPartial: Bool,
        products: [AgentProduct],
        storageLedger: StorageLedger,
        coverage: SnapshotCoverage,
        findings: [Finding]
    ) {
        self.id = id
        self.generation = generation
        self.createdAt = createdAt
        self.isPartial = isPartial
        self.products = products
        self.storageLedger = storageLedger
        self.coverage = coverage
        self.findings = findings
    }
}

public struct ScanRequest: Sendable {
    public let root: URL
    public let customLocations: [URL]
    public let ignoredLocations: [URL]
    public let userConfirmedHomes: [String: String]
    public let environment: [String: String]

    public init(
        root: URL,
        customLocations: [URL] = [],
        ignoredLocations: [URL] = [],
        userConfirmedHomes: [String: String] = [:],
        environment: [String: String] = [:]
    ) {
        self.root = root.standardizedFileURL
        self.customLocations = customLocations.map(\.standardizedFileURL)
        self.ignoredLocations = ignoredLocations.map(\.standardizedFileURL)
        self.userConfirmedHomes = userConfirmedHomes
        self.environment = environment
    }
}
