import Foundation

/// 已安装 CLI 版本探测：对内置白名单命令执行固定 `--version` 查询。
/// 不经过 shell，只使用 PATH 中已解析的可执行文件；单命令 2 秒超时，输出限制 64 KB。
/// 用于补充 Homebrew 探测覆盖不到的 npm / curl / 手动安装场景。
public struct ExecutableAgentVersionProbe: Sendable {
    private struct Command: Sendable {
        let executable: String
        let arguments: [String]
    }

    private static let commandsByProduct: [String: Command] = [
        "openai.codex": Command(executable: "codex", arguments: ["--version"]),
        "anthropic.claude-code": Command(executable: "claude", arguments: ["--version"]),
        "cursor.cursor-cli": Command(executable: "cursor-agent", arguments: ["--version"]),
        "google.gemini-cli": Command(executable: "gemini", arguments: ["--version"]),
        "opencode.opencode": Command(executable: "opencode", arguments: ["--version"]),
        "aider.aider": Command(executable: "aider", arguments: ["--version"]),
        "inflection.pi": Command(executable: "pi", arguments: ["--version"]),
    ]

    public init() {}

    public func installedVersions(for definitions: [AgentDefinition]) async -> [String: String] {
        let targets = definitions.compactMap { definition -> (String, Command)? in
            guard let command = Self.commandsByProduct[definition.id] else { return nil }
            return (definition.id, command)
        }
        guard !targets.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, String?).self) { group in
            for (productID, command) in targets {
                group.addTask {
                    let version = Self.runVersion(command: command)
                    return (productID, version)
                }
            }
            var versions: [String: String] = [:]
            for await (productID, version) in group {
                guard let version, versions[productID] == nil else { continue }
                versions[productID] = version
            }
            return versions
        }
    }

    static func parseVersionOutput(_ output: String) -> String? {
        for token in output.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "," }) {
            let candidate = AgentVersion.normalizedVersion(String(token))
            guard !candidate.isEmpty,
                  candidate.count <= 128,
                  candidate.contains(where: \.isNumber),
                  candidate.first?.isNumber == true || candidate.hasPrefix("v") else { continue }
            guard candidate.dropFirst().allSatisfy({ $0 == "." || $0 == "-" || $0 == "+" || $0.isNumber }) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func runVersion(command: Command, timeout: TimeInterval = 2) -> String? {
        guard let executableURL = resolveExecutable(named: command.executable) else { return nil }
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let temporaryURL = temporaryDirectory.appending(path: "agentnest-agent-version-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else { return nil }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        guard let outputHandle = try? FileHandle(forWritingTo: temporaryURL) else { return nil }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = command.arguments
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        do {
            try process.run()
        } catch {
            try? outputHandle.close()
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            try? outputHandle.close()
            return nil
        }
        process.waitUntilExit()
        try? outputHandle.close()
        guard process.terminationStatus == 0 else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size <= 64 * 1_024,
              let data = try? Data(contentsOf: temporaryURL, options: [.mappedIfSafe]),
              let output = String(data: data, encoding: .utf8) else { return nil }
        return parseVersionOutput(output)
    }

    /// 已解析的生效可执行文件（不执行 `--version`，只做 PATH 解析与文件身份采集）。
    /// PATH 按进程环境顺序生效；PATH 未覆盖时再回退到常见脚本安装目录。
    /// 用于扫描快照中填充 `AgentInstallation`；版本仍由 `installedVersions` 探测。
    func resolvedInstallations(for definitions: [AgentDefinition]) -> [String: AgentInstallation] {
        var installations: [String: AgentInstallation] = [:]
        for definition in definitions {
            guard let command = Self.commandsByProduct[definition.id],
                  let executableURL = Self.resolveExecutable(named: command.executable),
                  let node = try? FileMetadata.read(executableURL).node else { continue }
            installations[definition.id] = AgentInstallation(
                id: node.identity,
                productID: definition.id,
                path: node.path,
                version: nil,
                evidence: ["effective-executable:\(node.path)"]
            )
        }
        return installations
    }

    private static func resolveExecutable(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scriptInstallLocations = [
            home.appending(path: ".opencode/bin/\(name)"),
            home.appending(path: ".local/bin/\(name)"),
            home.appending(path: ".claude/local/\(name)"),
            home.appending(path: ".codex/bin/\(name)"),
        ]
        let pathValue = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var candidates = pathValue.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appending(path: name)
        }
        candidates.append(contentsOf: scriptInstallLocations)
        for url in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue == false,
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return nil
    }
}
