import Foundation

/// Agent 详情页的“实际内容洞察”：只读取本地可验证的配置文件、MCP 声明与用量记录，
/// 不在没有证据时编造套餐或用量。
public struct AgentInsightSnapshot: Codable, Equatable, Sendable {
    public let productID: String
    public let mcpInstallations: [AgentMcpInstallation]
    public let configurationEntries: [AgentConfigurationEntry]
    public let usage: AgentUsageSummary?

    public init(
        productID: String,
        mcpInstallations: [AgentMcpInstallation],
        configurationEntries: [AgentConfigurationEntry],
        usage: AgentUsageSummary?
    ) {
        self.productID = productID
        self.mcpInstallations = mcpInstallations
        self.configurationEntries = configurationEntries
        self.usage = usage
    }
}

public struct AgentMcpInstallation: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let command: String?
    public let enabled: Bool
    public let source: String

    public init(id: String, name: String, command: String?, enabled: Bool, source: String) {
        self.id = id
        self.name = name
        self.command = command
        self.enabled = enabled
        self.source = source
    }
}

public struct AgentConfigurationEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let value: String
    public let source: String

    public init(id: String, key: String, value: String, source: String) {
        self.id = id
        self.key = key
        self.value = value
        self.source = source
    }
}

public struct AgentModelUsage: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let cacheReadInputTokens: UInt64
    public let cacheCreationInputTokens: UInt64
    public let costUSD: Double

    public init(
        id: String,
        model: String,
        inputTokens: UInt64,
        outputTokens: UInt64,
        cacheReadInputTokens: UInt64,
        cacheCreationInputTokens: UInt64,
        costUSD: Double
    ) {
        self.id = id
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.costUSD = costUSD
    }
}

public struct AgentUsageSummary: Codable, Equatable, Sendable {
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let cacheReadInputTokens: UInt64
    public let cacheCreationInputTokens: UInt64
    public let costUSD: Double
    public let linesAdded: UInt64
    public let linesRemoved: UInt64
    public let durationSeconds: UInt64
    public let modelUsage: [AgentModelUsage]

    public init(
        inputTokens: UInt64,
        outputTokens: UInt64,
        cacheReadInputTokens: UInt64,
        cacheCreationInputTokens: UInt64,
        costUSD: Double,
        linesAdded: UInt64,
        linesRemoved: UInt64,
        durationSeconds: UInt64,
        modelUsage: [AgentModelUsage]
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.costUSD = costUSD
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.durationSeconds = durationSeconds
        self.modelUsage = modelUsage
    }
}
