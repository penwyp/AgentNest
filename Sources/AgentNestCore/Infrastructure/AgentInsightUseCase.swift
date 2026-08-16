import Foundation
import SQLite3

/// 从 Agent 实际落盘文件读取详情页洞察：MCP 安装、基础配置与用量。
///
/// 只读取有限的已知文件与 SQLite 表；单个文件上限 2 MB，JSON 只做只读解析。
public struct AgentInsightUseCase: Sendable {
    public init() {}

    public func execute(
        product: AgentProduct,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentInsightSnapshot {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []
        var usage: AgentUsageSummary?

        switch product.id {
        case "openai.codex":
            (mcp, config) = codexInsight(product: product)
            usage = codexUsage(product: product)
        case "anthropic.claude-code":
            (mcp, config) = claudeCodeInsight(product: product, homeDirectory: homeDirectory)
            usage = claudeCodeUsage(product: product, homeDirectory: homeDirectory)
        case "google.antigravity", "google.antigravity-cli":
            (mcp, config) = antigravityInsight(product: product, homeDirectory: homeDirectory)
        case "cursor.cursor", "cursor.cursor-cli":
            (mcp, config) = cursorInsight(product: product)
        case "opencode.opencode":
            (mcp, config) = openCodeInsight(product: product)
        case "bytedance.trae":
            (mcp, config) = traeInsight(product: product)
        default:
            (mcp, config) = genericInsight(product: product)
        }

        let orderedConfig = config.sorted {
            ($0.source, $0.key) < ($1.source, $1.key)
        }
        return AgentInsightSnapshot(
            productID: product.id,
            mcpInstallations: uniqueMCP(mcp),
            configurationEntries: orderedConfig,
            usage: usage
        )
    }

    // MARK: - Agent-specific readers

    private func codexInsight(product: AgentProduct) -> ([AgentMcpInstallation], [AgentConfigurationEntry]) {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []
        for home in product.homes {
            let root = URL(fileURLWithPath: home.path)
            let tomlURL = root.appending(path: "config.toml")
            guard let text = readText(url: tomlURL, limit: 2_097_152) else { continue }
            config.append(contentsOf: parseTOMLTopLevel(text, source: "config.toml"))
            mcp.append(contentsOf: parseCodexMCPServers(text, source: tomlURL.path))
            break
        }
        return (mcp, config)
    }

    private func claudeCodeInsight(
        product: AgentProduct,
        homeDirectory: URL
    ) -> ([AgentMcpInstallation], [AgentConfigurationEntry]) {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []

        if let settings = readJSON(url: homeDirectory.appending(path: ".claude/settings.json")) {
            config.append(contentsOf: safeJSONEntries(
                settings,
                allowedKeys: ["attribution", "skipDangerousModePermissionPrompt"],
                source: "settings.json"
            ))
            if let hooks = settings["hooks"] as? [String: Any] {
                config.append(AgentConfigurationEntry(
                    id: "settings.json:hooks",
                    key: "hooks",
                    value: "\(hooks.count)",
                    source: "settings.json"
                ))
            }
        }
        if let root = readJSON(url: homeDirectory.appending(path: ".claude.json")) {
            let projects = root["projects"] as? [String: Any] ?? [:]
            config.append(AgentConfigurationEntry(
                id: ".claude.json:projects",
                key: "projects",
                value: "\(projects.count)",
                source: ".claude.json"
            ))
            for project in projects.values {
                guard let object = project as? [String: Any],
                      let servers = object["mcpServers"] as? [String: Any] else { continue }
                mcp.append(contentsOf: mcpFromJSON(servers, source: ".claude.json", defaultEnabled: true))
            }
        }
        return (mcp, config)
    }

    private func antigravityInsight(
        product: AgentProduct,
        homeDirectory: URL
    ) -> ([AgentMcpInstallation], [AgentConfigurationEntry]) {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []
        let candidates: [URL]
        if product.id == "google.antigravity-cli" {
            candidates = [
                homeDirectory.appending(path: ".gemini/antigravity-cli/mcp_config.json"),
                homeDirectory.appending(path: ".gemini/antigravity/mcp_config.json"),
            ]
        } else {
            candidates = [
                homeDirectory.appending(path: ".gemini/antigravity/mcp_config.json"),
                homeDirectory.appending(path: ".antigravity/mcp_config.json"),
            ]
        }
        for url in candidates {
            guard let object = readJSON(url: url) else { continue }
            if let servers = object["mcpServers"] as? [String: Any] {
                mcp.append(contentsOf: mcpFromJSON(servers, source: url.path, defaultEnabled: true))
            } else {
                mcp.append(contentsOf: mcpFromJSON(object, source: url.path, defaultEnabled: true))
            }
            config.append(contentsOf: safeJSONEntries(object, allowedKeys: nil, source: url.lastPathComponent))
        }
        if let settings = readJSON(url: homeDirectory.appending(path: ".gemini/antigravity-cli/settings.json")) {
            config.append(contentsOf: safeJSONEntries(settings, allowedKeys: ["modelProvider"], source: "settings.json"))
        }
        return (mcp, config)
    }

    private func cursorInsight(product: AgentProduct) -> ([AgentMcpInstallation], [AgentConfigurationEntry]) {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []
        for home in product.homes {
            let root = URL(fileURLWithPath: home.path)
            if let object = readJSON(url: root.appending(path: "mcp.json")) {
                if let servers = object["mcpServers"] as? [String: Any] {
                    mcp.append(contentsOf: mcpFromJSON(servers, source: "mcp.json", defaultEnabled: true))
                }
                config.append(contentsOf: safeJSONEntries(object, allowedKeys: nil, source: "mcp.json"))
            }
            if let argv = readJSON(url: root.appending(path: "argv.json")) {
                config.append(contentsOf: safeJSONEntries(argv, allowedKeys: ["locale"], source: "argv.json"))
            }
        }
        return (mcp, config)
    }

    private func openCodeInsight(product: AgentProduct) -> ([AgentMcpInstallation], [AgentConfigurationEntry]) {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []
        for home in product.homes {
            let root = URL(fileURLWithPath: home.path)
            let url = root.appending(path: "opencode.json")
            guard let object = readJSON(url: url) else { continue }
            if let mcpServers = object["mcp"] as? [String: Any] {
                mcp.append(contentsOf: mcpFromJSON(mcpServers, source: "opencode.json", defaultEnabled: true))
            }
            config.append(contentsOf: safeJSONEntries(object, allowedKeys: nil, source: "opencode.json"))
        }
        return (mcp, config)
    }

    private func traeInsight(product: AgentProduct) -> ([AgentMcpInstallation], [AgentConfigurationEntry]) {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []
        for home in product.homes {
            let root = URL(fileURLWithPath: home.path)
            if let object = readJSON(url: root.appending(path: "mcp.json")) {
                if let servers = object["mcpServers"] as? [String: Any] {
                    mcp.append(contentsOf: mcpFromJSON(servers, source: "mcp.json", defaultEnabled: true))
                }
                config.append(contentsOf: safeJSONEntries(object, allowedKeys: nil, source: "mcp.json"))
            }
        }
        return (mcp, config)
    }

    private func genericInsight(product: AgentProduct) -> ([AgentMcpInstallation], [AgentConfigurationEntry]) {
        var mcp: [AgentMcpInstallation] = []
        var config: [AgentConfigurationEntry] = []
        for home in product.homes {
            let root = URL(fileURLWithPath: home.path)
            for fileName in ["settings.json", "mcp_config.json", "mcp.json", "config.json", "argv.json"] {
                let url = root.appending(path: fileName)
                guard let object = readJSON(url: url) else { continue }
                if let servers = object["mcpServers"] as? [String: Any] {
                    mcp.append(contentsOf: mcpFromJSON(servers, source: fileName, defaultEnabled: true))
                }
                config.append(contentsOf: safeJSONEntries(object, allowedKeys: nil, source: fileName))
            }
        }
        return (mcp, config)
    }

    // MARK: - Usage

    private func claudeCodeUsage(
        product: AgentProduct,
        homeDirectory: URL
    ) -> AgentUsageSummary? {
        let url = homeDirectory.appending(path: ".claude.json")
        guard let root = readJSON(url: url),
              let projects = root["projects"] as? [String: Any] else { return nil }

        var input: UInt64 = 0
        var output: UInt64 = 0
        var cacheRead: UInt64 = 0
        var cacheCreation: UInt64 = 0
        var cost = 0.0
        var linesAdded: UInt64 = 0
        var linesRemoved: UInt64 = 0
        var duration: UInt64 = 0
        var modelUsage: [String: AgentModelUsage] = [:]

        for project in projects.values {
            guard let object = project as? [String: Any] else { continue }
            input += positiveUInt64(object["lastTotalInputTokens"])
            output += positiveUInt64(object["lastTotalOutputTokens"])
            cacheRead += positiveUInt64(object["lastTotalCacheReadInputTokens"])
            cacheCreation += positiveUInt64(object["lastTotalCacheCreationInputTokens"])
            cost += positiveDouble(object["lastCost"])
            linesAdded += positiveUInt64(object["lastLinesAdded"])
            linesRemoved += positiveUInt64(object["lastLinesRemoved"])
            duration += positiveUInt64(object["lastDuration"])
            guard let usage = object["lastModelUsage"] as? [String: Any] else { continue }
            for (model, raw) in usage {
                guard let values = raw as? [String: Any] else { continue }
                let item = AgentModelUsage(
                    id: model,
                    model: model,
                    inputTokens: positiveUInt64(values["inputTokens"]),
                    outputTokens: positiveUInt64(values["outputTokens"]),
                    cacheReadInputTokens: positiveUInt64(values["cacheReadInputTokens"]),
                    cacheCreationInputTokens: positiveUInt64(values["cacheCreationInputTokens"]),
                    costUSD: positiveDouble(values["costUSD"])
                )
                let existing = modelUsage[model]
                modelUsage[model] = existing.map { mergeUsage($0, item) } ?? item
            }
        }

        guard input > 0 || output > 0 || cacheRead > 0 || cost > 0 else { return nil }
        return AgentUsageSummary(
            inputTokens: input,
            outputTokens: output,
            cacheReadInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreation,
            costUSD: cost,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            durationSeconds: duration / 1000,
            modelUsage: modelUsage.values.sorted { $0.costUSD > $1.costUSD }
        )
    }

    private func codexUsage(product: AgentProduct) -> AgentUsageSummary? {
        guard let home = product.homes.first(where: { $0.confidence == .confirmed }) ?? product.homes.first else {
            return nil
        }
        let dbURL = URL(fileURLWithPath: home.path).appending(path: "state_5.sqlite")
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        let query = """
        SELECT COALESCE(SUM(tokens_used), 0), COUNT(*)
        FROM threads
        WHERE archived = 0
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let tokens = UInt64(sqlite3_column_int64(statement, 0))
        let threads = UInt64(sqlite3_column_int64(statement, 1))
        guard tokens > 0 || threads > 0 else { return nil }
        return AgentUsageSummary(
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            costUSD: 0,
            linesAdded: 0,
            linesRemoved: 0,
            durationSeconds: 0,
            modelUsage: []
        )
    }

    // MARK: - Parsing

    private func parseTOMLTopLevel(_ text: String, source: String) -> [AgentConfigurationEntry] {
        var entries: [AgentConfigurationEntry] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let rawValue = parts[1].trimmingCharacters(in: .whitespaces)
            guard isSafeConfigurationKey(key) else { continue }
            let value = rawValue.replacingOccurrences(of: "\"", with: "")
            guard value.count <= 256 else { continue }
            entries.append(AgentConfigurationEntry(
                id: "\(source):\(key)",
                key: key,
                value: value,
                source: source
            ))
        }
        return entries
    }

    private func parseCodexMCPServers(_ text: String, source: String) -> [AgentMcpInstallation] {
        var servers: [AgentMcpInstallation] = []
        var currentName: String?
        var command: String?
        var enabled = true
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") {
                if let name = currentName {
                    servers.append(AgentMcpInstallation(
                        id: "\(source):\(name)",
                        name: name,
                        command: command,
                        enabled: enabled,
                        source: source
                    ))
                }
                let start = trimmed.index(trimmed.startIndex, offsetBy: "[mcp_servers.".count)
                let end = trimmed.index(before: trimmed.endIndex)
                currentName = String(trimmed[start..<end])
                command = nil
                enabled = true
            } else if currentName != nil {
                if trimmed.hasPrefix("command") {
                    command = valueAfterEquals(trimmed)?.replacingOccurrences(of: "\"", with: "")
                } else if trimmed.hasPrefix("enabled") {
                    enabled = valueAfterEquals(trimmed)?.lowercased() != "false"
                }
            }
        }
        if let name = currentName {
            servers.append(AgentMcpInstallation(
                id: "\(source):\(name)",
                name: name,
                command: command,
                enabled: enabled,
                source: source
            ))
        }
        return servers
    }

    private func mcpFromJSON(
        _ servers: [String: Any],
        source: String,
        defaultEnabled: Bool
    ) -> [AgentMcpInstallation] {
        servers.compactMap { name, raw in
            guard let object = raw as? [String: Any] else { return nil }
            let command = object["command"] as? String
                ?? object["url"] as? String
                ?? object["type"] as? String
            let disabled = object["disabled"] as? Bool ?? object["enabled"] as? Bool == false
            return AgentMcpInstallation(
                id: "\(source):\(name)",
                name: name,
                command: command,
                enabled: disabled ? false : defaultEnabled,
                source: source
            )
        }
    }

    private func safeJSONEntries(
        _ object: [String: Any],
        allowedKeys: Set<String>?,
        source: String
    ) -> [AgentConfigurationEntry] {
        object.compactMap { key, value in
            if let allowedKeys, allowedKeys.contains(key) == false { return nil }
            guard isSafeConfigurationKey(key) else { return nil }
            let stringValue: String
            switch value {
            case let string as String:
                stringValue = string.count > 160 ? String(string.prefix(160)) + "…" : string
            case let number as NSNumber:
                stringValue = number.stringValue
            case let bool as Bool:
                stringValue = bool ? "true" : "false"
            case let array as [Any]:
                stringValue = "\(array.count)"
            case let dictionary as [String: Any]:
                stringValue = "\(dictionary.count)"
            default:
                return nil
            }
            return AgentConfigurationEntry(
                id: "\(source):\(key)",
                key: key,
                value: stringValue,
                source: source
            )
        }
    }

    private func readJSON(url: URL) -> [String: Any]? {
        guard let data = readData(url: url, limit: 2_097_152),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func readText(url: URL, limit: Int) -> String? {
        guard let data = readData(url: url, limit: limit),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func readData(url: URL, limit: Int) -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size <= UInt64(limit),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return data
    }

    private func uniqueMCP(_ installations: [AgentMcpInstallation]) -> [AgentMcpInstallation] {
        var seen: Set<String> = []
        return installations.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func isSafeConfigurationKey(_ key: String) -> Bool {
        guard key.count <= 80, key.isEmpty == false else { return false }
        let lower = key.lowercased()
        let sensitive = ["token", "key", "secret", "password", "auth", "cookie", "credential", "api"]
        return sensitive.contains { lower.contains($0) } == false
    }

    private func valueAfterEquals(_ line: String) -> String? {
        guard let range = line.range(of: "=") else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private func positiveUInt64(_ value: Any?) -> UInt64 {
        switch value {
        case let number as NSNumber:
            let double = number.doubleValue
            return double > 0 ? UInt64(double) : 0
        case let integer as UInt64:
            return integer
        case let integer as Int:
            return integer > 0 ? UInt64(integer) : 0
        default:
            return 0
        }
    }

    private func positiveDouble(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            return number.doubleValue > 0 ? number.doubleValue : 0
        case let double as Double:
            return double > 0 ? double : 0
        default:
            return 0
        }
    }

    private func mergeUsage(_ lhs: AgentModelUsage, _ rhs: AgentModelUsage) -> AgentModelUsage {
        AgentModelUsage(
            id: lhs.id,
            model: lhs.model,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            costUSD: lhs.costUSD + rhs.costUSD
        )
    }
}
