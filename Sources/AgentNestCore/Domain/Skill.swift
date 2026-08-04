import Foundation

public enum SkillScope: String, Codable, Sendable {
    case global
    case project
}

public enum SkillInstallationState: String, Codable, Sendable {
    case valid
    case invalid
    case unreadable
    case duplicate
    case conflict
}

public struct SkillInstallation: Identifiable, Codable, Equatable, Sendable {
    public let id: PhysicalResourceIdentity
    public let logicalID: String
    public let name: String
    public let description: String?
    public let path: String
    public let homeID: PhysicalResourceIdentity
    public let scope: SkillScope
    public let format: String
    public let contentHash: String
    public let totalBytes: UInt64
    public let fileCount: Int
    public let modifiedAt: Date?
    public let state: SkillInstallationState
    public let diagnostics: [String]

    public init(
        id: PhysicalResourceIdentity,
        logicalID: String,
        name: String,
        description: String?,
        path: String,
        homeID: PhysicalResourceIdentity,
        scope: SkillScope,
        format: String,
        contentHash: String,
        totalBytes: UInt64,
        fileCount: Int,
        modifiedAt: Date?,
        state: SkillInstallationState,
        diagnostics: [String]
    ) {
        self.id = id
        self.logicalID = logicalID
        self.name = name
        self.description = description
        self.path = path
        self.homeID = homeID
        self.scope = scope
        self.format = format
        self.contentHash = contentHash
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.modifiedAt = modifiedAt
        self.state = state
        self.diagnostics = diagnostics
    }
}

public struct SkillVariant: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let logicalID: String
    public let contentHash: String
    public let installations: [SkillInstallation]

    public init(logicalID: String, contentHash: String, installations: [SkillInstallation]) {
        self.id = "\(logicalID):\(contentHash)"
        self.logicalID = logicalID
        self.contentHash = contentHash
        self.installations = installations
    }
}

public struct LogicalSkill: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let variants: [SkillVariant]
    public let missingHomeIDs: [PhysicalResourceIdentity]

    public init(id: String, name: String, variants: [SkillVariant], missingHomeIDs: [PhysicalResourceIdentity]) {
        self.id = id
        self.name = name
        self.variants = variants
        self.missingHomeIDs = missingHomeIDs
    }
}

public struct SkillIndex: Codable, Equatable, Sendable {
    public let logicalSkills: [LogicalSkill]
    public let installationCount: Int
    public let invalidCount: Int
    public let conflictCount: Int

    public init(logicalSkills: [LogicalSkill], installationCount: Int, invalidCount: Int, conflictCount: Int) {
        self.logicalSkills = logicalSkills
        self.installationCount = installationCount
        self.invalidCount = invalidCount
        self.conflictCount = conflictCount
    }
}

public enum SkillWriteOperation: String, Codable, Sendable {
    case create
    case replace
    case patch
}

public struct SkillWriteFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let data: Data

    public init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

public struct SkillWritePlan: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let generation: UUID
    public let operation: SkillWriteOperation
    public let skillRoot: String
    public let skillRootIdentity: PhysicalResourceIdentity
    public let destination: String
    public let expectedDestinationIdentity: PhysicalResourceIdentity?
    public let files: [SkillWriteFile]

    public init(
        id: UUID = UUID(),
        generation: UUID,
        operation: SkillWriteOperation,
        skillRoot: String,
        skillRootIdentity: PhysicalResourceIdentity,
        destination: String,
        expectedDestinationIdentity: PhysicalResourceIdentity?,
        files: [SkillWriteFile]
    ) {
        self.id = id
        self.generation = generation
        self.operation = operation
        self.skillRoot = skillRoot
        self.skillRootIdentity = skillRootIdentity
        self.destination = destination
        self.expectedDestinationIdentity = expectedDestinationIdentity
        self.files = files
    }
}

public enum SkillWriteError: String, Error, Sendable {
    case invalidName
    case invalidRelativePath
    case targetNotDirectory
    case targetOutsideRoot
    case targetAlreadyExists
    case targetMissing
    case targetChanged
    case generationChanged
    case unsupportedFileType
    case budgetExceeded
    case invalidSkill
}
