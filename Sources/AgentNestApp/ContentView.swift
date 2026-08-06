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
            sidebar
        } detail: {
            ZStack {
                DSCanvasBackground()
                Group {
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
                .id(model.selection)
                .transition(.opacity)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// 设计系统侧边栏：canvas 底、分组导航、选中态使用 accent 色（surface.selection 配方）。
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.x200) {
                Image(systemName: "bird.fill")
                    .font(.system(size: DS.IconSize.brand, weight: .medium))
                    .foregroundStyle(DS.Semantic.accentPrimary)
                Text("AgentNest")
                    .font(DS.Typeface.section)
                Spacer()
            }
            .padding(.horizontal, DS.Space.x300)
            .padding(.top, DS.Space.x250)
            .padding(.bottom, DS.Space.x200)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(model: model, item: .home)
                    sidebarDivider
                    SidebarRow(model: model, item: .agents)
                    SidebarRow(model: model, item: .skills)
                    SidebarRow(model: model, item: .storage)
                    SidebarRow(model: model, item: .activity)
                    SidebarRow(model: model, item: .history)
                    sidebarDivider
                    SidebarRow(model: model, item: .settings)
                }
                .padding(.horizontal, DS.Space.x200)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: DS.Space.x100) {
                HStack(spacing: DS.Space.x150) {
                    Circle()
                        .fill(model.hasCoreAccess ? DS.Semantic.statusPositive : DS.Semantic.statusCaution)
                        .frame(width: 6, height: 6)
                    Text(model.licenseStatusText)
                        .font(DS.Typeface.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("AgentNest 0.1.0")
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.x300)
        }
        .background(Color(nsColor: DS.Neutral.canvas))
        .frame(minWidth: 208, idealWidth: 224)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: DS.Stroke.hairline)
            .padding(.horizontal, DS.Space.x200)
            .padding(.vertical, DS.Space.x150)
    }
}

/// 侧边栏导航行：icon + label，hover/选中态，选中使用 accent 色。
private struct SidebarRow: View {
    @Bindable var model: AppModel
    let item: AppModel.Destination
    @State private var isHovering = false
    @State private var locallySelected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private var isSelected: Bool { locallySelected || model.selection == item }

    var body: some View {
        Button {
            // 交互响应优先：选中视觉本地先行（当前帧出现），模型导航状态随后提交。
            locallySelected = true
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.state)) {
                model.selection = item
            }
        } label: {
            HStack(spacing: DS.Space.x250) {
                Image(systemName: item.systemImage)
                    .font(.system(size: DS.IconSize.navigation, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? DS.Semantic.accentPrimary : Color.secondary)
                Text(model.localized(item.rawValue))
                    .font(DS.Typeface.body)
                    .foregroundStyle(isSelected ? DS.Semantic.accentPrimary : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.x250)
            .padding(.vertical, DS.Space.x200)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                    .strokeBorder(
                        isSelected ? DS.Semantic.accentPrimary.opacity(0.28) : Color.clear,
                        lineWidth: DS.Stroke.surface
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.hover)) {
                isHovering = hovering
            }
        }
        .onChange(of: controlActiveState) { _, state in
            if state != .active { isHovering = false }
        }
        .onChange(of: model.selection) { _, newValue in
            if newValue != item { locallySelected = false }
        }
    }

    private var rowFill: Color {
        if isSelected { return DS.Semantic.accentPrimary.opacity(DS.Opacity.fillStandard) }
        if isHovering, controlActiveState == .active { return Color.primary.opacity(0.05) }
        return .clear
    }
}

private struct ActivationView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            DSCanvasBackground()
            VStack(spacing: DS.Space.x400) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(DS.Semantic.accentPrimary)
                    .accessibilityHidden(true)
                Text("AgentNest")
                    .font(DS.Typeface.title)
                Text(model.licenseStatusText)
                    .font(DS.Typeface.label)
                    .foregroundStyle(.secondary)

                DSCard(padding: DS.Space.x400, cornerRadius: DS.Radius.panel) {
                    VStack(spacing: DS.Space.x250) {
                        Text("试用和设备额度由授权服务记录。本机只信任绑定设备且经过 Ed25519 验签的限时 Receipt。")
                            .font(DS.Typeface.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if model.licenseConfigurationAvailable {
                            Button("开始 7 天试用") { model.startTrial() }
                                .buttonStyle(.dsAction(.accent, size: .large))
                            Button("重试授权服务") { model.retryLicense() }
                                .buttonStyle(.dsAction())
                            HStack(spacing: DS.Space.x200) {
                                SecureField("License Key", text: $model.licenseKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 320)
                                Button("激活") { model.activate() }
                                    .buttonStyle(.dsAction(.accent))
                                    .disabled(model.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        } else {
                            Text("开发构建需配置 AGENTNEST_LICENSE_SERVER_URL 与 AGENTNEST_LICENSE_PUBLIC_KEY。")
                                .font(DS.Typeface.caption)
                                .foregroundStyle(DS.Semantic.statusCaution)
                        }
                    }
                    .frame(maxWidth: 520)
                }
                .frame(maxWidth: 560)

                HStack(spacing: DS.Space.x300) {
                    Button("隐私说明") {}
                        .buttonStyle(.dsAction())
                    Button("删除本地数据", role: .destructive) { model.deleteLocalData() }
                        .buttonStyle(.dsAction(.destructive))
                    Button("关于") {}
                        .buttonStyle(.dsAction())
                    Button("退出") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.dsAction())
                }
            }
            .padding(40)
        }
    }
}

private struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x400) {
                DSPageHeader(
                    title: model.localized(model.isScanning ? "正在分析 Agent 目录" : "发现并维护你的 Agent 环境"),
                    subtitle: model.localized("仅扫描 Agent Definition 声明和你明确添加的 Agent Home，数据只在本机分析。"),
                    systemImage: model.isScanning ? "magnifyingglass" : "bird.fill"
                ) {
                    if model.isScanning {
                        Button(model.localized(model.isStoppingScan ? "正在停止…" : "停止"), role: .cancel) {
                            model.stopScan()
                        }
                        .buttonStyle(.dsAction())
                        .disabled(model.isStoppingScan)
                    } else {
                        Button(action: model.startScan) {
                            Label("扫描", systemImage: "magnifyingglass")
                                .frame(minWidth: DS.Layout.homeActionMinWidth)
                        }
                        .buttonStyle(.dsAction(.accent, size: .large))
                        .keyboardShortcut(.defaultAction)
                    }
                }

                if let progress = model.progress, model.isScanning {
                    DSRecessed {
                        HStack(alignment: .center, spacing: DS.Space.x300) {
                            Image(systemName: "scope")
                                .font(.system(size: DS.IconSize.card, weight: .medium))
                                .foregroundStyle(DS.Semantic.accentPrimary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: DS.Space.x100) {
                                Text(model.scanPhaseTitle(progress.phase))
                                    .font(DS.Typeface.section)
                                if let location = progress.currentLocation {
                                    Text(model.displayPath(location))
                                        .font(DS.Typeface.micro)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .privacySensitive()
                                }
                            }
                            Spacer(minLength: DS.Space.x400)
                            Text(model.localized("已处理 %d 项 · %@", progress.processedCount, model.formatBytes(progress.processedBytes)))
                                .font(DS.Typeface.data)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                if let snapshot = model.snapshot {
                    SnapshotSummary(model: model, snapshot: snapshot)
                    ImpactCards(model: model, snapshot: snapshot)
                } else if !model.isScanning {
                    DSCard {
                        VStack(spacing: DS.Space.x200) {
                            Image(systemName: "tray")
                                .font(.system(size: DS.IconSize.hero, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text("尚无 Agent 结果")
                                .font(DS.Typeface.section)
                            Text("先在首页扫描。")
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let error = model.errorMessage {
                    DSRecessed {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(DS.Typeface.body)
                            .foregroundStyle(DS.Semantic.statusCaution)
                            .accessibilityLabel(model.localized("扫描状态：%@", error))
                    }
                }
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.localized("首页"))
    }
}

private struct ImpactCards: View {
    @Bindable var model: AppModel
    let snapshot: DeviceSnapshot

    var body: some View {
        Grid(horizontalSpacing: DS.Space.x300, verticalSpacing: DS.Space.x300) {
            GridRow {
                card(
                    title: "Agent",
                    value: model.localized("%d 个 Home", snapshot.homes.filter { $0.confidence == .confirmed }.count),
                    detail: model.localized(snapshot.homes.contains { $0.confidence == .possible } ? "有疑似位置待确认" : "发现结果已核验"),
                    icon: "cpu",
                    tint: DS.Chart.series01,
                    destination: .agents
                )
                card(
                    title: "Skill",
                    value: model.localized("%d 个安装", model.skillIndex?.installationCount ?? 0),
                    detail: model.skillIndex.map { model.localized("%d 个冲突 · %d 个无效", $0.conflictCount, $0.invalidCount) }
                        ?? model.localized("当前 Agent 未声明 Skill 来源"),
                    icon: "hammer",
                    tint: DS.Chart.series06,
                    destination: .skills
                )
            }
            GridRow {
                card(
                    title: model.localized("空间"),
                    value: model.formatBytes(snapshot.totalStorage.physicalBytes),
                    detail: largestStorageCategory(snapshot),
                    icon: "internaldrive",
                    tint: DS.Chart.series03,
                    destination: .storage
                )
                card(
                    title: model.localized("活动"),
                    value: activityValue,
                    detail: activityDetail,
                    icon: "waveform.path.ecg",
                    tint: DS.Chart.series02,
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
        tint: Color,
        destination: AppModel.Destination
    ) -> some View {
        Button { model.selection = destination } label: {
            HStack(alignment: .top, spacing: DS.Space.x300) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                            .fill(tint.opacity(DS.Opacity.fillSubtle))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                            .strokeBorder(tint.opacity(0.18), lineWidth: DS.Stroke.hairline)
                    )
                VStack(alignment: .leading, spacing: DS.Space.x100) {
                    Text(title).font(DS.Typeface.label).foregroundStyle(.secondary)
                    Text(value).font(DS.Typeface.title).monospacedDigit()
                    Text(detail).font(DS.Typeface.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(DS.Space.x400)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        }
        .buttonStyle(.dsCard)
        .accessibilityLabel(model.localized("%@：%@。%@", title, value, detail))
        .accessibilityHint(model.localized("打开%@详情", title))
    }

    private var activityValue: String {
        guard let cpu = model.activitySnapshot?.cpuFraction.value else { return model.localized("正在建立基线") }
        return model.localized("%@ CPU", model.formatPercent(cpu))
    }

    private var activityDetail: String {
        guard let activity = model.activitySnapshot else { return model.localized("第二个可比样本后显示速率") }
        let agents = activity.processes.filter { $0.attribution == .agent }.count
        return model.localized("%d 个已归因 Agent 进程 · %d 个证据缺口", agents, activity.droppedEvidenceCount)
    }

    private func largestStorageCategory(_ snapshot: DeviceSnapshot) -> String {
        let totals = Dictionary(grouping: snapshot.storageLedger.artifacts, by: \.category).mapValues {
            $0.reduce(UInt64(0)) { $0 &+ $1.storage.physicalBytes }
        }
        guard let largest = totals.max(by: { $0.value < $1.value }) else { return model.localized("暂无物理资源") }
        return model.localized("最大类别：%@", model.artifactCategoryTitle(largest.key))
    }
}

private struct SnapshotSummary: View {
    @Bindable var model: AppModel
    let snapshot: DeviceSnapshot

    var body: some View {
        DSCard(padding: DS.Space.x400) {
            HStack(spacing: 0) {
                metric(model.localized("Agent Home"), "\(snapshot.homes.filter { $0.confidence == .confirmed }.count)", color: DS.Chart.series01)
                metricDivider
                metric(model.localized("疑似"), "\(snapshot.homes.filter { $0.confidence == .possible }.count)", color: DS.Chart.series03)
                metricDivider
                metric(model.localized("物理占用"), model.formatBytes(snapshot.totalStorage.physicalBytes), color: DS.Chart.series02)
                metricDivider
                metric(model.localized("完整度"), model.localized(snapshot.isPartial ? "部分" : "完整"), color: snapshot.isPartial ? DS.Semantic.statusCaution : DS.Semantic.statusPositive)
            }
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: 760)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: DS.Stroke.hairline, height: 36)
            .padding(.horizontal, DS.Space.x400)
    }

    private func metric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            Text(value).font(DS.Typeface.title).monospacedDigit()
            HStack(spacing: DS.Space.x100) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(DS.Typeface.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 110, alignment: .leading)
    }
}

private struct AgentListView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                if snapshot.homes.isEmpty {
                    ContentUnavailableView("尚无 Agent 结果", systemImage: "cpu", description: Text("先在首页扫描。"))
                } else {
                List(snapshot.homes) { home in
                    VStack(alignment: .leading, spacing: DS.Space.x150) {
                        HStack(spacing: DS.Space.x200) {
                            Image(systemName: home.confidence == .confirmed ? "checkmark.circle.fill" : "questionmark.circle.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(home.confidence == .confirmed ? DS.Semantic.statusPositive : DS.Semantic.statusCaution)
                            Text(home.displayName).font(DS.Typeface.section)
                            DSBadge(
                                text: model.localized(home.confidence == .confirmed ? "已确认" : "疑似"),
                                color: home.confidence == .confirmed ? DS.Semantic.statusPositive : DS.Semantic.statusCaution
                            )
                        }
                        Text(model.displayPath(home.path)).font(DS.Typeface.caption).foregroundStyle(.secondary).privacySensitive()
                        Text(model.localized("%@ · %@", model.discoverySourceTitle(home.source), model.formatBytes(home.storage.physicalBytes)))
                            .font(DS.Typeface.micro)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        if home.confidence == .possible {
                            HStack(spacing: DS.Space.x200) {
                                Button(model.localized("确认为 %@", home.displayName)) { model.confirmCandidate(home) }
                                    .buttonStyle(.dsAction(.accent, size: .compact))
                                Button("忽略此位置", role: .destructive) { model.ignoreCandidate(home) }
                                    .buttonStyle(.dsAction(.destructive, size: .compact))
                            }
                        } else if home.source == .userConfirmed {
                            Button("撤销本机确认") { model.revokeCandidateConfirmation(home) }
                                .buttonStyle(.dsAction(size: .compact))
                        }
                    }
                    .padding(.vertical, DS.Space.x150)
                }
                .dsInstrumentList()
                }
            } else {
                DSSkeletonList(sections: [3, 4])
            }
        }
        .navigationTitle(model.localized("Agent"))
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
                                                Text(model.localized("%d 个文件 · %@", installation.fileCount, bytes(installation.totalBytes)))
                                                    .font(DS.Typeface.micro)
                                                    .monospacedDigit()
                                                Spacer()
                                                Button("编辑") { beginEdit(installation) }
                                                    .buttonStyle(.dsAction(size: .compact))
                                                Button("重命名目录") { beginRename(installation) }
                                                    .buttonStyle(.dsAction(size: .compact))
                                                Button("移到废纸篓", role: .destructive) { deleting = installation }
                                                    .buttonStyle(.dsAction(.destructive, size: .compact))
                                            }
                                            .disabled(
                                                !model.allows(.skillWrite) ||
                                                    installation.state != .valid ||
                                                    !installation.isWritable
                                            )
                                        }
                                        .padding(.vertical, 4)
                                    }
                                } label: {
                                    Text(model.localized("Variant %@ · %d 个副本", String(variant.contentHash.prefix(12)), variant.installations.count))
                                        .font(DS.Typeface.label)
                                        .monospaced()
                                }
                            }
                            if !skill.missingHomeIDs.isEmpty {
                                Button(model.localized("补齐到 %d 个缺失 Home", skill.missingHomeIDs.count)) {
                                    model.patchSkillToMissingHomes(skill)
                                }
                                .buttonStyle(.dsAction(.accent, size: .compact))
                                .disabled(!model.allows(.patch))
                            }
                        } label: {
                            HStack {
                                Text(skill.name).font(DS.Typeface.section)
                                Spacer()
                                Text(model.localized("%d 个 Variant · 缺失 %d 个 Home", skill.variants.count, skill.missingHomeIDs.count))
                                    .font(DS.Typeface.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .dsInstrumentList()
            } else if model.snapshot == nil || model.skillIndex == nil {
                DSSkeletonList(sections: [2, 3])
            } else {
                ContentUnavailableView(
                    "已扫描，但没有已适配的 Skill 来源",
                    systemImage: "hammer",
                    description: Text("已确认的 Agent Home 中没有可识别的 SKILL.md。")
                )
            }
        }
        .navigationTitle(model.localized("Skill"))
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
                .navigationTitle(model.localized("新建 Skill"))
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
                    .navigationTitle(model.localized("编辑 %@", installation.name))
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
                .navigationTitle(model.localized("重命名安装目录"))
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
            localError = model.localized("无法读取 SKILL.md：%@", String(describing: error))
        }
    }

    private func beginRename(_ installation: SkillInstallation) {
        renameText = URL(fileURLWithPath: installation.path).lastPathComponent
        renaming = installation
    }

    private func bytes(_ value: UInt64) -> String {
        model.formatBytes(value)
    }
}

