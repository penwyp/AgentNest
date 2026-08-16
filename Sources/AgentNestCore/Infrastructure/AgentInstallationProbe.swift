import Foundation

/// 生效 Agent 安装探测：只报告本机真正会执行的 Agent 可执行文件。
///
/// - CLI 产品按当前进程 PATH 的顺序解析命令，与 shell 的实际执行语义一致；PATH 未覆盖时回退到常见脚本安装目录；
/// - Desktop 产品解析 `/Applications`、`~/Applications` 中 .app 包的主可执行文件。
///
/// 探测结果只包含可执行文件的稳定物理身份与证据，不执行版本查询；
/// 版本由 `ExecutableAgentVersionProbe` / `InstalledAppBundleVersionProbe` 另行采集。
public struct AgentInstallationProbe: Sendable {
    public init() {}

    public func effectiveInstallations(
        for definitions: [AgentDefinition],
        additionalApplicationDirectories: [URL] = []
    ) -> [String: AgentInstallation] {
        var installations = ExecutableAgentVersionProbe().resolvedInstallations(for: definitions)
        let appInstallations = InstalledAppBundleVersionProbe().resolvedInstallations(
            for: definitions,
            additionalApplicationDirectories: additionalApplicationDirectories
        )
        for (productID, installation) in appInstallations where installations[productID] == nil {
            installations[productID] = installation
        }
        return installations
    }
}
