import Foundation

public struct AgentDefinition: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let homeDiscovery: HomeDiscovery
    public let fingerprints: Fingerprints
    public let skills: [SkillLocation]
    public let artifacts: [ArtifactRule]
    public let capabilities: Capabilities

    public var participatesInScanning: Bool {
        !homeDiscovery.defaultPaths.isEmpty ||
            !homeDiscovery.environmentVariables.isEmpty ||
            !fingerprints.required.isEmpty
    }
}

public struct HomeDiscovery: Codable, Equatable, Sendable {
    public let defaultPaths: [String]
    public let environmentVariables: [String]
}

public struct Fingerprints: Codable, Equatable, Sendable {
    public let required: [FingerprintRule]
    public let optional: [FingerprintRule]
    public let negative: [FingerprintRule]
}

public struct FingerprintRule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case jsonFile
        case file
        case directory
    }

    public let kind: Kind
    public let relativePath: String
}

public struct SkillLocation: Codable, Equatable, Sendable {
    public let relativePath: String
    public let format: String
    public let writable: Bool
}

public struct ArtifactRule: Codable, Equatable, Sendable {
    public let relativePath: String
    public let category: String
    public let cleanup: ArtifactCleanupDefinition?
}

public struct ArtifactCleanupDefinition: Codable, Equatable, Sendable {
    public let risk: ArtifactRisk
    public let method: CleanupMethod
    public let unitBoundary: CleanupUnitBoundary
    public let adapterID: String?
}

public struct Capabilities: Codable, Equatable, Sendable {
    public let space: Bool
    public let skills: Bool
    public let activity: Bool
    public let cleanup: Bool
}
