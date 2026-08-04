import Darwin
import Foundation

public actor SkillWriteUseCase {
    private let maximumFileCount = 256
    private let maximumTotalBytes = 16_777_216

    public init() {}

    public func planCreate(
        generation: UUID,
        skillRoot: URL,
        name: String,
        description: String
    ) throws -> SkillWritePlan {
        guard isValidName(name) else { throw SkillWriteError.invalidName }
        guard description.utf8.count <= 500 else { throw SkillWriteError.budgetExceeded }
        let root = skillRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootMetadata = try FileMetadata.read(root).node
        guard rootMetadata.identity.kind == .directory, !rootMetadata.isSymbolicLink else { throw SkillWriteError.targetNotDirectory }
        let destination = root.appending(path: name).standardizedFileURL
        guard isDirectChild(destination, of: root) else { throw SkillWriteError.targetOutsideRoot }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SkillWriteError.targetAlreadyExists }
        let main = """
        ---
        name: \(name)
        description: "\(escapeYAMLString(description))"
        ---

        # \(name)
        """
        return SkillWritePlan(
            generation: generation,
            operation: .create,
            skillRoot: root.path,
            skillRootIdentity: rootMetadata.identity,
            destination: destination.path,
            expectedDestinationIdentity: nil,
            files: [SkillWriteFile(relativePath: "SKILL.md", data: Data(main.utf8))]
        )
    }

    public func planPatch(
        generation: UUID,
        skillRoot: URL,
        destinationName: String,
        sourceSkill: URL
    ) throws -> SkillWritePlan {
        guard isValidName(destinationName) else { throw SkillWriteError.invalidName }
        let files = try readPackage(sourceSkill)
        let root = skillRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootMetadata = try FileMetadata.read(root).node
        guard rootMetadata.identity.kind == .directory, !rootMetadata.isSymbolicLink else { throw SkillWriteError.targetNotDirectory }
        let destination = root.appending(path: destinationName).standardizedFileURL
        guard isDirectChild(destination, of: root) else { throw SkillWriteError.targetOutsideRoot }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SkillWriteError.targetAlreadyExists }
        return SkillWritePlan(
            generation: generation,
            operation: .patch,
            skillRoot: root.path,
            skillRootIdentity: rootMetadata.identity,
            destination: destination.path,
            expectedDestinationIdentity: nil,
            files: files
        )
    }

    public func execute(_ plan: SkillWritePlan, currentGeneration: UUID) throws {
        guard plan.generation == currentGeneration else { throw SkillWriteError.generationChanged }
        let root = URL(fileURLWithPath: plan.skillRoot).resolvingSymlinksInPath().standardizedFileURL
        let currentRoot = try FileMetadata.read(root).node
        guard currentRoot.identity == plan.skillRootIdentity else { throw SkillWriteError.targetChanged }
        let destination = URL(fileURLWithPath: plan.destination).standardizedFileURL
        guard isDirectChild(destination, of: root) else { throw SkillWriteError.targetOutsideRoot }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SkillWriteError.targetChanged }
        try validateFiles(plan.files)

        let staging = root.appending(path: ".agentnest-staging-\(plan.id.uuidString)")
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw SkillWriteError.targetChanged }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in plan.files {
                let target = staging.appending(path: file.relativePath).standardizedFileURL
                guard target.path.hasPrefix(staging.path + "/") else { throw SkillWriteError.invalidRelativePath }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: target)
                try handle.write(contentsOf: file.data)
                try handle.synchronize()
                try handle.close()
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            try synchronizeDirectory(root)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    public func moveToTrash(
        skill: URL,
        expectedIdentity: PhysicalResourceIdentity,
        within skillRoot: URL
    ) throws -> URL? {
        let root = skillRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = skill.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectChild(target, of: root) else { throw SkillWriteError.targetOutsideRoot }
        let metadata = try FileMetadata.read(target).node
        guard metadata.identity == expectedIdentity, metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
            throw SkillWriteError.targetChanged
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    private func readPackage(_ source: URL) throws -> [SkillWriteFile] {
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        let rootMetadata = try FileMetadata.read(root).node
        guard rootMetadata.identity.kind == .directory, !rootMetadata.isSymbolicLink else { throw SkillWriteError.targetNotDirectory }
        guard FileManager.default.fileExists(atPath: root.appending(path: "SKILL.md").path) else { throw SkillWriteError.invalidSkill }
        var files: [SkillWriteFile] = []
        var pendingDirectories: [(url: URL, relativePath: String)] = [(root, "")]
        var index = 0
        while index < pendingDirectories.count {
            let directory = pendingDirectories[index]
            index += 1
            for item in try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil) {
                let metadata = try FileMetadata.read(item).node
                if metadata.isSymbolicLink || metadata.identity.kind == .other { throw SkillWriteError.unsupportedFileType }
                let relative = directory.relativePath.isEmpty
                    ? item.lastPathComponent
                    : directory.relativePath + "/" + item.lastPathComponent
                if metadata.identity.kind == .directory {
                    pendingDirectories.append((item, relative))
                    continue
                }
                guard isSafeRelativePath(relative) else { throw SkillWriteError.invalidRelativePath }
                guard metadata.logicalBytes <= UInt64(maximumTotalBytes),
                      files.count < maximumFileCount,
                      files.reduce(0, { $0 + $1.data.count }) + Int(metadata.logicalBytes) <= maximumTotalBytes else {
                    throw SkillWriteError.budgetExceeded
                }
                files.append(SkillWriteFile(relativePath: relative, data: try Data(contentsOf: item, options: [.mappedIfSafe])))
            }
        }
        try validateFiles(files)
        return files
    }

    private func validateFiles(_ files: [SkillWriteFile]) throws {
        guard !files.isEmpty, files.contains(where: { $0.relativePath == "SKILL.md" }) else { throw SkillWriteError.invalidSkill }
        guard files.count <= maximumFileCount, files.reduce(0, { $0 + $1.data.count }) <= maximumTotalBytes else {
            throw SkillWriteError.budgetExceeded
        }
        guard Set(files.map(\.relativePath)).count == files.count,
              files.allSatisfy({ isSafeRelativePath($0.relativePath) }) else { throw SkillWriteError.invalidRelativePath }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 80, name.first != ".", name.last != "-" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func escapeYAMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." }
    }

    private func isDirectChild(_ child: URL, of parent: URL) -> Bool {
        child.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path
    }
}
