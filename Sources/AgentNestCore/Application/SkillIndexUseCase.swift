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
        var roots: [URL] = []
        // 平铺 Markdown skill（DSH `<name>.md` 格式）：只有 root 一级的 `*.md` 文件；
        // bundle 目录内嵌套的 `*.md` 属于资源，不构成独立 skill。
        if let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for candidate in children {
                guard let metadata = try? FileMetadata.read(candidate).node,
                      !metadata.isSymbolicLink,
                      metadata.identity.kind == .file,
                      candidate.pathExtension.lowercased() == "md" else { continue }
                roots.append(candidate)
            }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else { return roots }
        while let candidate = enumerator.nextObject() as? URL {
            guard let metadata = try? FileMetadata.read(candidate).node else {
                enumerator.skipDescendants()
                continue
            }
            if metadata.isSymbolicLink || metadata.identity.kind == .other {
                enumerator.skipDescendants()
                continue
            }
            // `.system` 目录归系统所有（DSH 用户根约定），不作为普通用户 skill 索引。
            if candidate.lastPathComponent == ".system" {
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
              !rootMetadata.isSymbolicLink else { return nil }
        let isFlatFile = rootMetadata.identity.kind == .file
        guard isFlatFile || rootMetadata.identity.kind == .directory else { return nil }
        let mainFile = isFlatFile ? root : root.appending(path: "SKILL.md")
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
        if isFlatFile {
            if rootMetadata.logicalBytes <= policy.maximumFileBytes,
               rootMetadata.logicalBytes <= UInt64(policy.maximumSkillBytes),
               let data = try? Data(contentsOf: root, options: [.mappedIfSafe]) {
                files.append(("SKILL.md", normalizeTextIfPossible(data)))
                totalBytes += data.count
                latestModification = try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            } else {
                diagnostics.append("skill.budgetExceeded")
            }
        } else {
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
        let fallbackName = isFlatFile ? root.deletingPathExtension().lastPathComponent : root.lastPathComponent
        let name = manifest["name"] ?? fallbackName
        let logicalID = normalizeIdentifier(manifest["id"] ?? name)
        if logicalID.isEmpty { diagnostics.append("skill.invalidName") }
        let contentHash = structuredHash(files)
        return SkillInstallation(
            id: rootMetadata.identity,
            logicalID: logicalID.isEmpty ? normalizeIdentifier(fallbackName) : logicalID,
            name: name,
            description: manifest["description"],
            path: root.path,
            homeID: home.id,
            scope: .global,
            format: format,
            isWritable: isWritable && !isFlatFile,
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

    /// 极简 frontmatter 解析：覆盖 Agent 生态 SKILL.md 的常见写法——
    /// 单行键值、单/双引号标量（含跨行）、多行普通标量（缩进续接折叠为空格）、
    /// 块标量（`>` / `>-` / `|` / `|-` 等，内容按缩进收集）。
    /// 无法识别的行安全跳过；所有取值统一去除首尾空白。
    private func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var result: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let rest = String(line[line.index(after: colon)...])

            // 块标量：`description: >-` 等指示符后按缩进收集内容。
            if let style = blockScalarStyle(rest) {
                var content: [String] = []
                while index < end {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty {
                        content.append("")
                        index += 1
                        continue
                    }
                    let nextIndent = next.prefix(while: { $0 == " " || $0 == "\t" }).count
                    guard nextIndent > indent else { break }
                    content.append(String(next.dropFirst(nextIndent)))
                    index += 1
                }
                result[key] = foldBlockScalar(content, style: style).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            result[key] = parseScalar(rest, lines: lines, index: &index, end: end, indent: indent)
        }
        return result
    }

    private enum BlockScalarStyle: Equatable {
        case folded
        case literal
    }

    /// 识别块标量指示符：`>`、`>-`、`>+`、`|`、`|-`、`|+`（可带行尾注释）。
    private func blockScalarStyle(_ raw: String) -> BlockScalarStyle? {
        let token = raw.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let first = token.first, first == ">" || first == "|" else { return nil }
        let tail = token.dropFirst()
        guard tail.isEmpty || tail == "-" || tail == "+" else { return nil }
        return first == ">" ? .folded : .literal
    }

    /// `>` 折叠换行为空格（空行保留为段落分隔）；`|` 保留字面换行。
    private func foldBlockScalar(_ content: [String], style: BlockScalarStyle) -> String {
        switch style {
        case .literal:
            return content.joined(separator: "\n")
        case .folded:
            var paragraphs: [[String]] = [[]]
            for line in content {
                if line.isEmpty {
                    paragraphs.append([])
                } else {
                    paragraphs[paragraphs.count - 1].append(line)
                }
            }
            return paragraphs
                .filter { !$0.isEmpty }
                .map { $0.joined(separator: " ") }
                .joined(separator: "\n")
        }
    }

    /// 解析普通 / 引号标量；引号或普通多行内容按 YAML 规则折叠，并去掉行内注释。
    private func parseScalar(_ rest: String, lines: [String], index: inout Int, end: Int, indent: Int) -> String {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "\"" || trimmed.first == "'" {
            var text = rest
            while index < end, !quotedScalarIsClosed(text) {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                guard !nextTrimmed.isEmpty else { break }
                let nextIndent = next.prefix(while: { $0 == " " || $0 == "\t" }).count
                guard nextIndent > indent else { break }
                // 引号标量跨行时换行折叠为空格（YAML 规则）。
                text += " " + String(next.dropFirst(nextIndent))
                index += 1
            }
            return unquote(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var value = stripInlineComment(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        while index < end {
            let next = lines[index]
            let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
            if nextTrimmed.isEmpty || nextTrimmed.hasPrefix("#") { break }
            let nextIndent = next.prefix(while: { $0 == " " || $0 == "\t" }).count
            guard nextIndent > indent else { break }
            value += " " + stripInlineComment(String(next.dropFirst(nextIndent))).trimmingCharacters(in: .whitespaces)
            index += 1
        }
        return value
    }

    private func quotedScalarIsClosed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = trimmed.first, quote == "\"" || quote == "'", trimmed.count >= 2, trimmed.last == quote else {
            return false
        }
        let before = trimmed[trimmed.index(before: trimmed.endIndex)]
        if quote == "\"" { return before != "\\" }
        return before != "'"
    }

    /// 去掉首尾配对引号；双引号按 YAML 转义规则解码，单引号中 `''` 还原为 `'`。
    private func unquote(_ text: String) -> String {
        guard text.count >= 2,
              let first = text.first, let last = text.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return text }
        let inner = String(text.dropFirst().dropLast())
        if first == "\"" { return unescapeDoubleQuoted(inner) }
        return inner.replacingOccurrences(of: "''", with: "'")
    }

    private func unescapeDoubleQuoted(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var position = value.startIndex
        while position < value.endIndex {
            let char = value[position]
            if char == "\\", value.index(after: position) < value.endIndex {
                let nextPosition = value.index(after: position)
                let next = value[nextPosition]
                switch next {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "u":
                    let hexStart = value.index(nextPosition, offsetBy: 1)
                    if let hexEnd = value.index(hexStart, offsetBy: 4, limitedBy: value.endIndex),
                       let scalar = UInt32(value[hexStart..<hexEnd], radix: 16),
                       let unicode = UnicodeScalar(scalar) {
                        result.unicodeScalars.append(unicode)
                        position = hexEnd
                        continue
                    }
                    result.append("u")
                default: result.append(next)
                }
                position = value.index(after: nextPosition)
            } else {
                result.append(char)
                position = value.index(after: position)
            }
        }
        return result
    }

    /// YAML 普通标量：前面带空格的 `#` 开始行尾注释。
    private func stripInlineComment(_ value: String) -> String {
        var previousWasWhitespace = false
        for (offset, char) in value.enumerated() {
            if char == "#", previousWasWhitespace {
                let cut = value.index(value.startIndex, offsetBy: offset)
                return String(value[..<cut])
            }
            previousWasWhitespace = char == " " || char == "\t"
        }
        return value
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
