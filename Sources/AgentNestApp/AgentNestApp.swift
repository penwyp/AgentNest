import AgentNestCore
import SwiftUI

@main
struct AgentNestApplication: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        // 以裸可执行文件启动（无 .app bundle / Info.plist）时，AppKit 可能把激活策略
        // 置为 .prohibited：窗口永远不是 key window，键盘输入全部丢失。
        // 显式恢复 .regular，保证输入框可正常接收键盘事件。
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("AgentNest", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .environment(\.locale, model.appLocale)
                .tint(DS.Semantic.accentPrimary)
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra("AgentNest", systemImage: model.isScanning ? "magnifyingglass.circle.fill" : "bird") {
            Text(model.menuStatus)
            Divider()
            Button(model.localized("打开 AgentNest")) {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            if model.isScanning {
                Button(model.localized("停止扫描")) { model.stopScan() }
            } else {
                Button(model.localized("开始扫描")) { model.startScan() }
            }
            Divider()
            Button(model.localized("退出")) { NSApplication.shared.terminate(nil) }
        }
        .commands {
            CommandMenu("AgentNest") {
                Button(model.localized("开始扫描")) { model.startScan() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(model.localized("停止扫描")) { model.stopScan() }
                    .disabled(!model.isScanning)
                Divider()
                Button(model.localized("检查更新")) { model.checkForUpdates() }
                    .disabled(!model.updateAvailable || model.isMutatingEnvironment)
            }
        }
    }
}