/// 空间页清理候选的日期筛选预设。
private enum StorageCleanupDatePreset: String, CaseIterable, Identifiable {
    case all, today, days7, days30, days90, days180, days365, customBefore, range

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部时间"
        case .today: "今天活动"
        case .days7: "7 天未活动"
        case .days30: "30 天未活动"
        case .days90: "90 天未活动"
        case .days180: "180 天未活动"
        case .days365: "365 天未活动"
        case .customBefore: "自定义截止日期"
        case .range: "自定义日期区间"
        }
    }
}

/// 空间页派生数据（纯数据、Sendable，可在后台计算）。
private struct StorageGroupData: Identifiable, Sendable {
    enum OwnerKind: String, Sendable { case shared, home, unattributed }
    let key: String
    let ownerKind: OwnerKind
    let ownerProductName: String
    let ownerHomeIndex: Int?
    let ownerPath: String
    let category: ArtifactCategory
    let volumeDevice: UInt64
    let itemCount: Int
    let physicalBytes: UInt64
    var id: String { key }
}

private struct StorageDerived: Sendable {
    let totalPhysicalBytes: UInt64
    let groups: [StorageGroupData]
    let visibleCleanupUnits: [CleanupUnit]
    let selectableCleanupIDs: Set<String>
}

/// 纯数据派生计算（无 UI 依赖，可安全后台执行）：过滤、合计、分组、清理候选与可选项。
private func computeStorageDerived(
    snapshot: DeviceSnapshot,
    scope: StorageOwnershipScope,
    category: String,
    datePreset: StorageCleanupDatePreset,
    customCutoff: Date,
    rangeStart: Date,
    rangeEnd: Date,
    minimumSize: String,
    customMegabytes: Double,
    units: [CleanupUnit]
) -> StorageDerived {
    let ownership = StorageOwnershipFilter(scope: scope, snapshot: snapshot)
    let artifacts = snapshot.storageLedger.artifacts.filter { artifact in
        let matchesCategory = category == "*" || artifact.category.rawValue == category
        return ownership.includes(artifact) && matchesCategory
    }
    let totalPhysicalBytes = artifacts.reduce(UInt64(0)) { $0 &+ $1.storage.physicalBytes }

    let homesByID = Dictionary(uniqueKeysWithValues: snapshot.homes.map { ($0.id, $0) })
    let productNamesByID = Dictionary(uniqueKeysWithValues: snapshot.products.map { ($0.id, $0.displayName) })
    var homeDisplayIndexesByID: [PhysicalResourceIdentity: Int] = [:]
    for product in snapshot.products {
        for (index, home) in product.homes.sorted(by: {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }).enumerated() {
            homeDisplayIndexesByID[home.id] = index
        }
    }
    var groups: [String: StorageGroupData] = [:]
    for artifact in artifacts {
        let ownerKey: String
        let ownerKind: StorageGroupData.OwnerKind
        let ownerProductName: String
        let ownerHomeIndex: Int?
        let ownerPath: String
        if artifact.attribution == .shared {
            ownerKey = "shared"
            ownerKind = .shared
            ownerProductName = ""
            ownerHomeIndex = nil
            ownerPath = ""
        } else if let home = artifact.homeIDs.first.flatMap({ homesByID[$0] }) {
            ownerKey = "home:\(home.id.device):\(home.id.inode):\(home.id.kind.rawValue)"
            ownerKind = .home
            ownerProductName = productNamesByID[home.productID] ?? home.productID
            ownerHomeIndex = homeDisplayIndexesByID[home.id]
            ownerPath = home.path
        } else {
            ownerKey = "unattributed"
            ownerKind = .unattributed
            ownerProductName = ""
            ownerHomeIndex = nil
            ownerPath = ""
        }
        let key = "\(artifact.id.device)|\(ownerKey)|\(artifact.category.rawValue)"
        let current = groups[key]
        groups[key] = StorageGroupData(
            key: key,
            ownerKind: ownerKind,
            ownerProductName: ownerProductName,
            ownerHomeIndex: ownerHomeIndex,
            ownerPath: ownerPath,
            category: artifact.category,
            volumeDevice: artifact.id.device,
            itemCount: (current?.itemCount ?? 0) + 1,
            physicalBytes: (current?.physicalBytes ?? 0) &+ artifact.storage.physicalBytes
        )
    }
    let groupRows = groups.values.sorted {
        if $0.physicalBytes != $1.physicalBytes { return $0.physicalBytes > $1.physicalBytes }
        return $0.key < $1.key
    }

    let inactiveBefore: Date?
    let activityRange: ClosedRange<Date>?
    switch datePreset {
    case .all:
        inactiveBefore = nil
        activityRange = nil
    case .today:
        inactiveBefore = nil
        activityRange = Calendar.current.startOfDay(for: Date())...Date()
    case .days7, .days30, .days90, .days180, .days365:
        let days: Int
        switch datePreset {
        case .days7: days = 7
        case .days30: days = 30
        case .days90: days = 90
        case .days180: days = 180
        case .days365: days = 365
        default: days = 0
        }
        inactiveBefore = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        activityRange = nil
    case .customBefore:
        inactiveBefore = Calendar.current.startOfDay(for: customCutoff)
        activityRange = nil
    case .range:
        let start = Calendar.current.startOfDay(for: rangeStart)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: rangeEnd))?
            .addingTimeInterval(-1) ?? rangeEnd
        inactiveBefore = nil
        activityRange = min(start, end)...max(start, end)
    }
    let query = CleanupQuery(
        inactiveBefore: inactiveBefore,
        activityRange: activityRange,
        minimumPhysicalBytes: storageMinimumPhysicalBytes(size: minimumSize, customMegabytes: customMegabytes),
        risks: [],
        categories: category == "*" ? [] : [category]
    )
    let ownershipForUnits = StorageOwnershipFilter(scope: scope, snapshot: snapshot)
    let visibleCleanupUnits = CleanupPolicy().selectableUnits(units: units, query: query).filter { unit in
        ownershipForUnits.includes(unit)
    }
    let selectableCleanupIDs = Set(visibleCleanupUnits.map(\.id))

    return StorageDerived(
        totalPhysicalBytes: totalPhysicalBytes,
        groups: groupRows,
        visibleCleanupUnits: visibleCleanupUnits,
        selectableCleanupIDs: selectableCleanupIDs
    )
}

