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
    /// App Store 应用 ID（可选，用于 App Store 分发的产品）。
    public let appStoreID: String?
    /// 官网下载页（可选，用于仅官网分发的产品，如 WorkBuddy）。
    public let websiteDownloadURL: String?
    /// 官网更新检查 JSON（可选，读取 `version` / `productVersion`）。
    public let websiteUpdateURL: String?

    public init(
        summary: String,
        homepageURL: String,
        install: AgentInstallMethod? = nil,
        appStoreID: String? = nil,
        websiteDownloadURL: String? = nil,
        websiteUpdateURL: String? = nil
    ) {
        self.summary = summary
        self.homepageURL = homepageURL
        self.install = install
        self.appStoreID = appStoreID
        self.websiteDownloadURL = websiteDownloadURL
        self.websiteUpdateURL = websiteUpdateURL
    }
}

/// 安装方式：Homebrew 公式或 Cask。
public struct AgentInstallMethod: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case brew
        case cask
        case npm
        case website
    }

    public let kind: Kind
    public let formula: String
    /// 可选的官方脚本安装地址（HTTPS）。提供时安装器会优先走脚本，
    /// 脚本失败后再回退到 Homebrew；脚本 URL 由内置 Definition 白名单控制。
    public let scriptURL: String?
    /// 该安装方式是否依赖 Node.js / npm（脚本安装通常需要）。
    public let requiresNode: Bool?
    /// 官网更新检查 URL；`{platform}` 会在运行时替换为当前架构平台标识。
    public let websiteUpdateURL: String?
    /// 官网安装包对应的 .app 名称（用于等待用户完成安装）。
    public let installedAppName: String?

    public init(
        kind: Kind,
        formula: String,
        scriptURL: String? = nil,
        requiresNode: Bool? = nil,
        websiteUpdateURL: String? = nil,
        installedAppName: String? = nil
    ) {
        self.kind = kind
        self.formula = formula
        self.scriptURL = scriptURL
        self.requiresNode = requiresNode
        self.websiteUpdateURL = websiteUpdateURL
        self.installedAppName = installedAppName
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
    /// 可选：当 `kind == .jsonFile` 时，从该 JSON 文件中提取 Agent 版本。
    /// 使用点分路径（如 `version` 或 `build.version`），只允许字典逐级读取。
    public let versionKeyPath: String?

    public init(kind: Kind, relativePath: String, versionKeyPath: String? = nil) {
        self.kind = kind
        self.relativePath = relativePath
        self.versionKeyPath = versionKeyPath
    }
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
