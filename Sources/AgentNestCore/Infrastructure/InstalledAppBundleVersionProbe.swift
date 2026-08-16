import Foundation

/// 已安装桌面 App 版本探测：根据 Definition 声明的 `installedAppName` 读取
/// `/Applications` 与 `~/Applications` 中的 `.app` 包版本。
/// 用于 Homebrew 探测覆盖不到的手动安装 / App Store 安装。
public struct InstalledAppBundleVersionProbe: Sendable {
    public init() {}

    public func installedVersions(
        for definitions: [AgentDefinition],
        additionalApplicationDirectories: [URL] = []
    ) async -> [String: String] {
        var versions: [String: String] = [:]
        for definition in definitions {
            guard let appName = definition.marketplace?.install?.installedAppName else { continue }
            if let version = Self.installedVersion(
                appName: appName,
                additionalApplicationDirectories: additionalApplicationDirectories
            ) {
                versions[definition.id] = version
            }
        }
        return versions
    }

    /// 已安装桌面 App 的生效可执行文件（`Contents/MacOS/<CFBundleExecutable>`）。
    /// 只解析实际可执行的 bundle 主程序；版本可随后由 `installedVersions` 补充。
    func resolvedInstallations(
        for definitions: [AgentDefinition],
        additionalApplicationDirectories: [URL] = []
    ) -> [String: AgentInstallation] {
        var installations: [String: AgentInstallation] = [:]
        for definition in definitions {
            guard let appName = definition.marketplace?.install?.installedAppName,
                  let executableURL = Self.executableURL(
                      appName: appName,
                      additionalApplicationDirectories: additionalApplicationDirectories
                  ),
                  let node = try? FileMetadata.read(executableURL).node else { continue }
            installations[definition.id] = AgentInstallation(
                id: node.identity,
                productID: definition.id,
                path: node.path,
                version: nil,
                evidence: ["effective-app-executable:\(node.path)"]
            )
        }
        return installations
    }

    public static func installedVersion(
        appName: String,
        additionalApplicationDirectories: [URL] = []
    ) -> String? {
        guard let bundleURL = appBundleURL(
            appName: appName,
            additionalApplicationDirectories: additionalApplicationDirectories
        ), let bundle = Bundle(path: bundleURL.path) else { return nil }
        let rawVersion: String?
        if let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            rawVersion = value
        } else if let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? NSNumber {
            rawVersion = value.stringValue
        } else {
            rawVersion = nil
        }
        guard let rawVersion else { return nil }
        let version = AgentVersion.normalizedVersion(rawVersion)
        if version.isEmpty == false { return version }
        return nil
    }

    private static func appBundleURL(
        appName: String,
        additionalApplicationDirectories: [URL]
    ) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        directories.append(contentsOf: additionalApplicationDirectories)
        for directory in directories {
            let candidate = directory.appending(path: "\(appName).app")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func executableURL(
        appName: String,
        additionalApplicationDirectories: [URL]
    ) -> URL? {
        guard let bundleURL = appBundleURL(
            appName: appName,
            additionalApplicationDirectories: additionalApplicationDirectories
        ), let bundle = Bundle(path: bundleURL.path),
           let executablePath = bundle.executablePath else { return nil }
        let url = URL(fileURLWithPath: executablePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false,
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
}