private func storageMinimumPhysicalBytes(size: String, customMegabytes: Double) -> UInt64? {
    switch size {
    case "100m": return 100 * 1_024 * 1_024
    case "500m": return 500 * 1_024 * 1_024
    case "1g": return 1_024 * 1_024 * 1_024
    case "5g": return 5 * 1_024 * 1_024 * 1_024
    case "custom":
        guard customMegabytes.isFinite, customMegabytes > 0 else { return nil }
        return UInt64(min(customMegabytes * 1_024 * 1_024, Double(Int64.max)))
    default: return nil
    }
}

private struct StorageView: View {
    @Bindable var model: AppModel
    @State private var selectedScope: StorageOwnershipScope = .all
    @State private var selectedCategory = "*"
    @State private var cleanupDatePreset: StorageCleanupDatePreset = .all
    @State private var customCutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var rangeEnd = Date()
    @State private var minimumCleanupSize = "any"
    @State private var customMinimumMegabytes = 100.0
    @State private var selectedCleanupIDs = Set<String>()
    @State private var pendingReviewUnits: [CleanupUnit] = []
    @State private var showingCleanupReview = false
    /// 派生数据缓存：过滤/分组/清理候选在后台计算，切页与筛选不阻塞主线程。
    @State private var derived: StorageDerived?

    var body: some View {
        Group {
            if let snapshot = model.snapshot, let derived {
                storageContent(snapshot: snapshot, derived: derived)
            } else {
                DSSkeletonList(sections: [3, 4, 3])
            }
        }
        .navigationTitle(model.localized("空间"))
        .task(id: deriveKey) { await recomputeDerived() }
        .sheet(isPresented: $showingCleanupReview) {
            CleanupReviewSheet(model: model, units: pendingReviewUnits) {
                model.executeCleanup(pendingReviewUnits)
                selectedCleanupIDs.subtract(pendingReviewUnits.map(\.id))
                showingCleanupReview = false
            }
        }
    }

