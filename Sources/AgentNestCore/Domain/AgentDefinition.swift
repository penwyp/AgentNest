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
    /// 市场面板展示信息（可选；缺失时市场面板显示「暂无安装方式」）。
    public let marketplace: AgentMarketplace?

    public var participatesInScanning: Bool {
        !homeDiscovery.defaultPaths.isEmpty ||
            !homeDiscovery.environmentVariables.isEmpty ||
            !fingerprints.required.isEmpty
    }

    public init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        homeDiscovery: HomeDiscovery,
        fingerprints: Fingerprints,
        skills: [SkillLocation],
        artifacts: [ArtifactRule],
        capabilities: Capabilities,
        marketplace: AgentMarketplace? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.homeDiscovery = homeDiscovery
        self.fingerprints = fingerprints
        self.skills = skills
        self.artifacts = artifacts
        self.capabilities = capabilities
        self.marketplace = marketplace
    }
}

/// 市场面板展示信息：简介、主页与可选安装方式。
public struct AgentMarketplace: Codable, Equatable, Sendable {
    public let summary: String
    public let homepageURL: String
    public let install: AgentInstallMethod?

    public init(summary: String, homepageURL: String, install: AgentInstallMethod? = nil) {
        self.summary = summary
        self.homepageURL = homepageURL
        self.install = install
    }
}

/// 安装方式：Homebrew 公式或 Cask。
public struct AgentInstallMethod: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case brew
        case cask
    }

    public let kind: Kind
    public let formula: String

    public init(kind: Kind, formula: String) {
        self.kind = kind
        self.formula = formula
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
