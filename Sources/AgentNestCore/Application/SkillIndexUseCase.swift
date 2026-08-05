import CryptoKit
import Foundation

public struct SkillIndexPolicy: Sendable {
    public let maximumFilesPerSkill: Int
    public let maximumFileBytes: Int
    public let maximumSkillBytes: Int

    public init(maximumFilesPerSkill: Int = 256, maximumFileBytes: Int = 1_048_576, maximumSkillBytes: Int = 16_777_216) {
        self.maximumFilesPerSkill = maximumFilesPerSkill
        self.maximumFileBytes = maximumFileBytes
        self.maximumSkillBytes = maximumSkillBytes
    }
}

public struct SkillIndexUseCase: Sendable {
    private let catalog: AgentDefinitionCatalog
    private let policy: SkillIndexPolicy

    public init(catalog: AgentDefinitionCatalog, policy: SkillIndexPolicy = SkillIndexPolicy()) {
        self.catalog = catalog
        self.policy = policy
    }

    public func execute(homes: [AgentHome]) async -> SkillIndex {
        var installations: [SkillInstallation] = []
        for home in homes where home.confidence == .confirmed {
            guard let definition = catalog.definitions.first(where: { $0.id == home.productID }),
                  definition.capabilities.skills else { continue }
            for location in definition.skills {
                let root = URL(fileURLWithPath: home.path).appending(path: location.relativePath)
                for child in discoverSkillRoots(in: root) {
                    if let installation = indexSkill(
                        at: child,
                        home: home,
                        format: location.format,
                        isWritable: location.writable && isDirectChild(child, of: root)
                    ) {
                        installations.append(installation)
                    }
                }
            }
        }

        let skillCapableProductIDs = Set(catalog.definitions.filter { $0.capabilities.skills }.map(\.id))
        let allHomeIDs = Set(homes.filter {
            $0.confidence == .confirmed && skillCapableProductIDs.contains($0.productID)
        }.map(\.id))
        let logicalGroups = Dictionary(grouping: installations, by: \.logicalID)
        let logicalSkills = logicalGroups.map { logicalID, group -> LogicalSkill in
            let variantGroups = Dictionary(grouping: group, by: \.contentHash)
            let variants = variantGroups.map { hash, members in
                SkillVariant(logicalID: logicalID, contentHash: hash, installations: members.sorted { $0.path < $1.path })
            }.sorted { $0.contentHash < $1.contentHash }
            let covered = Set(group.map(\.homeID))
            let name = group.first?.name ?? logicalID
            return LogicalSkill(id: logicalID, name: name, variants: variants, missingHomeIDs: Array(allHomeIDs.subtracting(covered)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let conflictCount = logicalSkills.filter { $0.variants.count > 1 }.count
        return SkillIndex(
            logicalSkills: logicalSkills,
            installationCount: installations.count,
            invalidCount: installations.filter { $0.state != .valid }.count,
            conflictCount: conflictCount
        )
    }

    private func discoverSkillRoots(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var roots: [URL] = []
        while let candidate = enumerator.nextObject() as? URL {
            guard let metadata = try? FileMetadata.read(candidate).node else {
                enumerator.skipDescendants()
                continue
            }
            if metadata.isSymbolicLink || metadata.identity.kind == .other {
                enumerator.skipDescendants()
                continue
            }
            guard metadata.identity.kind == .directory else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: "SKILL.md").path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue {
                roots.append(candidate)
                enumerator.skipDescendants()
            }
        }
        return roots.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func indexSkill(at root: URL, home: AgentHome, format: String, isWritable: Bool) -> SkillInstallation? {
        guard let rootMetadata = try? FileMetadata.read(root).node,
              rootMetadata.identity.kind == .directory,
              !rootMetadata.isSymbolicLink else { return nil }
        let mainFile = root.appending(path: "SKILL.md")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mainFile.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return invalidInstallation(
                root: root,
                metadata: rootMetadata,
                home: home,
                format: format,
                isWritable: isWritable,
                diagnostic: "skill.missingMainFile"
            )
        }

        var files: [(String, Data)] = []
        var diagnostics: [String] = []
        var totalBytes = 0
        var latestModification: Date?
        let indexer = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [])
        while let file = indexer?.nextObject() as? URL {
            guard let metadata = try? FileMetadata.read(file).node else { diagnostics.append("skill.unreadable"); continue }
            if metadata.isSymbolicLink || metadata.identity.kind == .other {
                diagnostics.append("skill.unsupportedFileType")
                indexer?.skipDescendants()
                continue
            }
            guard metadata.identity.kind == .file else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            guard isSafeRelativePath(relative) else { diagnostics.append("skill.pathOutsideRoot"); continue }
            guard metadata.logicalBytes <= policy.maximumFileBytes,
                  files.count < policy.maximumFilesPerSkill,
                  totalBytes + Int(metadata.logicalBytes) <= policy.maximumSkillBytes,
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
                diagnostics.append("skill.budgetExceeded")
                continue
            }
            files.append((relative, normalizeTextIfPossible(data)))
            totalBytes += data.count
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               latestModification == nil || date > latestModification! { latestModification = date }
        }
        guard let mainData = files.first(where: { $0.0 == "SKILL.md" })?.1,
              let mainText = String(data: mainData, encoding: .utf8) else {
            diagnostics.append("skill.invalidMainFile")
            return invalidInstallation(
                root: root,
                metadata: rootMetadata,
                home: home,
                format: format,
                isWritable: isWritable,
                diagnostic: diagnostics.first ?? "skill.invalid"
            )
        }
        let manifest = parseFrontmatter(mainText)
        let name = manifest["name"] ?? root.lastPathComponent
        let logicalID = normalizeIdentifier(manifest["id"] ?? name)
        if logicalID.isEmpty { diagnostics.append("skill.invalidName") }
        let contentHash = structuredHash(files)
        return SkillInstallation(
            id: rootMetadata.identity,
            logicalID: logicalID.isEmpty ? normalizeIdentifier(root.lastPathComponent) : logicalID,
            name: name,
            description: manifest["description"],
            path: root.path,
            homeID: home.id,
            scope: .global,
            format: format,
            isWritable: isWritable,
            contentHash: contentHash,
            totalBytes: UInt64(totalBytes),
            fileCount: files.count,
            modifiedAt: latestModification,
            state: diagnostics.isEmpty ? .valid : .invalid,
            diagnostics: diagnostics
        )
    }