    private func storageContent(snapshot: DeviceSnapshot, derived: StorageDerived) -> some View {
        let visibleCleanupUnits = derived.visibleCleanupUnits
        let selectableCleanupIDs = derived.selectableCleanupIDs
        let selectedVisibleUnits = visibleCleanupUnits.filter { selectedCleanupIDs.contains($0.id) }
        return List {
            Section {
                scopePicker
                Picker("类别", selection: $selectedCategory) {
                    Text("全部类别").tag("*")
                    ForEach(ArtifactCategory.allCases, id: \.rawValue) { category in
                        Text(model.artifactCategoryTitle(category)).tag(category.rawValue)
                    }
                }
            } header: {
                Text("筛选").font(DS.Typeface.section)
            }

            Section {
                HStack {
                    Text("合计").font(DS.Typeface.body)
                    Spacer()
                    Text(bytes(derived.totalPhysicalBytes))
                        .font(DS.Typeface.title)
                        .monospacedDigit()
                        .foregroundStyle(DS.Semantic.accentPrimary)
                }
                Text("每个 device/inode/type 只记一次；共享对象不会重复摊入多个 Home。")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("唯一物理占用").font(DS.Typeface.section)
            }

            Section {
                if derived.groups.isEmpty {
                    Text("当前筛选没有资源")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: DS.Space.x300)],
                        spacing: DS.Space.x300
                    ) {
                        ForEach(derived.groups) { group in
                            let owner = groupOwnerDisplay(group)
                            DSCard(padding: DS.Space.x300) {
                                VStack(alignment: .leading, spacing: DS.Space.x200) {
                                    HStack(alignment: .firstTextBaseline) {
                                        DSBadge(
                                            text: model.artifactCategoryTitle(group.category),
                                            color: DS.Semantic.accentPrimary
                                        )
                                        Spacer()
                                        Text(bytes(group.physicalBytes))
                                            .font(DS.Typeface.label)
                                            .monospacedDigit()
                                    }
                                    Text(owner.title)
                                        .font(DS.Typeface.body)
                                    if let detail = owner.detail {
                                        Text(detail)
                                            .font(DS.Typeface.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .privacySensitive()
                                    }
                                    HStack(spacing: DS.Space.x100) {
                                        Image(systemName: "internaldrive")
                                            .accessibilityHidden(true)
                                        Text(volumeTitle(device: group.volumeDevice))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(model.localized("%d 项", group.itemCount))
                                    }
                                    .font(DS.Typeface.micro)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, DS.Space.x100)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text("归属与类别").font(DS.Typeface.section)
            }

            Section {
                if let message = model.cleanupOperationMessage {
                    Text(message).font(DS.Typeface.caption).foregroundStyle(.secondary)
                }
                ForEach(model.cleanupResults) { result in
                    cleanupResultRow(result)
                }
                if model.isCleaning {
                    HStack {
                        Image(systemName: "gearshape.2")
                            .font(.system(size: DS.IconSize.navigation, weight: .medium))
                            .foregroundStyle(DS.Semantic.accentPrimary)
                            .accessibilityHidden(true)
                        Text("正在逐项执行并复验")
                        Spacer()
                        Button("停止后续清理") { model.cancelCleanup() }
                    }
                }
                if model.cleanupUnits.isEmpty {
                    Text("当前 Agent Definition 没有声明可清理目标。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("最后活动", selection: $cleanupDatePreset) {
                        ForEach(StorageCleanupDatePreset.allCases) { preset in
                            Text(model.localized(preset.title)).tag(preset)
                        }
                    }
                    if cleanupDatePreset == .customBefore {
                        DatePicker("截止日期", selection: $customCutoff, displayedComponents: .date)
                    } else if cleanupDatePreset == .range {
                        DatePicker("开始日期", selection: $rangeStart, displayedComponents: .date)
                        DatePicker("结束日期", selection: $rangeEnd, in: rangeStart..., displayedComponents: .date)
                    }
                    Picker("最小占用", selection: $minimumCleanupSize) {
                        Text("不限大小").tag("any")
                        Text("超过 100 MB").tag("100m")
                        Text("超过 500 MB").tag("500m")
                        Text("超过 1 GB").tag("1g")
                        Text("超过 5 GB").tag("5g")
                        Text("自定义").tag("custom")
                    }
                    if minimumCleanupSize == "custom" {
                        customMinimumField
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: DS.Space.x050) {
                            Text(model.localized(
                                "%d 个候选 · %@",
                                visibleCleanupUnits.count,
                                bytes(visibleCleanupUnits.reduce(0) { $0 &+ $1.storage.physicalBytes })
                            ))
                            if !selectedVisibleUnits.isEmpty {
                                Text(model.localized(
                                    "已选择 %d 项 · %@",
                                    selectedVisibleUnits.count,
                                    bytes(selectedVisibleUnits.reduce(0) { $0 &+ $1.storage.physicalBytes })
                                ))
                                    .foregroundStyle(DS.Semantic.accentPrimary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button(model.localized(
                            selectedVisibleUnits.count == visibleCleanupUnits.count && !visibleCleanupUnits.isEmpty
                                ? "取消全选"
                                : "全选"
                        )) {
                            if selectedVisibleUnits.count == visibleCleanupUnits.count {
                                selectedCleanupIDs.subtract(selectableCleanupIDs)
                            } else {
                                selectedCleanupIDs.formUnion(selectableCleanupIDs)
                            }
                        }
                        .disabled(visibleCleanupUnits.isEmpty || model.isCleaning)
                        Button("复核所选") {
                            pendingReviewUnits = selectedVisibleUnits
                            showingCleanupReview = !pendingReviewUnits.isEmpty
                        }
                        .disabled(selectedVisibleUnits.isEmpty || model.isCleaning)
                    }

                    if visibleCleanupUnits.isEmpty {
                        Text("当前筛选没有可清理项目")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleCleanupUnits) { unit in
                            cleanupUnitToggle(unit)
                        }
                    }
                }
            } header: {
                Text("安全清理候选").font(DS.Typeface.section)
            }
        }
        .dsInstrumentList()
        .onChange(of: derived.selectableCleanupIDs) { _, allowedIDs in
            selectedCleanupIDs.formIntersection(allowedIDs)
        }
        .onChange(of: snapshot.generation) { _, _ in
            if !scopeIsAvailable(in: snapshot) { selectedScope = .all }
            selectedCleanupIDs.removeAll()
            pendingReviewUnits = []
            showingCleanupReview = false
        }
    }

    private var scopePicker: some View {
        Picker("范围", selection: $selectedScope) {
            Text("全部 Agent 与 Home").tag(StorageOwnershipScope.all)
            ForEach(model.snapshot?.products ?? []) { product in
                Text(model.localized("%@ · 全部 Home", product.displayName))
                    .tag(StorageOwnershipScope.product(product.id))
                ForEach(product.homes.sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }) { home in
                    Text(model.localized(
                        "%@ · %@",
                        product.displayName,
                        model.homeDisplayTitle(
                            productID: product.id,
                            homeIdentity: home.id,
                            homePath: home.path
                        )
                    ))
                        .tag(StorageOwnershipScope.home(home.id))
                }
            }
        }
    }

    /// 拆分为独立子表达式，避免 ViewBuilder 内联格式化类型推断过慢。
    private var customMinimumField: some View {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        return TextField("自定义最小占用（MB）", value: $customMinimumMegabytes, format: format)
    }

    private func cleanupResultRow(_ result: CleanupResultRow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                Text(result.name)
                if let owner = model.cleanupResultOwnerTitle(result) {
                    Text(owner)
                        .font(DS.Typeface.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
            }
            Spacer()
            Text(model.localized(
                "%@ · %@",
                model.cleanupResultStatusTitle(result.status),
                model.cleanupResultCodeTitle(result.code)
            ))
                .font(DS.Typeface.caption)
                .foregroundStyle(result.status == .failed ? DS.Semantic.statusCritical : Color.secondary)
        }
    }

    private func cleanupUnitToggle(_ unit: CleanupUnit) -> some View {
        let selected = selectedCleanupIDs.contains(unit.id)
        return Toggle(isOn: cleanupSelectionBinding(for: unit)) {
            cleanupUnitRow(unit)
        }
        .toggleStyle(.checkbox)
        .disabled(model.isCleaning)
        .contentShape(Rectangle())
        .listRowBackground(selected ? DS.Semantic.accentPrimary.opacity(0.08) : Color.clear)
        .accessibilityLabel(model.localized(
            "%@ · %@",
            model.cleanupUnitTitle(unit),
            model.cleanupUnitOwnerTitle(unit)
        ))
        .accessibilityValue(model.localized(selected ? "已选择" : "未选择"))
        .privacySensitive()
    }

    private func cleanupUnitRow(_ unit: CleanupUnit) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                Text(model.cleanupUnitTitle(unit))
                    .font(DS.Typeface.body)
                Text(model.cleanupUnitOwnerTitle(unit))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Semantic.accentPrimary)
                    .lineLimit(1)
                    .privacySensitive()
                Text(model.artifactCategoryTitle(ArtifactCategory(definitionValue: unit.category)))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                if let date = unit.lastActivity.date {
                    Text(model.localized(
                        "最后活动：%@",
                        date.formatted(.dateTime.year().month().day().hour().minute().locale(model.appLocale))
                    ))
                        .font(DS.Typeface.micro)
                        .foregroundStyle(.secondary)
                } else {
                    Text("最后活动时间不可用")
                        .font(DS.Typeface.micro)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(bytes(unit.storage.physicalBytes))
                .font(DS.Typeface.label)
                .monospacedDigit()
        }
    }

