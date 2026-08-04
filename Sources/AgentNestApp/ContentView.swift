import AgentNestCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.hasCoreAccess {
            mainNavigation
        } else {
            ActivationView(model: model)
        }
    }

    private var mainNavigation: some View {
        NavigationSplitView {
            List(AppModel.Destination.allCases, selection: $model.selection) { item in
                Label {
                    Text(LocalizedStringKey(item.rawValue))
                } icon: {
                    Image(systemName: item.systemImage)
                }
                    .tag(item)
            }
            .navigationTitle("AgentNest")
        } detail: {
            switch model.selection ?? .home {
            case .home: HomeView(model: model)
            case .agents: AgentListView(snapshot: model.snapshot)
            case .skills: SkillView(index: model.skillIndex, snapshot: model.snapshot)
            case .storage: StorageView(snapshot: model.snapshot)
            case .activity: ActivityView(snapshot: model.activitySnapshot)
            case .history: HistoryView(model: model)
            case .settings: SettingsView(model: model)
            }
        }
    }
}

private struct ActivationView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("AgentNest").font(.largeTitle.bold())
            Text(model.licenseStatusText)
                .font(.headline)
            Text("试用和设备额度由授权服务记录。本机只信任绑定设备且经过 Ed25519 验签的限时 Receipt。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if model.licenseConfigurationAvailable {
                Button("开始 7 天试用") { model.startTrial() }
                    .buttonStyle(.borderedProminent)
                HStack {
                    SecureField("License Key", text: $model.licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                    Button("激活") { model.activate() }
                        .disabled(model.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("开发构建需配置 AGENTNEST_LICENSE_SERVER_URL 与 AGENTNEST_LICENSE_PUBLIC_KEY。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider().frame(width: 520)
            HStack {
                Button("隐私说明") {}
                Button("删除本地数据", role: .destructive) { model.deleteLocalData() }
                Button("关于") {}
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(40)
    }
}

private struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: model.isScanning ? "magnifyingglass.circle.fill" : "bird.fill")
                .font(.system(size: 76))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: model.isScanning)
                .accessibilityHidden(true)
            Text(model.isScanning ? "正在分析这台 Mac" : "发现并维护你的 Agent 环境")
                .font(.largeTitle.bold())
            Text("默认扫描当前用户 Home（包括隐藏目录），数据只在本机分析，不上传内容。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let progress = model.progress, model.isScanning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(phaseTitle(progress.phase)).font(.headline)
                    Text("已处理 \(progress.processedCount) 项 · \(ByteCountFormatter.string(fromByteCount: Int64(progress.processedBytes), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let location = progress.currentLocation {
                        Text(location).font(.caption2).lineLimit(1).truncationMode(.middle).privacySensitive()
                    }
                }
                .frame(maxWidth: 520)
                Button("停止", role: .cancel) { model.stopScan() }
            } else {
                Button(action: model.startScan) {
                    Label("扫描", systemImage: "magnifyingglass")
                        .font(.title2.bold())
                        .frame(minWidth: 180, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }

            if let snapshot = model.snapshot {
                SnapshotSummary(snapshot: snapshot)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("扫描状态：\(error)")
            }
            Spacer()
        }
        .padding(32)
    }

    private func phaseTitle(_ phase: ScanPhase) -> String {
        switch phase {
        case .discoveringAgents: String(localized: "发现 Agent")
        case .validatingHomes: String(localized: "验证 Home / Profile")
        case .indexingSkills: String(localized: "索引 Skill")
        case .measuringSpace: String(localized: "测量空间")
        case .generatingFindings: String(localized: "生成安全与活动结论")
        case .reconciling: String(localized: "对账并完成")
        }
    }
}

private struct SnapshotSummary: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        HStack(spacing: 28) {
            metric("Agent Home", "\(snapshot.homes.filter { $0.confidence == .confirmed }.count)")
            metric("疑似", "\(snapshot.homes.filter { $0.confidence == .possible }.count)")
            metric("物理占用", ByteCountFormatter.string(fromByteCount: Int64(snapshot.totalStorage.physicalBytes), countStyle: .file))
            metric("完整度", snapshot.isPartial ? "部分" : "完整")
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AgentListView: View {
    let snapshot: DeviceSnapshot?

    var body: some View {
        Group {
            if let snapshot, !snapshot.homes.isEmpty {
                List(snapshot.homes) { home in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(home.displayName).font(.headline)
                            Text(home.confidence == .confirmed ? "已确认" : "疑似")
                                .font(.caption)
                                .foregroundStyle(home.confidence == .confirmed ? .green : .orange)
                        }
                        Text(home.path).font(.caption).foregroundStyle(.secondary).privacySensitive()
                        Text("\(home.source.rawValue) · \(ByteCountFormatter.string(fromByteCount: Int64(home.storage.physicalBytes), countStyle: .file))")
                            .font(.caption2)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ContentUnavailableView("尚无 Agent 结果", systemImage: "cpu", description: Text("先在首页扫描。"))
            }
        }
        .navigationTitle("Agent")
    }
}

private struct SkillView: View {
    let index: SkillIndex?
    let snapshot: DeviceSnapshot?

