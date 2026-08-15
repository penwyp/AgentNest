import Foundation

/// A curated, installable Skill shown in the Skills marketplace.
public struct SkillMarketplaceItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let publisher: String
    public let summary: String
    public let homepageURL: String
    public let repositoryURL: String?
    public let installCommand: String
    public let category: String
    public let tags: [String]
    public let verified: Bool

    public init(
        id: String,
        name: String,
        publisher: String,
        summary: String,
        homepageURL: String,
        repositoryURL: String? = nil,
        installCommand: String,
        category: String,
        tags: [String],
        verified: Bool
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.summary = summary
        self.homepageURL = homepageURL
        self.repositoryURL = repositoryURL
        self.installCommand = installCommand
        self.category = category
        self.tags = tags
        self.verified = verified
    }
}

public enum MCPTransport: String, Codable, Sendable, CaseIterable {
    case stdio
    case sse
    case http
}

/// A curated MCP server shown in the MCP marketplace.
public struct MCPServerMarketplaceItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let publisher: String
    public let summary: String
    public let homepageURL: String
    public let category: String
    public let transport: MCPTransport
    public let command: String
    public let args: [String]
    public let environment: [String: String]
    public let repositoryURL: String?
    public let tags: [String]
    public let verified: Bool

    public init(
        id: String,
        name: String,
        publisher: String,
        summary: String,
        homepageURL: String,
        category: String,
        transport: MCPTransport,
        command: String,
        args: [String],
        environment: [String: String] = [:],
        repositoryURL: String? = nil,
        tags: [String],
        verified: Bool
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.summary = summary
        self.homepageURL = homepageURL
        self.category = category
        self.transport = transport
        self.command = command
        self.args = args
        self.environment = environment
        self.repositoryURL = repositoryURL
        self.tags = tags
        self.verified = verified
    }

    /// The shell-style command shown on cards. Arguments containing spaces are quoted.
    public var installCommand: String {
        ([command] + args)
            .map { value in
                value.contains(" ") || value.contains("\"")
                    ? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
                    : value
            }
            .joined(separator: " ")
    }

    /// A Claude Desktop compatible `mcpServers` entry. Empty environment values are omitted.
    public func configurationJSON(serverKey: String? = nil) -> String? {
        var entry: [String: Any] = [
            "command": command,
            "args": args,
        ]
        if !environment.isEmpty {
            entry["env"] = environment
        }
        let root: [String: Any] = [
            "mcpServers": [serverKey ?? id: entry]
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Bundled, read-only marketplace catalog.
public struct MarketplaceCatalog: Sendable, Equatable {
    public let skills: [SkillMarketplaceItem]
    public let mcpServers: [MCPServerMarketplaceItem]

    public init(skills: [SkillMarketplaceItem], mcpServers: [MCPServerMarketplaceItem]) {
        self.skills = skills
        self.mcpServers = mcpServers
    }
}
