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
            case .agents: AgentListView(model: model)
            case .skills: SkillView(model: model)
            case .storage: StorageView(model: model)
            case .activity: ActivityView(model: model)
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
                .accessibilityHidden(true)
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
                Button("重试授权服务") { model.retryLicense() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: model.isScanning ? "magnifyingglass.circle.fill" : "bird.fill")
                .font(.system(size: 76))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: model.isScanning && !reduceMotion)
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
                ImpactCards(model: model, snapshot: snapshot)
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

private struct ImpactCards: View {
    @Bindable var model: AppModel
    let snapshot: DeviceSnapshot

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                card(
                    title: "Agent",
                    value: "\(snapshot.homes.filter { $0.confidence == .confirmed }.count) 个 Home",
                    detail: snapshot.homes.contains { $0.confidence == .possible } ? "有疑似位置待确认" : "发现结果已核验",
                    icon: "cpu",
                    destination: .agents
                )
                card(
                    title: "Skill",
                    value: "\(model.skillIndex?.installationCount ?? 0) 个安装",
                    detail: model.skillIndex.map { "\($0.conflictCount) 个冲突 · \($0.invalidCount) 个无效" } ?? "当前 Agent 未声明 Skill 来源",
                    icon: "hammer",
                    destination: .skills
                )
            }
            GridRow {
                card(
                    title: "空间",
                    value: ByteCountFormatter.string(fromByteCount: Int64(snapshot.totalStorage.physicalBytes), countStyle: .file),
                    detail: largestStorageCategory(snapshot),
                    icon: "internaldrive",
                    destination: .storage
                )
                card(
                    title: "活动",
                    value: activityValue,
                    detail: activityDetail,
                    icon: "waveform.path.ecg",
                    destination: .activity
                )
            }
        }
        .frame(maxWidth: 720)
    }

    private func card(
        title: String,
        value: String,
        detail: String,
        icon: String,
        destination: AppModel.Destination
    ) -> some View {
        Button { model.selection = destination } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(value).font(.title3.bold())
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)：\(value)。\(detail)")
        .accessibilityHint("打开\(title)详情")
    }

    private var activityValue: String {
        guard let cpu = model.activitySnapshot?.cpuFraction.value else { return "正在建立基线" }
        return cpu.formatted(.percent.precision(.fractionLength(1))) + " CPU"
    }

    private var activityDetail: String {
        guard let activity = model.activitySnapshot else { return "第二个可比样本后显示速率" }
        let agents = activity.processes.filter { $0.attribution == .agent }.count
        return "\(agents) 个已归因 Agent 进程 · \(activity.droppedEvidenceCount) 个证据缺口"
    }

    private func largestStorageCategory(_ snapshot: DeviceSnapshot) -> String {
        let totals = Dictionary(grouping: snapshot.storageLedger.artifacts, by: \.category).mapValues {
            $0.reduce(UInt64(0)) { $0 &+ $1.storage.physicalBytes }
        }
        guard let largest = totals.max(by: { $0.value < $1.value }) else { return "暂无物理资源" }
        return "最大类别：\(largest.key == .unattributed ? "未归属" : largest.key.rawValue)"
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
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let snapshot = model.snapshot, !snapshot.homes.isEmpty {
                List(snapshot.homes) { home in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(home.displayName).font(.headline)
                            Text(home.confidence == .confirmed ? "已确认" : "疑似")
                                .font(.caption)
                                .foregroundStyle(home.confidence == .confirmed ? .green : .orange)
                        }
                        Text(model.displayPath(home.path)).font(.caption).foregroundStyle(.secondary).privacySensitive()
                        Text("\(home.source.rawValue) · \(ByteCountFormatter.string(fromByteCount: Int64(home.storage.physicalBytes), countStyle: .file))")
                            .font(.caption2)
                        if home.confidence == .possible {
                            HStack {
                                Button("确认为 \(home.displayName)") { model.confirmCandidate(home) }
                                Button("忽略此位置", role: .destructive) { model.ignoreCandidate(home) }
                            }
                        } else if home.source == .userConfirmed {
                            Button("撤销本机确认") { model.revokeCandidateConfirmation(home) }
                        }
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
    @Bindable var model: AppModel
    @State private var editing: SkillInstallation?
    @State private var editorText = ""
    @State private var renaming: SkillInstallation?
    @State private var renameText = ""
    @State private var deleting: SkillInstallation?
    @State private var isCreating = false
    @State private var createTargetID = ""
    @State private var createName = ""
    @State private var createDescription = ""
    @State private var localError: String?

    var body: some View {
        Group {
            if let index = model.skillIndex, !index.logicalSkills.isEmpty {
                List {
                    if let message = localError ?? model.skillOperationMessage {
                        Section("操作结果") {
                            Text(message)
                            Button("关闭") {
                                localError = nil
                                model.clearSkillOperationMessage()
                            }
                        }
                    }
                    ForEach(index.logicalSkills) { skill in
                        DisclosureGroup {
                            ForEach(skill.variants) { variant in
                                DisclosureGroup {
                                    ForEach(variant.installations) { installation in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(model.displayPath(installation.path))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .privacySensitive()
                                            HStack {
                                                Text("\(installation.fileCount) 文件 · \(bytes(installation.totalBytes))")
                                                    .font(.caption2)
                                                Spacer()
                                                Button("编辑") { beginEdit(installation) }
                                                Button("重命名目录") { beginRename(installation) }
                                                Button("移到废纸篓", role: .destructive) { deleting = installation }
                                            }
                                            .disabled(!model.allows(.skillWrite) || installation.state != .valid)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                } label: {
                                    Text("Variant \(variant.contentHash.prefix(12)) · \(variant.installations.count) 个副本")
                                        .font(.headline)
                                        .monospaced()
                                }
                            }
                            if !skill.missingHomeIDs.isEmpty {
                                Button("补齐到 \(skill.missingHomeIDs.count) 个缺失 Home") {
                                    model.patchSkillToMissingHomes(skill)
                                }
                                .disabled(!model.allows(.patch))
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
                }
            } else if model.snapshot == nil {
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
        .toolbar {
            Button {
                guard let first = model.skillWriteTargets.first else { return }
                createTargetID = first.id
                createName = ""
                createDescription = ""
                isCreating = true
            } label: {
                Label("新建 Skill", systemImage: "plus")
            }
            .disabled(!model.allows(.skillWrite) || model.skillWriteTargets.isEmpty)
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                Form {
                    Picker("目标", selection: $createTargetID) {
                        ForEach(model.skillWriteTargets) { target in
                            Text(model.displayPath(target.rootPath)).tag(target.id)
                        }
                    }
                    TextField("名称", text: $createName)
                    TextField("描述", text: $createDescription)
                }
                .formStyle(.grouped)
                .navigationTitle("新建 Skill")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { isCreating = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") {
                            if let target = model.skillWriteTargets.first(where: { $0.id == createTargetID }) {
                                model.createSkill(target: target, name: createName, description: createDescription)
                            }
                            isCreating = false
                        }
                        .disabled(createName.isEmpty)
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 260)
        }
        .sheet(item: $editing) { installation in
            NavigationStack {
                TextEditor(text: $editorText)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .navigationTitle("编辑 \(installation.name)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("原子保存") {
                                model.editSkill(installation, mainDocument: editorText)
                                editing = nil
                            }
                        }
                    }
            }
            .frame(minWidth: 720, minHeight: 520)
        }
        .sheet(item: $renaming) { installation in
            NavigationStack {
                Form {
                    Text("只重命名此安装目录；Skill 清单中的逻辑名称不会被暗改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("新目录名", text: $renameText)
                }
                .formStyle(.grouped)
                .navigationTitle("重命名安装目录")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { renaming = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("重命名") {
                            model.renameSkillInstallation(installation, destinationName: renameText)
                            renaming = nil
                        }
                        .disabled(renameText.isEmpty)
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 220)
        }
        .alert(
            "将 Skill 安装移到废纸篓？",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { installation in
            Button("移到废纸篓", role: .destructive) {
                model.deleteSkillInstallation(installation)
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { installation in
            Text(model.displayPath(installation.path)).privacySensitive()
        }
    }

    private func beginEdit(_ installation: SkillInstallation) {
        do {
            editorText = try model.loadSkillMainDocument(installation)
            editing = installation
        } catch {
            localError = "无法读取 SKILL.md：\(String(describing: error))"
        }
    }

    private func beginRename(_ installation: SkillInstallation) {
        renameText = URL(fileURLWithPath: installation.path).lastPathComponent
        renaming = installation
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

private struct StorageView: View {
    @Bindable var model: AppModel
    @State private var selectedProductID = "*"
    @State private var selectedHomePath = "*"
    @State private var selectedCategory = "*"
    @State private var selectedVolumeDevice = "*"
    @State private var pendingCleanup: CleanupUnit?

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                List {
                    Section("筛选") {
                        Picker("Agent", selection: $selectedProductID) {
                            Text("全部 Agent").tag("*")
                            ForEach(snapshot.products) { product in
                                Text(product.displayName).tag(product.id)
                            }
                        }
                        .onChange(of: selectedProductID) { _, _ in selectedHomePath = "*" }

                        Picker("Home", selection: $selectedHomePath) {
                            Text("全部 Home").tag("*")
                            ForEach(availableHomes(in: snapshot)) { home in
                                Text(model.displayPath(home.path)).tag(home.path)
                            }
                        }

                        Picker("类别", selection: $selectedCategory) {
                            Text("全部类别").tag("*")
                            ForEach(ArtifactCategory.allCases, id: \.rawValue) { category in
                                Text(categoryTitle(category)).tag(category.rawValue)
                            }
                        }

                        Picker("卷", selection: $selectedVolumeDevice) {
                            Text("全部卷").tag("*")
                            ForEach(volumeDevices(in: snapshot), id: \.self) { device in
                                Text(volumeTitle(device: device)).tag(String(device))
                            }
                        }
                    }

                    Section("唯一物理占用") {
                        HStack {
                            Text("合计")
                            Spacer()
                            Text(bytes(filteredArtifacts(in: snapshot).reduce(0) { $0 &+ $1.storage.physicalBytes }))
                                .font(.headline)
                                .monospacedDigit()
                        }
                        Text("每个 device/inode/type 只记一次；共享对象不会重复摊入多个 Home。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("归属与类别") {
                        if storageGroups(in: snapshot).isEmpty {
                            Text("当前筛选没有资源")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(storageGroups(in: snapshot)) { group in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.ownerIsPath ? model.displayPath(group.ownerTitle) : group.ownerTitle)
                                        Text("\(group.volumeTitle) · \(categoryTitle(group.category)) · \(group.itemCount) 项")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(bytes(group.physicalBytes))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }

                    Section("安全清理候选") {
                        if let message = model.cleanupOperationMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.cleanupUnits.isEmpty {
                            Text("当前 Agent Definition 没有声明可清理目标。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.cleanupUnits) { unit in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(unit.name)
                                        Text("\(unit.category) · \(unit.risk.rawValue) · \(unit.activity.rawValue)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(bytes(unit.storage.physicalBytes)).monospacedDigit()
                                    Button("复核") { pendingCleanup = unit }
                                        .disabled(!model.allows(.cleanup) || unit.activity != .inactive || unit.risk == .protected)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("尚无空间账本", systemImage: "internaldrive", description: Text("空间数字仅来自一次完整索引。"))
            }
        }
        .navigationTitle("空间")
        .alert(
            "将目标移到废纸篓？",
            isPresented: Binding(get: { pendingCleanup != nil }, set: { if !$0 { pendingCleanup = nil } }),
            presenting: pendingCleanup
        ) { unit in
            Button("移到废纸篓", role: .destructive) {
                model.executeCleanup(unit)
                pendingCleanup = nil
            }
            Button("取消", role: .cancel) { pendingCleanup = nil }
        } message: { unit in
            Text("\(model.displayPath(unit.path))\n预计物理占用：\(bytes(unit.storage.physicalBytes))\n风险：\(unit.risk.rawValue)；活动：\(unit.activity.rawValue)；方式：\(unit.method.rawValue)")
                .privacySensitive()
        }
    }

    private struct GroupRow: Identifiable {
        let id: String
        let ownerTitle: String
        let ownerIsPath: Bool
        let category: ArtifactCategory
        let volumeTitle: String
        let itemCount: Int
        let physicalBytes: UInt64
    }

    private func availableHomes(in snapshot: DeviceSnapshot) -> [AgentHome] {
        snapshot.homes.filter {
            selectedProductID == "*" || $0.productID == selectedProductID
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func filteredArtifacts(in snapshot: DeviceSnapshot) -> [ArtifactRecord] {
        let selectedHomeID = snapshot.homes.first { $0.path == selectedHomePath }?.id
        let productHomeIDs = Set(snapshot.homes.filter {
            selectedProductID == "*" || $0.productID == selectedProductID
        }.map(\.id))
        return snapshot.storageLedger.artifacts.filter { artifact in
            let matchesProduct = selectedProductID == "*" || artifact.homeIDs.contains { productHomeIDs.contains($0) }
            let matchesHome = selectedHomeID == nil || artifact.homeIDs.contains(selectedHomeID!)
            let matchesCategory = selectedCategory == "*" || artifact.category.rawValue == selectedCategory
            let matchesVolume = selectedVolumeDevice == "*" || String(artifact.id.device) == selectedVolumeDevice
            return matchesProduct && matchesHome && matchesCategory && matchesVolume
        }
    }

    private func storageGroups(in snapshot: DeviceSnapshot) -> [GroupRow] {
        let homesByID = Dictionary(uniqueKeysWithValues: snapshot.homes.map { ($0.id, $0) })
        var groups: [String: (String, Bool, ArtifactCategory, String, Int, UInt64)] = [:]
        for artifact in filteredArtifacts(in: snapshot) {
            let ownerKey: String
            let ownerTitle: String
            let ownerIsPath: Bool
            if artifact.attribution == .shared {
                ownerKey = "shared"
                ownerTitle = "共享资源"
                ownerIsPath = false
            } else if let home = artifact.homeIDs.first.flatMap({ homesByID[$0] }) {
                ownerKey = "home:\(home.path)"
                ownerTitle = home.path
                ownerIsPath = true
            } else {
                ownerKey = "unattributed"
                ownerTitle = "未归属资源"
                ownerIsPath = false
            }
            let key = "\(artifact.id.device)|\(ownerKey)|\(artifact.category.rawValue)"
            let current = groups[key] ?? (ownerTitle, ownerIsPath, artifact.category, volumeTitle(device: artifact.id.device), 0, 0)
            groups[key] = (current.0, current.1, current.2, current.3, current.4 + 1, current.5 &+ artifact.storage.physicalBytes)
        }
        return groups.map { key, value in
            GroupRow(
                id: key,
                ownerTitle: value.0,
                ownerIsPath: value.1,
                category: value.2,
                volumeTitle: value.3,
                itemCount: value.4,
                physicalBytes: value.5
            )
        }.sorted {
            if $0.physicalBytes != $1.physicalBytes { return $0.physicalBytes > $1.physicalBytes }
            return $0.id < $1.id
        }
    }

    private func volumeDevices(in snapshot: DeviceSnapshot) -> [UInt64] {
        Array(Set(snapshot.storageLedger.artifacts.map { $0.id.device })).sorted()
    }

    private func volumeTitle(device: UInt64) -> String {
        if let volume = model.activitySnapshot?.volumes.first(where: { $0.id.device == device }) {
            return model.hideSensitivePaths ? volume.name : "\(volume.name)（\(volume.mountPath)）"
        }
        return "未知卷（device \(device)）"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func categoryTitle(_ category: ArtifactCategory) -> String {
        switch category {
        case .sessions: "会话"
        case .cache: "缓存"
        case .logs: "日志"
        case .runtime: "运行时"
        case .browser: "浏览器"
        case .database: "数据库"
        case .skill: "Skill"
        case .configuration: "配置"
        case .unattributed: "未归属"
        }
    }
}

private struct ActivityView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let snapshot = model.activitySnapshot {
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
                        if snapshot.droppedEvidenceCount > 0 {
                            Text("本轮有 \(snapshot.droppedEvidenceCount) 个进程证据因权限、退出或预算未采集。")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section("可见进程（按 CPU）") {
                        ForEach(snapshot.processes.prefix(20)) { process in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(process.name)
                                    if process.attribution == .agent {
                                        Text("Agent").font(.caption).foregroundStyle(.green)
                                    } else {
                                        Text("macOS 与其它进程").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(metricText(process.cpuFraction, format: .percent)).monospacedDigit()
                                }
                                if let path = process.executablePath {
                                    Text(model.displayPath(path)).font(.caption2).foregroundStyle(.secondary).privacySensitive()
                                }
                                if let workingDirectory = process.workingDirectoryPath {
                                    Text("工作目录：\(model.displayPath(workingDirectory))").font(.caption2).foregroundStyle(.secondary).privacySensitive()
                                }
                                Text("请求读取 \(metricText(process.requestedReadBytesPerSecond, format: .bytesPerSecond)) · 请求写入 \(metricText(process.requestedWriteBytesPerSecond, format: .bytesPerSecond))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if process.attribution == .agent {
                                    DisclosureGroup("文件证据") {
                                        Text("当前打开文件")
                                            .font(.caption.bold())
                                        if process.currentlyOpenFiles.isEmpty {
                                            Text("无权限、进程已退出或当前没有可见 vnode 文件。")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        } else {
                                            ForEach(process.currentlyOpenFiles.prefix(10), id: \.path) { evidence in
                                                Text(model.displayPath(evidence.path))
                                                    .font(.caption2).lineLimit(1).truncationMode(.middle).privacySensitive()
                                            }
                                        }
                                        Text("最近变化")
                                            .font(.caption.bold())
                                        if process.recentChanges.isEmpty {
                                            Text("未启动 Trace Helper；打开文件不会被冒充为变化事件。")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    Section("物理设备吞吐") {
                        if snapshot.physicalDevices.isEmpty {
                            Text("物理设备指标不可用").foregroundStyle(.secondary)
                        } else {
                            ForEach(snapshot.physicalDevices) { device in
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    Text("读 \(metricText(device.readBytesPerSecond, format: .bytesPerSecond))")
                                    Text("写 \(metricText(device.writeBytesPerSecond, format: .bytesPerSecond))")
                                }
                            }
                        }
                    }
                    Section("挂载卷") {
                        ForEach(snapshot.volumes) { volume in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(volume.name)
                                    Spacer()
                                    Text(volume.health == .unavailable ? "健康字段不可用" : volume.health.rawValue)
                                        .font(.caption)
                                }
                                Text(model.displayPath(volume.mountPath)).font(.caption2).foregroundStyle(.secondary).privacySensitive()
                                Text(volumeDescription(volume)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
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

    private func volumeDescription(_ volume: MountedVolume) -> String {
        let available = volume.availableBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " 可用"
        } ?? "容量不可用"
        let locality = volume.isLocal.map { $0 ? "本地" : "非本地" } ?? "本地属性未知"
        let writable = volume.isWritable.map { $0 ? "可写" : "只读" } ?? "写入属性未知"
        let removable = volume.isRemovable.map { $0 ? "可移除" : "不可移除" } ?? "移除属性未知"
        return "\(available) · \(locality) · \(writable) · \(removable)"
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("sampleInterval") private var sampleInterval = 3.0
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("扫描与隐私") {
                LabeledContent("默认范围", value: "当前用户 Home，不跨卷")
                ForEach(model.customScanPaths, id: \.self) { path in
                    HStack {
                        Text(model.displayPath(path)).lineLimit(1).truncationMode(.middle).privacySensitive()
                        Spacer()
                        Button("移除", role: .destructive) { model.removeCustomScanLocation(path) }
                    }
                }
                Button("加入其它目录或本地卷") { model.addCustomScanLocations() }
                if !model.ignoredScanPaths.isEmpty {
                    Text("忽略位置（优先于其它扫描范围）").font(.caption.bold())
                }
                ForEach(model.ignoredScanPaths, id: \.self) { path in
                    HStack {
                        Text(model.displayPath(path)).lineLimit(1).truncationMode(.middle).privacySensitive()
                        Spacer()
                        Button("移除", role: .destructive) { model.removeIgnoredScanLocation(path) }
                    }
                }
                Button("加入忽略位置") { model.addIgnoredScanLocations() }
                Toggle("隐藏敏感路径", isOn: Binding(
                    get: { model.hideSensitivePaths },
                    set: { model.setHideSensitivePaths($0) }
                ))
                Toggle("保存脱敏历史聚合", isOn: Binding(
                    get: { model.historyEnabled },
                    set: { model.setHistoryEnabled($0) }
                ))
                if !model.allows(.history) {
                    Text("历史保存需要付费 License。").font(.caption).foregroundStyle(.secondary)
                }
                Picker("历史保留期", selection: Binding(
                    get: { model.historyRetentionDays },
                    set: { model.setHistoryRetentionDays($0) }
                )) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("365 天").tag(365)
                }
                .disabled(!model.historyEnabled)
            }
            Section("语言与辅助功能") {
                Picker("界面语言", selection: Binding(
                    get: { model.selectedLanguage },
                    set: { model.setLanguage($0) }
                )) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Text("界面使用系统动态字体，并遵循 Reduce Motion、Reduce Transparency、提高对比度与 VoiceOver 设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("活动") {
                Stepper("采样间隔：\(Int(sampleInterval)) 秒", value: $sampleInterval, in: 1...60)
            }
            Section("权限") {
                LabeledContent("Full Disk Access", value: "请在系统设置查看真实状态")
                Button("打开 Full Disk Access 设置") { model.openFullDiskAccessSettings() }
                LabeledContent("Trace Helper", value: "未安装")
                LabeledContent("登录项", value: model.loginItemStatusText)
                HStack {
                    Button("启用登录项") { model.setLoginItemEnabled(true) }
                    Button("停用登录项") { model.setLoginItemEnabled(false) }
                }
            }
            Section("本地数据") {
                Button("删除本地数据", role: .destructive) { model.deleteLocalData() }
                Button("删除本地数据并准备卸载", role: .destructive) { confirmUninstall = true }
                if let report = model.uninstallReport {
                    Text(report).font(.caption)
                    Button("退出 AgentNest") { NSApplication.shared.terminate(nil) }
                }
                Text("停止扫描与采集，并删除快照、历史、Receipt 和 Keychain 凭据；不会删除已移入废纸篓的第三方文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("License") {
                LabeledContent("状态", value: model.licenseStatusText)
                Button("立即重试刷新") { model.retryLicense() }
                    .disabled(!model.licenseConfigurationAvailable)
                Button("停用这台设备", role: .destructive) { model.deactivateLicense() }
                    .disabled(!model.canDeactivateLicense)
            }
            Section("更新") {
                Button("检查更新") { model.checkForUpdates() }
                    .disabled(!model.updateAvailable || model.isMutatingEnvironment)
                Text(model.updateAvailable ? "更新包必须同时通过 HTTPS、Sparkle Ed25519 与 Apple 代码签名验证。" : "发布构建尚未配置 HTTPS appcast 与 Sparkle 公钥。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .alert("准备卸载 AgentNest？", isPresented: $confirmUninstall) {
            Button("清除并准备卸载", role: .destructive) { model.prepareForUninstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止任务，删除历史、快照、Receipt、Keychain 凭据并注销登录项。不会删除第三方 Agent 数据。")
        }
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
            Menu("导出") {
                Button("CSV") { model.exportHistoryCSV() }
                Button("PDF") { model.exportHistoryPDF() }
            }
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
