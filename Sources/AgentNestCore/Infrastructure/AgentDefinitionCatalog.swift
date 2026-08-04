import Foundation

public enum AgentDefinitionError: Error, Equatable, LocalizedError {
    case invalidRoot
    case unknownField(path: String, field: String)
    case unsupportedSchema(Int)
    case invalidRelativePath(String)
    case duplicateID(String)
    case missingBundledResources

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "Agent Definition root must be a JSON object"
        case let .unknownField(path, field): "Unknown field \(field) at \(path)"
        case let .unsupportedSchema(version): "Unsupported Agent Definition schema \(version)"
        case let .invalidRelativePath(path): "Unsafe relative path \(path)"
        case let .duplicateID(id): "Duplicate Agent Definition id \(id)"
        case .missingBundledResources: "Bundled Agent Definitions are missing"
        }
    }
}

public struct AgentDefinitionCatalog: Sendable {
    public let definitions: [AgentDefinition]

    public init(definitions: [AgentDefinition]) throws {
        let ids = definitions.map(\.id)
        if Set(ids).count != ids.count, let duplicate = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) {
            throw AgentDefinitionError.duplicateID(duplicate)
        }
        self.definitions = definitions
    }

    public static func bundled() throws -> AgentDefinitionCatalog {
        let nested = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "AgentDefinitions") ?? []
        let flattened = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let urls = Array(Set(nested + flattened))
        guard !urls.isEmpty else {
            throw AgentDefinitionError.missingBundledResources
        }
        let definitions = try urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try load(data: Data(contentsOf: $0)) }
        return try AgentDefinitionCatalog(definitions: definitions)
    }

    public static func load(data: Data) throws -> AgentDefinition {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw AgentDefinitionError.invalidRoot
        }

        try requireOnly(root, allowed: [
            "schemaVersion", "id", "displayName", "homeDiscovery", "fingerprints",
            "skills", "artifacts", "capabilities",
        ], path: "$")
        try validateObject(root["homeDiscovery"], allowed: [
            "defaultPaths", "environmentVariables", "allowDeepDiscovery",
        ], path: "$.homeDiscovery")
        try validateObject(root["fingerprints"], allowed: ["required", "optional", "negative"], path: "$.fingerprints")
        if let fingerprints = root["fingerprints"] as? [String: Any] {
            for key in ["required", "optional", "negative"] {
                try validateArrayObjects(fingerprints[key], allowed: ["kind", "relativePath"], path: "$.fingerprints.\(key)")
            }
        }
        try validateArrayObjects(root["skills"], allowed: ["relativePath", "format"], path: "$.skills")
        try validateArrayObjects(root["artifacts"], allowed: ["relativePath", "category", "cleanup"], path: "$.artifacts")
        if let artifacts = root["artifacts"] as? [[String: Any]] {
            for (index, artifact) in artifacts.enumerated() {
                try validateObject(artifact["cleanup"], allowed: ["risk", "method"], path: "$.artifacts[\(index)].cleanup")
            }
        }
        try validateObject(root["capabilities"], allowed: ["space", "skills", "activity", "cleanup"], path: "$.capabilities")

        let definition = try JSONDecoder().decode(AgentDefinition.self, from: data)
        guard definition.schemaVersion == 1 else {
            throw AgentDefinitionError.unsupportedSchema(definition.schemaVersion)
        }
        let paths = definition.fingerprints.required.map(\.relativePath)
            + definition.fingerprints.optional.map(\.relativePath)
            + definition.fingerprints.negative.map(\.relativePath)
            + definition.skills.map(\.relativePath)
            + definition.artifacts.map(\.relativePath)
        for path in paths where !isSafeRelativePath(path) {
            throw AgentDefinitionError.invalidRelativePath(path)
        }
        for path in definition.homeDiscovery.defaultPaths where !isSafeDefaultHomePath(path) {
            throw AgentDefinitionError.invalidRelativePath(path)
        }
        for variable in definition.homeDiscovery.environmentVariables where !isSafeEnvironmentVariable(variable) {
            throw AgentDefinitionError.invalidRelativePath(variable)
        }
        return definition
    }

    private static func validateObject(_ value: Any?, allowed: Set<String>, path: String) throws {
        guard let value = value as? [String: Any] else { return }
        try requireOnly(value, allowed: allowed, path: path)
    }

    private static func validateArrayObjects(_ value: Any?, allowed: Set<String>, path: String) throws {
        guard let values = value as? [[String: Any]] else { return }
        for (index, object) in values.enumerated() {
            try requireOnly(object, allowed: allowed, path: "\(path)[\(index)]")
        }
    }

    private static func requireOnly(_ object: [String: Any], allowed: Set<String>, path: String) throws {
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
            throw AgentDefinitionError.unknownField(path: path, field: unknown)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != ".." && !$0.isEmpty }
    }

    private static func isSafeDefaultHomePath(_ path: String) -> Bool {
        guard path == "~" || path.hasPrefix("~/") else { return false }
        let suffix = path == "~" ? "home" : String(path.dropFirst(2))
        return isSafeRelativePath(suffix)
    }

    private static func isSafeEnvironmentVariable(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isASCII && first.isLetter else { return false }
        return value.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