    private func cleanupSelectionBinding(for unit: CleanupUnit) -> Binding<Bool> {
        Binding(
            get: { selectedCleanupIDs.contains(unit.id) },
            set: { selected in
                if selected { selectedCleanupIDs.insert(unit.id) }
                else { selectedCleanupIDs.remove(unit.id) }
            }
        )
    }

    private func scopeIsAvailable(in snapshot: DeviceSnapshot) -> Bool {
        switch selectedScope {
        case .all:
            true
        case .product(let productID):
            snapshot.products.contains { $0.id == productID }
        case .home(let homeID):
            snapshot.homes.contains { $0.id == homeID }
        }
    }

    private func groupOwnerDisplay(_ group: StorageGroupData) -> (title: String, detail: String?) {
        switch group.ownerKind {
        case .shared:
            return (model.localized("共享资源"), nil)
        case .unattributed:
            return (model.localized("未归属资源"), nil)
        case .home:
            let detail: String
            if model.hideSensitivePaths, let index = group.ownerHomeIndex {
                detail = model.localized("Home %d（路径已隐藏）", index + 1)
            } else {
                detail = model.displayPath(group.ownerPath)
            }
            return (group.ownerProductName, detail)
        }
    }

    /// 派生计算输入签名：任一输入变化都会触发后台重算（快照 generation、筛选参数、清理库存）。
    private var deriveKey: String {
        let unitsSignature = model.cleanupUnits
            .map {
                [
                    $0.id,
                    String($0.storage.physicalBytes),
                    $0.activity.rawValue,
                    $0.risk.rawValue,
                    $0.category,
                    $0.productID,
                    $0.name,
                    $0.path,
                    $0.homePath,
                    String($0.homeIdentity.device),
                    String($0.homeIdentity.inode),
                    $0.lastActivity.kind.rawValue,
                    String($0.lastActivity.date?.timeIntervalSince1970 ?? 0),
                    $0.method.rawValue,
                    $0.nativeID ?? "",
                ].joined(separator: ":")
            }
            .joined(separator: ",")
        return [
            "\(model.snapshot?.generation.uuidString ?? "nil")",
            String(describing: selectedScope),
            selectedCategory,
            cleanupDatePreset.rawValue,
            minimumCleanupSize,
            "\(customMinimumMegabytes)",
            "\(customCutoff.timeIntervalSince1970)",
            "\(rangeStart.timeIntervalSince1970)",
            "\(rangeEnd.timeIntervalSince1970)",
            unitsSignature,
        ].joined(separator: "|")
    }

    @MainActor
    private func recomputeDerived() async {
        guard let snapshot = model.snapshot else {
            derived = nil
            return
        }
        let cleanupUnits = model.cleanupUnits
        let scope = selectedScope
        let category = selectedCategory
        let datePreset = cleanupDatePreset
        let cutoff = customCutoff
        let start = rangeStart
        let end = rangeEnd
        let minimumSize = minimumCleanupSize
        let customMegabytes = customMinimumMegabytes
        let result = await Task.detached(priority: .utility) {
            computeStorageDerived(
                snapshot: snapshot,
                scope: scope,
                category: category,
                datePreset: datePreset,
                customCutoff: cutoff,
                rangeStart: start,
                rangeEnd: end,
                minimumSize: minimumSize,
                customMegabytes: customMegabytes,
                units: cleanupUnits
            )
        }.value
        derived = result
    }

    private func volumeTitle(device: UInt64) -> String {
        if let volume = model.activitySnapshot?.volumes.first(where: { $0.id.device == device }) {
            return model.hideSensitivePaths ? volume.name : model.localized("%@（%@）", volume.name, volume.mountPath)
        }
        return model.localized("未知卷（device %llu）", device)
    }

    private func bytes(_ value: UInt64) -> String {
        model.formatBytes(value)
    }
}

private struct CleanupReviewSheet: View {
    @Bindable var model: AppModel
    let units: [CleanupUnit]
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var estimatedBytes: UInt64 {
        units.reduce(0) { $0 &+ $1.storage.physicalBytes }
    }

    private var containsPermanentDeletion: Bool {
        units.contains { $0.method == .officialPermanentDelete }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("清理复核")
                    .font(.title2.bold())
                Text(model.localized("%d 个完整清理单元 · 预计候选占用 %@", units.count, model.formatBytes(estimatedBytes)))
                    .foregroundStyle(.secondary)
                Text(model.localized(containsPermanentDeletion
                    ? "所选项包含 Agent 官方永久删除，无法从废纸篓恢复。"
                    : "所选项将移入系统废纸篓，可在清空废纸篓前恢复。"))
                    .font(DS.Typeface.body)
                    .foregroundStyle(containsPermanentDeletion ? DS.Semantic.statusCaution : Color.secondary)
            }

