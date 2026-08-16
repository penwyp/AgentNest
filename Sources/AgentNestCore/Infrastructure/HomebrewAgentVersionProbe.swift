import Foundation

/// 本地 Homebrew 安装版本探测：只执行固定的 `brew list --versions` 只读查询，
/// 输出写入有界临时文件，单次超时 4 秒。不执行网络更新、不执行任何公式脚本。
public struct HomebrewAgentVersionProbe: Sendable {
    public init() {}

    public func installedVersions(for definitions: [AgentDefinition]) async -> [String: String] {
        var formulaProducts: [String: String] = [:]
        var caskProducts: [String: String] = [:]
        for definition in definitions {
            guard let install = definition.marketplace?.install else { continue }
            switch install.kind {
            case .brew:
                formulaProducts[install.formula] = definition.id
            case .cask:
                caskProducts[install.formula] = definition.id
            case .npm, .website:
                break
            }
        }
        guard !formulaProducts.isEmpty || !caskProducts.isEmpty else { return [:] }

        return await Task.detached(priority: .utility) {
            var versions: [String: String] = [:]
            if !formulaProducts.isEmpty,
               let output = Self.runBrewList(kind: "--formula"),
               let parsed = Self.parseVersions(output, productsByFormula: formulaProducts) {
                versions.merge(parsed) { _, new in new }
            }
            if !caskProducts.isEmpty,
               let output = Self.runBrewList(kind: "--cask"),
               let parsed = Self.parseVersions(output, productsByFormula: caskProducts) {
                versions.merge(parsed) { _, new in new }
            }
            return versions
        }.value
    }

    static func parseVersions(
        _ output: String,
        productsByFormula: [String: String]
    ) -> [String: String]? {
        var versions: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let formula = components.first, components.count >= 2 else { continue }
            let name = String(formula)
            guard let productID = productsByFormula[name] else { continue }
            let version = AgentVersion.normalizedVersion(String(components[1]))
            guard !version.isEmpty, version.count <= 128, versions[productID] == nil else { continue }
            versions[productID] = version
        }
        return versions
    }

    private static func runBrewList(kind: String, timeout: TimeInterval = 4) -> String? {
        guard let brewPath = resolveBrewPath() else { return nil }
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let temporaryURL = temporaryDirectory.appending(path: "agentnest-brew-versions-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else { return nil }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        guard let output = try? FileHandle(forWritingTo: temporaryURL) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["list", "--versions", kind]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            try? output.close()
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            try? output.close()
            return nil
        }
        process.waitUntilExit()
        try? output.close()
        guard process.terminationStatus == 0 else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size <= 1_024 * 1_024,
              let data = try? Data(contentsOf: temporaryURL, options: [.mappedIfSafe]),
              let outputText = String(data: data, encoding: .utf8) else { return nil }
        return outputText
    }

    private static func resolveBrewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
