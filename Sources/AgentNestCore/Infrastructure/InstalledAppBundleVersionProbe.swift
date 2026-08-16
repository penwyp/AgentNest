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

    public static func installedVersion(
        appName: String,
        additionalApplicationDirectories: [URL] = []
    ) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        directories.append(contentsOf: additionalApplicationDirectories)
        for directory in directories {
            let candidate = directory.appending(path: "\(appName).app")
            guard let bundle = Bundle(path: candidate.path) else { continue }
            let rawVersion: String?
            if let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
                rawVersion = value
            } else if let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? NSNumber {
                rawVersion = value.stringValue
            } else {
                rawVersion = nil
            }
            guard let rawVersion else { continue }
            let version = AgentVersion.normalizedVersion(rawVersion)
            if !version.isEmpty { return version }
        }
        return nil
    }
}
