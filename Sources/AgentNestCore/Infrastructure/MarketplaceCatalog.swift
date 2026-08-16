import Foundation

public enum MarketplaceCatalogError: Error, Equatable {
    case missingBundledResource(String)
    case duplicateSkillID(String)
    case duplicateMCPServerID(String)
}

public extension MarketplaceCatalog {
    /// Loads the bundled marketplace catalog from `Resources/Marketplace`.
    ///
    /// SwiftPM may either preserve the `Marketplace` subdirectory or flatten processed
    /// resources, so both lookup strategies are attempted.
    static func bundled() throws -> MarketplaceCatalog {
        let skillsData = try bundledData(resource: "marketplace-skills", extension: "json")
        let mcpData = try bundledData(resource: "marketplace-mcp-servers", extension: "json")

        struct SkillEnvelope: Decodable {
            let skills: [SkillMarketplaceItem]
        }
        struct MCPEnvelope: Decodable {
            let mcpServers: [MCPServerMarketplaceItem]
        }

        let decoder = JSONDecoder()
        let skills = try decoder.decode(SkillEnvelope.self, from: skillsData).skills
        let mcpServers = try decoder.decode(MCPEnvelope.self, from: mcpData).mcpServers

        let skillIDs = skills.map(\.id)
        if Set(skillIDs).count != skillIDs.count, let duplicate = skillIDs.first(where: { id in skillIDs.filter { $0 == id }.count > 1 }) {
            throw MarketplaceCatalogError.duplicateSkillID(duplicate)
        }
        let mcpIDs = mcpServers.map(\.id)
        if Set(mcpIDs).count != mcpIDs.count, let duplicate = mcpIDs.first(where: { id in mcpIDs.filter { $0 == id }.count > 1 }) {
            throw MarketplaceCatalogError.duplicateMCPServerID(duplicate)
        }

        return MarketplaceCatalog(skills: skills, mcpServers: mcpServers)
    }

    private static func bundledData(resource: String, extension pathExtension: String) throws -> Data {
        if let url = AgentNestCoreResourceBundle.bundle.url(
            forResource: resource,
            withExtension: pathExtension,
            subdirectory: "Marketplace"
        ) ?? AgentNestCoreResourceBundle.bundle.url(
            forResource: resource,
            withExtension: pathExtension
        ) {
            return try Data(contentsOf: url)
        }
        throw MarketplaceCatalogError.missingBundledResource(resource)
    }
}
