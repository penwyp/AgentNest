import Darwin
import Foundation

public actor SkillWriteUseCase {
    private let maximumFileCount = 256
    private let maximumTotalBytes = 16_777_216

    public init() {}

    public func ensureSkillRoot(
        home: URL,
        expectedHomeIdentity: PhysicalResourceIdentity,
        relativePath: String
    ) throws -> URL {
        guard isValidRootName(relativePath) else { throw SkillWriteError.invalidRelativePath }
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        let homeMetadata = try FileMetadata.read(home).node
        guard homeMetadata.identity == expectedHomeIdentity,
              homeMetadata.identity.kind == .directory,
              !homeMetadata.isSymbolicLink else { throw SkillWriteError.targetChanged }
        let root = home.appending(path: relativePath).standardizedFileURL
        guard isDirectChild(root, of: home) else { throw SkillWriteError.targetOutsideRoot }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            let rootMetadata = try FileMetadata.read(root).node
            guard isDirectory.boolValue, rootMetadata.identity.kind == .directory, !rootMetadata.isSymbolicLink else {
                throw SkillWriteError.targetNotDirectory
            }
            return root
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try synchronizeDirectory(home)
        return root
    }

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
        sourceSkill: URL,
        conflictResolution: SkillPatchConflictResolution = .skip
    ) throws -> SkillWritePlan {
        guard isValidName(destinationName) else { throw SkillWriteError.invalidName }
        let files = try readPackage(sourceSkill)
        let root = skillRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootMetadata = try FileMetadata.read(root).node
        guard rootMetadata.identity.kind == .directory, !rootMetadata.isSymbolicLink else { throw SkillWriteError.targetNotDirectory }
        var destination = root.appending(path: destinationName).standardizedFileURL
        guard isDirectChild(destination, of: root) else { throw SkillWriteError.targetOutsideRoot }
        var expectedDestinationIdentity: PhysicalResourceIdentity?
        if FileManager.default.fileExists(atPath: destination.path) {
            switch conflictResolution {
            case .skip:
                throw SkillWriteError.targetAlreadyExists
            case .replace:
                let metadata = try FileMetadata.read(destination).node
                guard metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
                    throw SkillWriteError.targetChanged
                }
                expectedDestinationIdentity = metadata.identity
            case .keepBoth:
                destination = try availableDestination(root: root, baseName: destinationName)
            }
        }
        return SkillWritePlan(
            generation: generation,
            operation: expectedDestinationIdentity == nil ? .patch : .replace,
            skillRoot: root.path,
            skillRootIdentity: rootMetadata.identity,
            destination: destination.path,
            expectedDestinationIdentity: expectedDestinationIdentity,
            files: files
        )
    }

    public func planEdit(
        generation: UUID,
        skillRoot: URL,
        skillName: String,
        expectedIdentity: PhysicalResourceIdentity,
        mainDocument: String
    ) throws -> SkillWritePlan {
        guard mainDocument.utf8.count <= maximumTotalBytes else { throw SkillWriteError.budgetExceeded }
        let root = try validatedRoot(skillRoot)
        let destination = root.url.appending(path: skillName).standardizedFileURL
        guard isDirectChild(destination, of: root.url) else { throw SkillWriteError.targetOutsideRoot }
        let metadata = try FileMetadata.read(destination).node
        guard metadata.identity == expectedIdentity, metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
            throw SkillWriteError.targetChanged
        }
        var files = try readPackage(destination)
        guard let mainIndex = files.firstIndex(where: { $0.relativePath == "SKILL.md" }) else {
            throw SkillWriteError.invalidSkill
        }
        files[mainIndex] = SkillWriteFile(relativePath: "SKILL.md", data: Data(mainDocument.utf8))
        try validateFiles(files)
        return SkillWritePlan(
            generation: generation,
            operation: .replace,
            skillRoot: root.url.path,
            skillRootIdentity: root.identity,
            destination: destination.path,
            expectedDestinationIdentity: expectedIdentity,
            files: files
        )
    }

    public func planRename(
        generation: UUID,
        skillRoot: URL,
        sourceName: String,
        expectedIdentity: PhysicalResourceIdentity,
        destinationName: String
    ) throws -> SkillWritePlan {
        guard isValidName(sourceName), isValidName(destinationName), sourceName != destinationName else {
            throw SkillWriteError.invalidName
        }
        let root = try validatedRoot(skillRoot)
        let source = root.url.appending(path: sourceName).standardizedFileURL
        let destination = root.url.appending(path: destinationName).standardizedFileURL
        guard isDirectChild(source, of: root.url), isDirectChild(destination, of: root.url) else {
            throw SkillWriteError.targetOutsideRoot
        }
        let metadata = try FileMetadata.read(source).node
        guard metadata.identity == expectedIdentity, metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
            throw SkillWriteError.targetChanged
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SkillWriteError.targetAlreadyExists }
        return SkillWritePlan(
            generation: generation,
            operation: .rename,
            skillRoot: root.url.path,
            skillRootIdentity: root.identity,
            source: source.path,
            expectedSourceIdentity: expectedIdentity,
            destination: destination.path,
            expectedDestinationIdentity: nil,
            files: []
        )
    }

    public func planDelete(
        generation: UUID,
        skillRoot: URL,
        skillName: String,
        expectedIdentity: PhysicalResourceIdentity
    ) throws -> SkillWritePlan {
        guard isValidName(skillName) else { throw SkillWriteError.invalidName }
        let root = try validatedRoot(skillRoot)
        let destination = root.url.appending(path: skillName).standardizedFileURL
        guard isDirectChild(destination, of: root.url) else { throw SkillWriteError.targetOutsideRoot }
        let metadata = try FileMetadata.read(destination).node
        guard metadata.identity == expectedIdentity, metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
            throw SkillWriteError.targetChanged
        }
        return SkillWritePlan(
            generation: generation,
            operation: .delete,
            skillRoot: root.url.path,
            skillRootIdentity: root.identity,
            destination: destination.path,
            expectedDestinationIdentity: expectedIdentity,
            files: []
        )
    }

    public func execute(_ plan: SkillWritePlan, currentGeneration: UUID) throws {
        guard plan.generation == currentGeneration else { throw SkillWriteError.generationChanged }
        let root = URL(fileURLWithPath: plan.skillRoot).resolvingSymlinksInPath().standardizedFileURL
        let currentRoot = try FileMetadata.read(root).node
        guard currentRoot.identity == plan.skillRootIdentity else { throw SkillWriteError.targetChanged }
        let destination = URL(fileURLWithPath: plan.destination).standardizedFileURL
        guard isDirectChild(destination, of: root) else { throw SkillWriteError.targetOutsideRoot }

        switch plan.operation {
        case .rename:
            try executeRename(plan, root: root, destination: destination)
            return
        case .delete:
            try executeDelete(plan, root: root, destination: destination)
            return
        case .create, .patch, .replace:
            break
        }

        if let expected = plan.expectedDestinationIdentity {
            let metadata = try FileMetadata.read(destination).node
            guard metadata.identity == expected, metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
                throw SkillWriteError.targetChanged
            }
        } else {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw SkillWriteError.targetChanged }
        }
        try validateFiles(plan.files)

        let staging = root.appending(path: ".agentnest-staging-\(plan.id.uuidString)")
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw SkillWriteError.targetChanged }
        var stagingContainsReplacedTarget = false
        var stagingLockDescriptor: Int32 = -1
        defer {
            if stagingLockDescriptor >= 0 {
                flock(stagingLockDescriptor, LOCK_UN)
                close(stagingLockDescriptor)
            }
        }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            stagingLockDescriptor = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard stagingLockDescriptor >= 0, flock(stagingLockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for file in plan.files {
                let target = staging.appending(path: file.relativePath).standardizedFileURL
                guard CanonicalPath.isDescendant(target.path, of: staging.path) else { throw SkillWriteError.invalidRelativePath }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: target)
                try handle.write(contentsOf: file.data)
                try handle.synchronize()
                try handle.close()
            }
            if plan.expectedDestinationIdentity == nil {
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                let expectedIdentity = plan.expectedDestinationIdentity!
                let destinationBeforeSwap = try FileMetadata.read(destination).node
                guard destinationBeforeSwap.identity == expectedIdentity else { throw SkillWriteError.targetChanged }
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                stagingContainsReplacedTarget = true
                let replacedTarget = try FileMetadata.read(staging).node
                guard replacedTarget.identity == expectedIdentity else {
                    guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    stagingContainsReplacedTarget = false
                    throw SkillWriteError.targetChanged
                }
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: staging, resultingItemURL: &trashedURL)
                stagingContainsReplacedTarget = false
            }
            try synchronizeDirectory(root)
        } catch {
            if !stagingContainsReplacedTarget {
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
    }

    public func recoverAbandonedStaging(
        in skillRoot: URL,
        now: Date = Date(),
        minimumAge: TimeInterval = 3_600
    ) throws -> [SkillStagingRecoveryResult] {
        guard minimumAge >= 60 else { throw SkillWriteError.budgetExceeded }
        let root = try validatedRoot(skillRoot).url
        let prefix = ".agentnest-staging-"
        let cutoff = now.addingTimeInterval(-minimumAge)
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var results: [SkillStagingRecoveryResult] = []

        for child in children.sorted(by: { $0.path < $1.path }) {
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  isDirectChild(child, of: root) else { continue }
            do {
                let before = try FileMetadata.read(child).node
                guard before.identity.kind == .directory, !before.isSymbolicLink,
                      let modifiedAt = before.modifiedAt, modifiedAt <= cutoff else { continue }
                let descriptor = open(child.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer {
                    flock(descriptor, LOCK_UN)
                    close(descriptor)
                }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
                let current = try FileMetadata.read(child).node
                guard current.identity == before.identity, !current.isSymbolicLink,
                      let currentModifiedAt = current.modifiedAt, currentModifiedAt <= cutoff else { continue }
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: child, resultingItemURL: &trashedURL)
                results.append(SkillStagingRecoveryResult(
                    originalPath: child.path,
                    trashedPath: (trashedURL as URL?)?.path,
                    status: .succeeded,
                    code: "skill.stagingRecovered"
                ))
            } catch {
                results.append(SkillStagingRecoveryResult(
                    originalPath: child.path,
                    trashedPath: nil,
                    status: .failed,
                    code: "skill.stagingRecoveryFailed"
                ))
            }
        }
        if results.contains(where: { $0.status == .succeeded }) { try synchronizeDirectory(root) }
        return results
    }

    public func executeSerial(
        _ plans: [SkillWritePlan],
        currentGeneration: UUID,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [SkillWriteResult] {
        var results: [SkillWriteResult] = []
        for (index, plan) in plans.enumerated() {
            if shouldCancel() || Task.isCancelled {
                results.append(contentsOf: plans[index...].map {
                    SkillWriteResult(planID: $0.id, status: .skipped, code: "skill.cancelled")
                })
                break
            }
            do {
                try execute(plan, currentGeneration: currentGeneration)
                results.append(SkillWriteResult(planID: plan.id, status: .succeeded, code: "skill.succeeded"))
            } catch let error as SkillWriteError {
                results.append(SkillWriteResult(planID: plan.id, status: .failed, code: "skill.\(error.rawValue)"))
            } catch {
                results.append(SkillWriteResult(planID: plan.id, status: .failed, code: "skill.ioFailed"))
            }
        }
        return results
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

    private func validatedRoot(_ skillRoot: URL) throws -> (url: URL, identity: PhysicalResourceIdentity) {
        let root = skillRoot.resolvingSymlinksInPath().standardizedFileURL
        let metadata = try FileMetadata.read(root).node
        guard metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
            throw SkillWriteError.targetNotDirectory
        }
        return (root, metadata.identity)
    }

    private func availableDestination(root: URL, baseName: String) throws -> URL {
        for suffix in 2...999 {
            let candidate = root.appending(path: "\(baseName)-\(suffix)").standardizedFileURL
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw SkillWriteError.targetAlreadyExists
    }

    private func executeRename(_ plan: SkillWritePlan, root: URL, destination: URL) throws {
        guard let sourcePath = plan.source, let expectedIdentity = plan.expectedSourceIdentity else {
            throw SkillWriteError.targetChanged
        }
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard isDirectChild(source, of: root) else { throw SkillWriteError.targetOutsideRoot }
        let metadata = try FileMetadata.read(source).node
        guard metadata.identity == expectedIdentity, metadata.identity.kind == .directory, !metadata.isSymbolicLink,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw SkillWriteError.targetChanged
        }
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(root)
    }

    private func executeDelete(_ plan: SkillWritePlan, root: URL, destination: URL) throws {
        guard let expectedIdentity = plan.expectedDestinationIdentity else { throw SkillWriteError.targetChanged }
        let metadata = try FileMetadata.read(destination).node
        guard metadata.identity == expectedIdentity, metadata.identity.kind == .directory, !metadata.isSymbolicLink else {
            throw SkillWriteError.targetChanged
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: destination, resultingItemURL: &trashedURL)
        try synchronizeDirectory(root)
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

    private func isValidRootName(_ name: String) -> Bool {
        !name.isEmpty &&
            name != "." &&
            name != ".." &&
            name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
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