    private func invalidInstallation(
        root: URL,
        metadata: IndexedNode,
        home: AgentHome,
        format: String,
        isWritable: Bool,
        diagnostic: String
    ) -> SkillInstallation {
        SkillInstallation(
            id: metadata.identity,
            logicalID: normalizeIdentifier(root.lastPathComponent),
            name: root.lastPathComponent,
            description: nil,
            path: root.path,
            homeID: home.id,
            scope: .global,
            format: format,
            isWritable: isWritable,
            contentHash: "",
            totalBytes: 0,
            fileCount: 0,
            modifiedAt: nil,
            state: .invalid,
            diagnostics: [diagnostic]
        )
    }

    private func structuredHash(_ files: [(String, Data)]) -> String {
        var hasher = SHA256()
        for (path, data) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func normalizeTextIfPossible(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
        return Data(text.utf8)
    }

    private func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var result: [String: String] = [:]
        for line in lines[1..<end] {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return result
    }

    private func normalizeIdentifier(_ value: String) -> String {
        value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }.reduce(into: "") { result, character in
            if character != "-" || !result.hasSuffix("-") { result.append(character) }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && path.split(separator: "/").allSatisfy { $0 != ".." }
    }

    private func isDirectChild(_ child: URL, of parent: URL) -> Bool {
        child.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path
    }
}
