import Foundation

/// 统一解析 AgentNestCore 资源包。
///
/// App 打包时资源位于 `Contents/Resources/AgentNest_AgentNestCore.bundle`；
/// 裸可执行文件与 SwiftPM 测试运行时则由 SwiftPM 的 `Bundle.module` 定位。
enum AgentNestCoreResourceBundle {
    static let bundle: Bundle = {
        let mainURL = Bundle.main.bundleURL
        let candidates = [
            Bundle.main.url(forResource: "AgentNest_AgentNestCore", withExtension: "bundle"),
            mainURL.appending(path: "Contents/Resources/AgentNest_AgentNestCore.bundle"),
            Bundle.main.resourceURL?.appending(path: "AgentNest_AgentNestCore.bundle"),
        ]
        for candidate in candidates {
            guard let candidate, let bundle = Bundle(url: candidate) else { continue }
            return bundle
        }
        return Bundle.module
    }()
}
