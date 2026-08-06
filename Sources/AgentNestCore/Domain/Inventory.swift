import Foundation

public enum AgentSupportState: String, Codable, Sendable {
    case supported
    case detectable
}

public struct AgentInstallation: Identifiable, Codable, Equatable, Sendable {
    public let id: PhysicalResourceIdentity
    public let productID: String
    public let path: String
    public let version: String?
    public let evidence: [String]

    public init(
        id: PhysicalResourceIdentity,
        productID: String,
        path: String,
        version: String? = nil,
        evidence: [String]
    ) {
        self.id = id
        self.productID = productID
        self.path = path
        self.version = version
        self.evidence = evidence
    }
}

public struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: PhysicalResourceIdentity
    public let homeID: PhysicalResourceIdentity
    public let displayName: String
    public let path: String
    public let evidence: [String]

    public init(
        id: PhysicalResourceIdentity,
        homeID: PhysicalResourceIdentity,
        displayName: String,
        path: String,
        evidence: [String]
    ) {
        self.id = id
        self.homeID = homeID
        self.displayName = displayName
        self.path = path
        self.evidence = evidence
    }
}

public struct AgentProduct: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let definitionVersion: Int
    public let supportState: AgentSupportState
    public let capabilities: Capabilities
    public let installations: [AgentInstallation]
    public let homes: [AgentHome]
    public let profiles: [AgentProfile]

    public init(
        id: String,
        displayName: String,
        definitionVersion: Int,
        supportState: AgentSupportState,
        capabilities: Capabilities,
        installations: [AgentInstallation],
        homes: [AgentHome],
        profiles: [AgentProfile]
    ) {
        self.id = id
        self.displayName = displayName
        self.definitionVersion = definitionVersion
        self.supportState = supportState
        self.capabilities = capabilities
        self.installations = installations
        self.homes = homes
        self.profiles = profiles
    }
}

public enum ArtifactCategory: String, Codable, CaseIterable, Sendable {
    case sessions
    case cache
    case logs
    case runtime
    case browser
    case database
    case skill
    case configuration
    case unattributed

    public init(definitionValue: String) {
        switch definitionValue.lowercased() {
        case "session", "sessions": self = .sessions
        case "cache", "caches": self = .cache
        case "log", "logs": self = .logs
        case "runtime": self = .runtime
        case "browser": self = .browser
        case "database", "databases", "db": self = .database
        case "skill", "skills": self = .skill
        case "config", "configuration": self = .configuration
        default: self = .unattributed
        }
    }
}

public enum StorageAttribution: String, Codable, Sendable {
    case home
    case shared
    case unattributed
}

public enum StorageOwnershipScope: Hashable, Sendable {
    case all
    case product(String)
    case home(PhysicalResourceIdentity)
}

public struct ArtifactRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: PhysicalResourceIdentity
    public let path: String
    public let category: ArtifactCategory
    public let attribution: StorageAttribution
    public let homeIDs: [PhysicalResourceIdentity]
    public let profileIDs: [PhysicalResourceIdentity]
    public let storage: StorageMeasurement
    public let evidence: [String]
    public let modifiedAt: Date?

    public init(
        id: PhysicalResourceIdentity,
        path: String,
        category: ArtifactCategory,
        attribution: StorageAttribution,
        homeIDs: [PhysicalResourceIdentity],
        profileIDs: [PhysicalResourceIdentity] = [],
        storage: StorageMeasurement,
        evidence: [String],
        modifiedAt: Date?
    ) {
        self.id = id
        self.path = path
        self.category = category
        self.attribution = attribution
        self.homeIDs = homeIDs
        self.profileIDs = profileIDs
        self.storage = storage
        self.evidence = evidence
        self.modifiedAt = modifiedAt
    }
}

public struct StorageLedger: Codable, Equatable, Sendable {
    public let artifacts: [ArtifactRecord]
    public let total: StorageMeasurement

    public init(artifacts: [ArtifactRecord]) {
        var seen: Set<PhysicalResourceIdentity> = []
        var unique: [ArtifactRecord] = []
        var logical: UInt64 = 0
        var physical: UInt64 = 0
        for artifact in artifacts where seen.insert(artifact.id).inserted {
            unique.append(artifact)
            logical &+= artifact.storage.logicalBytes
            physical &+= artifact.storage.physicalBytes
        }
        self.artifacts = unique
        self.total = StorageMeasurement(
            logicalBytes: logical,
            physicalBytes: physical,
            itemCount: unique.count
        )
    }
}
