import AgentNestCore
import SwiftUI

@main
struct AgentNestApplication: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AgentNest") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .environment(\.locale, model.appLocale)
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra("AgentNest", systemImage: model.isScanning ? "magnifyingglass.circle.fill" : "bird") {
            Text(model.menuStatus)
            Divider()
            Button("打开 AgentNest") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            if model.isScanning {
                Button("停止扫描") { model.stopScan() }
            } else {
                Button("开始扫描") { model.startScan() }
            }
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .commands {
            CommandMenu("AgentNest") {
                Button("开始扫描") { model.startScan() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("停止扫描") { model.stopScan() }
                    .disabled(!model.isScanning)
                Divider()
                Button("检查更新") { model.checkForUpdates() }
                    .disabled(!model.updateAvailable || model.isMutatingEnvironment)
            }
        }
    }
}
