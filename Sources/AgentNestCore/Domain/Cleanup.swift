import Foundation

public enum ArtifactRisk: String, Codable, Sendable {
    case rebuildable
    case expensiveOrShared
    case userContent
    case protected
}

public enum ActivityProtection: String, Codable, Sendable {
    case inactive
    case recentlyOpened
    case writerPresent
    case unknown
}

public enum ActivityEvidenceKind: String, Codable, Sendable {
    case officialMetadata
    case objectMetadata
    case contentMaximumModification
    case rootModification
    case accessTimeOnly
    case unknown
}

public struct LastActivityEvidence: Codable, Equatable, Sendable {
    public let date: Date?
    public let kind: ActivityEvidenceKind
    public let hasConflict: Bool

    public init(date: Date?, kind: ActivityEvidenceKind, hasConflict: Bool = false) {
        self.date = date
        self.kind = kind
        self.hasConflict = hasConflict
    }

    public var isReliableForAutomaticCleanup: Bool {
        date != nil && !hasConflict && kind != .accessTimeOnly && kind != .unknown
    }
}

public enum CleanupMethod: String, Codable, Sendable {
    case trash
    case officialPermanentDelete
}

public struct CleanupUnit: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let generation: UUID
    public let path: String
    public let homePath: String
    public let identity: PhysicalResourceIdentity
    public let homeIdentity: PhysicalResourceIdentity
    public let name: String
    public let category: String
    public let storage: StorageMeasurement
    public let risk: ArtifactRisk
    public let activity: ActivityProtection
    public let lastActivity: LastActivityEvidence
    public let method: CleanupMethod

    public init(
        id: UUID = UUID(),
        generation: UUID,
        path: String,
        homePath: String,
        identity: PhysicalResourceIdentity,
        homeIdentity: PhysicalResourceIdentity,
        name: String,
        category: String,
        storage: StorageMeasurement,
        risk: ArtifactRisk,
        activity: ActivityProtection,
        lastActivity: LastActivityEvidence,
        method: CleanupMethod
    ) {
        self.id = id
        self.generation = generation
        self.path = path
        self.homePath = homePath
        self.identity = identity
        self.homeIdentity = homeIdentity
        self.name = name
        self.category = category
        self.storage = storage
        self.risk = risk
        self.activity = activity
        self.lastActivity = lastActivity
        self.method = method
    }
}

public struct CleanupQuery: Sendable {
    public let inactiveBefore: Date?
    public let minimumPhysicalBytes: UInt64?
    public let risks: Set<ArtifactRisk>

    public init(inactiveBefore: Date? = nil, minimumPhysicalBytes: UInt64? = nil, risks: Set<ArtifactRisk> = []) {
        self.inactiveBefore = inactiveBefore
        self.minimumPhysicalBytes = minimumPhysicalBytes
        self.risks = risks
    }
}

public struct CleanupPlan: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let generation: UUID
    public let units: [CleanupUnit]
    public let estimatedPhysicalBytes: UInt64

    public init(id: UUID = UUID(), generation: UUID, units: [CleanupUnit]) {
        self.id = id
        self.generation = generation
        self.units = units
        self.estimatedPhysicalBytes = units.reduce(0) { $0 &+ $1.storage.physicalBytes }
    }
}

public enum CleanupResultStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case skipped
    case cancelled
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public let unitID: UUID
    public let status: CleanupResultStatus
    public let code: String

    public init(unitID: UUID, status: CleanupResultStatus, code: String) {
        self.unitID = unitID
        self.status = status
        self.code = code
    }
}