    var body: some View {
        Group {
            if let index, !index.logicalSkills.isEmpty {
                List(index.logicalSkills) { skill in
                    DisclosureGroup {
                        ForEach(skill.variants) { variant in
                            VStack(alignment: .leading) {
                                Text("Variant \(variant.contentHash.prefix(12))").font(.headline).monospaced()
                                Text("\(variant.installations.count) 个安装副本")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        HStack {
                            Text(skill.name)
                            Spacer()
                            Text("\(skill.variants.count) Variant · 缺失 \(skill.missingHomeIDs.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if snapshot == nil {
                ContentUnavailableView("尚无 Skill 索引", systemImage: "hammer", description: Text("先在首页扫描。"))
            } else {
                ContentUnavailableView(
                    "已扫描，但没有已适配的 Skill 来源",
                    systemImage: "hammer",
                    description: Text("Codex Skill 路径和格式 fixture 尚未确认，因此不会猜测路径或开放写入。")
                )
            }
        }
        .navigationTitle("Skill")
    }
}

private struct StorageView: View {
    let snapshot: DeviceSnapshot?

    var body: some View {
        Group {
            if let snapshot {
                List(snapshot.homes.sorted { $0.storage.physicalBytes > $1.storage.physicalBytes }) { home in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(home.displayName)
                            Text(home.path).font(.caption).foregroundStyle(.secondary).privacySensitive()
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(home.storage.physicalBytes), countStyle: .file))
                            .monospacedDigit()
                    }
                }
            } else {
                ContentUnavailableView("尚无空间账本", systemImage: "internaldrive", description: Text("空间数字仅来自一次完整索引。"))
            }
        }
        .navigationTitle("空间")
    }
}

private struct ActivityView: View {
    let snapshot: ActivitySnapshot?

    var body: some View {
        Group {
            if let snapshot {
                List {
                    Section("整机基础指标") {
                        metricRow("CPU", metric: snapshot.cpuFraction, format: .percent)
                        metricRow("磁盘读取", metric: snapshot.diskReadBytesPerSecond, format: .bytesPerSecond)
                        metricRow("磁盘写入", metric: snapshot.diskWriteBytesPerSecond, format: .bytesPerSecond)
                        metricRow("网络下载", metric: snapshot.networkReceiveBytesPerSecond, format: .bytesPerSecond)
                        metricRow("网络上传", metric: snapshot.networkSendBytesPerSecond, format: .bytesPerSecond)
                    }
                    Section("口径") {
                        Text("首个样本只建立基线；计数器回退、睡眠或过长间隔会重新建立基线，不显示为尖峰。")
                        Text("进程请求写入与物理设备写入不是同一指标；不可用数据不会显示为 0。")
                    }
                }
            } else {
                ContentUnavailableView("正在建立活动基线", systemImage: "waveform.path.ecg", description: Text("第二个可比样本后显示速率。"))
            }
        }
        .navigationTitle("活动")
    }

    private enum MetricFormat { case percent, bytesPerSecond }

    private func metricRow(_ title: String, metric: MetricValue, format: MetricFormat) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text("覆盖率 \(metric.coverage, format: .percent) · 观测 \(metric.observedSeconds, format: .number.precision(.fractionLength(1))) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(metricText(metric, format: format)).monospacedDigit()
        }
    }

    private func metricText(_ metric: MetricValue, format: MetricFormat) -> String {
        guard let value = metric.value else {
            return metric.availability == .partial ? String(localized: "部分可用") : String(localized: "不可用")
        }
        switch format {
        case .percent: return value.formatted(.percent.precision(.fractionLength(1)))
        case .bytesPerSecond:
            return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("sampleInterval") private var sampleInterval = 3.0

    var body: some View {
        Form {
            Section("扫描与隐私") {
                LabeledContent("默认范围", value: "当前用户 Home，不跨卷")
                Toggle("保存脱敏历史聚合", isOn: Binding(
                    get: { model.historyEnabled },
                    set: { model.setHistoryEnabled($0) }
                ))
                if !model.allows(.history) {
                    Text("历史保存需要付费 License。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("活动") {
                Stepper("采样间隔：\(Int(sampleInterval)) 秒", value: $sampleInterval, in: 1...60)
            }
            Section("权限") {
                LabeledContent("Full Disk Access", value: "按需单独授权")
                LabeledContent("Trace Helper", value: "未安装")
                LabeledContent("登录项", value: "未启用")
            }
            Section("本地数据") {
                Button("删除本地数据", role: .destructive) { model.deleteLocalData() }
                Text("停止扫描与采集，并删除快照、历史、Receipt 和 Keychain 凭据；不会删除已移入废纸篓的第三方文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }
}

private struct HistoryView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.historyEnabled {
                ContentUnavailableView("历史默认关闭", systemImage: "clock.arrow.circlepath", description: Text("在设置中明确开启后才创建本地历史数据库。"))
            } else if model.historyPoints.isEmpty {
                ContentUnavailableView("尚无历史样本", systemImage: "chart.xyaxis.line", description: Text("有可比活动样本后将保存脱敏聚合。"))
            } else {
                List(model.historyPoints, id: \.capturedAt) { point in
                    HStack {
                        Text(point.capturedAt, format: .dateTime.month().day().hour().minute().second())
                        Spacer()
                        Text(point.cpuFraction?.formatted(.percent.precision(.fractionLength(1))) ?? "CPU 不可用")
                        Text("覆盖率 \(point.coverage, format: .percent)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("历史")
        .toolbar {
            Button("导出 CSV") { model.exportHistoryCSV() }
                .disabled(!model.historyEnabled || !model.allows(.export))
        }
        .task { await model.refreshHistory() }
    }
}

private struct PlaceholderView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "shippingbox", description: Text(message))
            .navigationTitle(title)
    }
}