            List(units) { unit in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.cleanupUnitTitle(unit))
                            .textSelection(.enabled)
                        Spacer()
                        Text(model.formatBytes(unit.storage.physicalBytes))
                            .monospacedDigit()
                    }
                    Text(model.displayPath(unit.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(model.cleanupUnitOwnerTitle(unit))
                        .font(.caption)
                        .foregroundStyle(DS.Semantic.accentPrimary)
                        .lineLimit(1)
                        .privacySensitive()
                    Text(model.localized(
                        "类别：%@ · 最后活动：%@ · 方式：%@",
                        model.artifactCategoryTitle(ArtifactCategory(definitionValue: unit.category)),
                        unit.lastActivity.date?.formatted(.dateTime.year().month().day().hour().minute().locale(model.appLocale))
                            ?? model.localized("时间不可用"),
                        model.cleanupMethodTitle(unit.method)
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.localized("完整单元包含 %d 个物理成员；保留该 Home 的配置、Skill 与未选单元。", unit.members.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .privacySensitive()
            }
            .frame(minHeight: 260)

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !model.allows(.cleanup) {
                    Text("当前 License 不包含清理。")
                        .font(DS.Typeface.caption)
                        .foregroundStyle(DS.Semantic.statusCaution)
                }
                Button("执行清理", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(units.isEmpty || model.isCleaning || !model.allows(.cleanup))
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
    }
}

private struct ActivityView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let snapshot = model.activitySnapshot {
                List {
                    Section {
                        metricRow("CPU", metric: snapshot.cpuFraction, format: .percent, meter: true)
                        metricRow("磁盘读取", metric: snapshot.diskReadBytesPerSecond, format: .bytesPerSecond)
                        metricRow("磁盘写入", metric: snapshot.diskWriteBytesPerSecond, format: .bytesPerSecond)
                        metricRow("网络下载", metric: snapshot.networkReceiveBytesPerSecond, format: .bytesPerSecond)
                        metricRow("网络上传", metric: snapshot.networkSendBytesPerSecond, format: .bytesPerSecond)
                    } header: {
                        Text("整机基础指标").font(DS.Typeface.section)
                    }
                    Section {
                        Text("首个样本只建立基线；计数器回退、睡眠或过长间隔会重新建立基线，不显示为尖峰。")
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                        Text("进程请求写入与物理设备写入不是同一指标；不可用数据不会显示为 0。")
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                        if snapshot.droppedEvidenceCount > 0 {
                            Label(model.localized("本轮有 %d 个进程证据因权限、退出或预算未采集。", snapshot.droppedEvidenceCount), systemImage: "exclamationmark.triangle")
                                .font(DS.Typeface.caption)
                                .foregroundStyle(DS.Semantic.statusCaution)
                        }
                    } header: {
                        Text("口径").font(DS.Typeface.section)
                    }
                    Section {
                        ForEach(snapshot.processes.prefix(20)) { process in
                            VStack(alignment: .leading, spacing: DS.Space.x100) {
                                HStack {
                                    Text(process.name).font(DS.Typeface.body)
                                    if process.attribution == .agent {
                                        DSBadge(text: "Agent", color: DS.Semantic.statusPositive, filled: true)
                                    } else {
                                        DSBadge(text: "macOS 与其它进程", color: .secondary)
                                    }
                                    Spacer()
                                    Text(metricText(process.cpuFraction, format: .percent)).font(DS.Typeface.label).monospacedDigit()
                                }
                                if let fraction = process.cpuFraction.value {
                                    DSSegmentedMeter(progress: fraction, color: process.attribution == .agent ? DS.Chart.series01 : DS.Chart.series04)
                                }
                                if let path = process.executablePath {
                                    Text(model.displayPath(path)).font(DS.Typeface.micro).foregroundStyle(.secondary).privacySensitive()
                                }
                                if let workingDirectory = process.workingDirectoryPath {
                                    Text(model.localized("工作目录：%@", model.displayPath(workingDirectory))).font(DS.Typeface.micro).foregroundStyle(.secondary).privacySensitive()
                                }
                                Text(model.localized(
                                    "请求读取 %@ · 请求写入 %@",
                                    metricText(process.requestedReadBytesPerSecond, format: .bytesPerSecond),
                                    metricText(process.requestedWriteBytesPerSecond, format: .bytesPerSecond)
                                ))
                                    .font(DS.Typeface.caption)
                                    .foregroundStyle(.secondary)
                                if process.attribution == .agent {
                                    DisclosureGroup("文件证据") {
                                        Text("当前打开文件")
                                            .font(DS.Typeface.label)
                                        if process.currentlyOpenFiles.isEmpty {
                                            Text("无权限、进程已退出或当前没有可见 vnode 文件。")
                                                .font(DS.Typeface.micro).foregroundStyle(.secondary)
                                        } else {
                                            ForEach(process.currentlyOpenFiles.prefix(10), id: \.path) { evidence in
                                                Text(model.displayPath(evidence.path))
                                                    .font(DS.Typeface.micro).lineLimit(1).truncationMode(.middle).privacySensitive()
                                            }
                                        }
                                        Text("最近变化")
                                            .font(DS.Typeface.label)
                                        if process.recentChanges.isEmpty {
                                            Text("未启动 Trace Helper；打开文件不会被冒充为变化事件。")
                                                .font(DS.Typeface.micro).foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(DS.Typeface.caption)
                                }
                            }
                            .padding(.vertical, DS.Space.x100)
                        }
                    } header: {
                        Text("可见进程（按 CPU）").font(DS.Typeface.section)
                    }
                    Section {
                        if snapshot.physicalDevices.isEmpty {
                            Text("物理设备指标不可用").foregroundStyle(.secondary)
                        } else {
                            ForEach(snapshot.physicalDevices) { device in
                                HStack {
                                    Text(device.name).font(DS.Typeface.body)
                                    Spacer()
                                    Text(model.localized("读 %@", metricText(device.readBytesPerSecond, format: .bytesPerSecond)))
                                        .font(DS.Typeface.caption).monospacedDigit()
                                    Text(model.localized("写 %@", metricText(device.writeBytesPerSecond, format: .bytesPerSecond)))
                                        .font(DS.Typeface.caption).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("物理设备吞吐").font(DS.Typeface.section)
                    }
                    Section {
                        ForEach(snapshot.volumes) { volume in
                            VStack(alignment: .leading, spacing: DS.Space.x100) {
                                HStack {
                                    Text(volume.name).font(DS.Typeface.body)
                                    Spacer()
                                    if let available = volume.availableBytes, let total = volume.totalBytes, total > 0 {
                                        DSDonut(fraction: Double(available) / Double(total), color: DS.Chart.series02, size: 40)
                                    } else {
                                        Text(volume.health == .unavailable ? model.localized("健康字段不可用") : model.deviceHealthTitle(volume.health))
                                            .font(DS.Typeface.caption)
                                    }
                                }
                                Text(model.displayPath(volume.mountPath)).font(DS.Typeface.micro).foregroundStyle(.secondary).privacySensitive()
                                Text(volumeDescription(volume)).font(DS.Typeface.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("挂载卷").font(DS.Typeface.section)
                    }
                }
                .dsInstrumentList()
            } else {
                ContentUnavailableView("正在建立活动基线", systemImage: "waveform.path.ecg", description: Text("第二个可比样本后显示速率。"))
            }
        }
        .navigationTitle(model.localized("活动"))
    }

    private enum MetricFormat { case percent, bytesPerSecond }

    private func metricRow(_ title: String, metric: MetricValue, format: MetricFormat, meter: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.localized(title)).font(DS.Typeface.body)
                Text(model.localized("覆盖率 %@ · 观测 %@ 秒", model.formatPercent(metric.coverage), metric.observedSeconds.formatted(.number.precision(.fractionLength(1)).locale(model.appLocale))))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if meter, let value = metric.value {
                DSSegmentedMeter(progress: value, color: DS.Chart.series01)
            }
            Spacer()
            Text(metricText(metric, format: format))
                .font(DS.Typeface.title)
                .monospacedDigit()
                .foregroundStyle(metric.value == nil ? .secondary : DS.Semantic.accentPrimary)
        }
    }

    private func metricText(_ metric: MetricValue, format: MetricFormat) -> String {
        guard let value = metric.value else {
            return model.localized(metric.availability == .partial ? "部分可用" : "不可用")
        }
        switch format {
        case .percent: return model.formatPercent(value)
        case .bytesPerSecond:
            return model.localized("%@/s", model.formatBytes(UInt64(max(0, value))))
        }
    }

    private func volumeDescription(_ volume: MountedVolume) -> String {
        let available = volume.availableBytes.map {
            model.localized("%@ 可用", model.formatBytes($0))
        } ?? model.localized("容量不可用")
        let locality = volume.isLocal.map { model.localized($0 ? "本地" : "非本地") } ?? model.localized("本地属性未知")
        let writable = volume.isWritable.map { model.localized($0 ? "可写" : "只读") } ?? model.localized("写入属性未知")
        let removable = volume.isRemovable.map { model.localized($0 ? "可移除" : "不可移除") } ?? model.localized("移除属性未知")
        return model.localized("%@ · %@ · %@ · %@", available, locality, writable, removable)
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("sampleInterval") private var sampleInterval = 3.0
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("扫描与隐私") {
                LabeledContent("默认范围", value: model.localized("Agent Definition 声明的候选目录"))
                ForEach(model.customScanPaths, id: \.self) { path in
                    HStack {
                        Text(model.displayPath(path)).lineLimit(1).truncationMode(.middle).privacySensitive()
                        Spacer()
                        Button("移除", role: .destructive) { model.removeCustomScanLocation(path) }
                            .buttonStyle(.dsAction(.destructive, size: .compact))
                    }
                }
                Button("加入 Agent Home 目录") { model.addCustomScanLocations() }
                    .buttonStyle(.dsAction())
                if !model.ignoredScanPaths.isEmpty {
                    Text("忽略位置（优先于其它扫描范围）").font(.caption.bold())
                }
                ForEach(model.ignoredScanPaths, id: \.self) { path in
                    HStack {
                        Text(model.displayPath(path)).lineLimit(1).truncationMode(.middle).privacySensitive()
                        Spacer()
                        Button("移除", role: .destructive) { model.removeIgnoredScanLocation(path) }
                            .buttonStyle(.dsAction(.destructive, size: .compact))
                    }
                }
                Button("加入忽略位置") { model.addIgnoredScanLocations() }
                    .buttonStyle(.dsAction())
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
                Stepper(model.localized("采样间隔：%d 秒", Int(sampleInterval)), value: $sampleInterval, in: 1...60)
            }
            Section("权限") {
                LabeledContent("Full Disk Access", value: model.localized("请在系统设置查看真实状态"))
                Button("打开 Full Disk Access 设置") { model.openFullDiskAccessSettings() }
                    .buttonStyle(.dsAction())
                LabeledContent("Trace Helper", value: model.localized("未安装"))
                LabeledContent("登录项", value: model.loginItemStatusText)
                HStack {
                    Button("启用登录项") { model.setLoginItemEnabled(true) }
                        .buttonStyle(.dsAction(size: .compact))
                    Button("停用登录项") { model.setLoginItemEnabled(false) }
                        .buttonStyle(.dsAction(size: .compact))
                }
            }
            Section("本地数据") {
                Button("删除本地数据", role: .destructive) { model.deleteLocalData() }
                    .buttonStyle(.dsAction(.destructive))
                Button("删除本地数据并准备卸载", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(.dsAction(.destructive))
                if let report = model.uninstallReport {
                    Text(report).font(DS.Typeface.caption)
                    Button("退出 AgentNest") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.dsAction())
                }
                Text("停止扫描与采集，并删除快照、历史、Receipt 和 Keychain 凭据；不会删除已移入废纸篓的第三方文件。")
                    .font(DS.Typeface.caption).foregroundStyle(.secondary)
            }
            Section("License") {
                LabeledContent("状态", value: model.licenseStatusText)
                Button("立即重试刷新") { model.retryLicense() }
                    .buttonStyle(.dsAction())
                    .disabled(!model.licenseConfigurationAvailable)
                Button("停用这台设备", role: .destructive) { model.deactivateLicense() }
                    .buttonStyle(.dsAction(.destructive))
                    .disabled(!model.canDeactivateLicense)
            }
            Section("更新") {
                Button("检查更新") { model.checkForUpdates() }
                    .buttonStyle(.dsAction())
                    .disabled(!model.updateAvailable || model.isMutatingEnvironment)
                Text(model.localized(model.updateAvailable ? "更新包必须同时通过 HTTPS、Sparkle Ed25519 与 Apple 代码签名验证。" : "发布构建尚未配置 HTTPS appcast 与 Sparkle 公钥。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .dsInstrumentList()
        .navigationTitle(model.localized("设置"))
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
                List {
                    if historyCPU.compactMap({ $0 }).count >= 2 {
                        Section {
                            VStack(alignment: .leading, spacing: DS.Space.x200) {
                                HStack {
                                    Text(model.localized("CPU 趋势")).font(DS.Typeface.label)
                                    Spacer()
                                    DSBadge(text: model.localized("最近 %d 个样本", historyCPU.count), color: DS.Chart.series01)
                                }
                                DSLineChart(samples: historyCPU, color: DS.Chart.series01, height: 88)
                                    .accessibilityLabel(model.localized("CPU 历史趋势折线图"))
                            }
                            .padding(.vertical, DS.Space.x100)
                        } header: {
                            Text(model.localized("趋势")).font(DS.Typeface.section)
                        }
                    }
                    Section {
                        ForEach(model.historyPoints, id: \.capturedAt) { point in
                            HStack {
                                Text(point.capturedAt, format: .dateTime.month().day().hour().minute().second())
                                    .font(DS.Typeface.data)
                                Spacer()
                                Text(point.cpuFraction.map { model.formatPercent($0) } ?? model.localized("CPU 不可用"))
                                    .font(DS.Typeface.label)
                                    .monospacedDigit()
                                Text(model.localized("覆盖率 %@", model.formatPercent(point.coverage)))
                                    .font(DS.Typeface.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(model.localized("脱敏样本")).font(DS.Typeface.section)
                    }
                }
                .dsInstrumentList()
            }
        }
        .navigationTitle(model.localized("历史"))
        .toolbar {
            Menu("导出") {
                Button("CSV") { model.exportHistoryCSV() }
                Button("PDF") { model.exportHistoryPDF() }
            }
            .disabled(!model.historyEnabled || !model.allows(.export))
        }
        .task { await model.refreshHistory() }
    }

    private var historyCPU: [Double?] {
        model.historyPoints.map(\.cpuFraction)
    }
}
