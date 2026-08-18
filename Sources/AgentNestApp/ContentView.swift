import AgentNestCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    case .agents:
                        if let id = model.selectedAgentID, let product = model.activeAgentProduct(withID: id) {
                            if let homeID = model.selectedAgentHomeID,
                               let home = model.agentHome(withID: homeID),
                               home.productID == product.id {
                                AgentHomeDetailView(model: model, home: home)
                            } else {
                                AgentProductDetailView(model: model, productID: product.id)
                            }
                        } else {
                            AgentListView(model: model)
                        }
                    case .market: MarketView(model: model)
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
        .overlay {
            // Skill 同步/冲突解决：全窗口完整 Dialog（遮罩覆盖含侧边栏的整个窗口，点击外部关闭）。
            if let dialog = model.skillDialog {
                SkillDialogOverlay(model: model, dialog: dialog)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.state), value: model.skillDialog)
        .task {
            // 打开程序后后台轻量扫描已安装 Agent 版本；不阻塞窗口与首次完整扫描。
            model.startBackgroundInstalledVersionScanIfNeeded()
        }
    }

    /// 设计系统侧边栏：canvas 底、分组导航、选中态使用 accent 色（surface.selection 配方）。
    /// 不再放置品牌标题块：导航行直接从顶部开始，与窗口融合。
    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(model: model, item: .home)
                    sidebarDivider
                    SidebarRow(model: model, item: .agents)
                    SidebarRow(model: model, item: .market)
                    SidebarRow(model: model, item: .skills)
                    SidebarRow(model: model, item: .storage)
                    SidebarRow(model: model, item: .activity)
                    SidebarRow(model: model, item: .history)
                    sidebarDivider
                    SidebarRow(model: model, item: .settings)
                }
                .padding(.horizontal, DS.Space.x200)
                .padding(.top, DS.Layout.windowChromeTopInset)
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
                Text("v0.1.0")
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
            // 重新进入 Agent 页时回到列表（退出详情）。
            if item == .agents {
                model.selectedAgentID = nil
                model.selectedAgentHomeID = nil
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
                if item == .market, model.marketUpdateCount > 0 {
                    updateBadge
                }
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

    private var updateBadge: some View {
        let count = model.marketUpdateCount
        return Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
            .frame(minWidth: 16, minHeight: 16)
            .background(Circle().fill(DS.Semantic.statusCritical))
            .accessibilityLabel(model.localized("%d 个 Agent 可更新", count))
    }

    private var rowFill: Color {
        if isSelected { return DS.Semantic.accentPrimary.opacity(DS.Opacity.fillStandard) }
        if isHovering, controlActiveState == .active { return Color.primary.opacity(0.05) }
        return .clear
    }
}

private struct HomeView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 本次扫描开始时刻（底部栏已用时计时用，随 generation 重置）。
    @State private var scanStartedAt: Date?
    /// 首页稳定态派生数据：按 snapshot generation 只计算一次，避免卡片反复遍历存储账本。
    @State private var storageDerived: HomeStorageDerived?

    private var storageDeriveKey: UUID? { model.snapshot?.generation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x400) {
                pageIdentity

                if let progress = model.progress, model.isScanning {
                    HomeDiscoveryView(model: model, progress: progress)
                }

                // 扫描中只呈现发现界面；扫描完成后进入「环境总览台」稳定态。
                if !model.isScanning {
                    if let snapshot = model.snapshot {
                        HomeOverview(model: model, snapshot: snapshot, storageDerived: storageDerived)
                    } else {
                        HomeEmptyState(model: model)
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
            .frame(maxWidth: model.isScanning ? DS.Layout.discoveryPageMaxWidth : DS.Layout.homeOverviewMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isScanning, let progress = model.progress {
                scanProgressBar(progress)
            }
        }
        .onAppear {
            model.autoStartInitialScanIfNeeded()
        }
        .onChange(of: model.progress?.generation) { _, newGeneration in
            if newGeneration != nil { scanStartedAt = Date() }
        }
        .task(id: storageDeriveKey) { await recomputeStorageDerived() }
    }

    @MainActor
    private func recomputeStorageDerived() async {
        guard model.isScanning == false, let snapshot = model.snapshot else {
            storageDerived = nil
            return
        }
        let generation = snapshot.generation
        let value = await Task.detached(priority: .utility) {
            computeHomeStorageDerived(snapshot: snapshot)
        }.value
        guard model.snapshot?.generation == generation else { return }
        storageDerived = value
    }

    /// 页面身份区：大标题 + 按状态定制的信息行，主操作右对齐在标题基线行。
    private var pageIdentity: some View {
        DSPageIdentity(
            title: model.localized(model.isScanning ? "正在发现本机 Agent 环境" : "发现并维护你的 Agent 环境"),
            glyph: model.isScanning ? "magnifyingglass" : "bird",
            detail: identityDetail
        ) {
            if model.isScanning {
                Button(model.localized(model.isStoppingScan ? "正在停止…" : "停止"), role: .cancel) {
                    model.stopScan()
                }
                .buttonStyle(.dsAction())
                .disabled(model.isStoppingScan)
            } else {
                Button(action: model.startScan) {
                    Label(model.localized("扫描"), systemImage: "magnifyingglass")
                        .labelStyle(DSPrimaryLabelStyle())
                        .frame(minWidth: DS.Layout.homeActionMinWidth)
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// 信息行按状态切换：扫描中显示当前阶段；空闲时显示上次扫描时间与覆盖状态。
    private var identityDetail: String? {
        if model.isScanning {
            guard let progress = model.progress else { return nil }
            return model.scanPhaseTitle(progress.phase)
        }
        guard let snapshot = model.snapshot else { return nil }
        let scanned = snapshot.createdAt.formatted(.relative(presentation: .named).locale(model.appLocale))
        let base = model.localized("上次扫描 %@", scanned)
        return snapshot.isPartial ? base + " · " + model.localized("部分扫描") : base
    }

    /// 扫描期间钉在底部的进度栏：当前位置（对账阶段改为阶段名 + spinner）+ 已处理项数/字节 +
    /// 已用时（每秒跳动）；顶缘为不确定扫描条（仅扫描态存在、Reduce Motion 下静态化，DESIGN.md §2 例外）。
    private func scanProgressBar(_ progress: ScanProgress) -> some View {
        HStack(spacing: DS.Space.x300) {
            Image(systemName: "scope")
                .font(.system(size: DS.IconSize.card, weight: .medium))
                .foregroundStyle(DS.Semantic.accentPrimary)
                .accessibilityHidden(true)
            if progress.phase == .reconciling {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(model.scanPhaseTitle(progress.phase))
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
            } else if let location = progress.currentLocation {
                Text(model.displayPath(location))
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive()
            }
            Spacer(minLength: DS.Space.x400)
            Text(model.localized("已处理 %d 项 · %@", progress.processedCount, model.formatBytes(progress.processedBytes)))
                .font(DS.Typeface.data)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.sample), value: progress.processedCount)
            scanElapsedText
        }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .background(Color(nsColor: DS.Neutral.canvas))
        .overlay(alignment: .top) {
            DSIndeterminateScanBar()
        }
    }

    /// 已用时：扫描开始起每秒跳动的真实计时（等宽数字）。
    private var scanElapsedText: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(scanStartedAt ?? context.date))
            Text(model.localized("%d 秒", seconds))
                .font(DS.Typeface.data)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

// MARK: - 首页稳定态（环境总览台）

/// 稳定态 = 扫描拓扑的落定形态：读数带 → Agent 环境图 → 管理入口 → 信任行。
/// 全部静态排版，动效仅 hover；无材质、无渐变，阴影仅入口卡保留原有单层。
private struct HomeOverview: View {
    let model: AppModel
    let snapshot: DeviceSnapshot
    let storageDerived: HomeStorageDerived?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x450) {
            HomeReadingsStrip(model: model, snapshot: snapshot, storageDerived: storageDerived)
            HomeEnvironmentMap(model: model, storageDerived: storageDerived)
            HomeManagementTiles(model: model, snapshot: snapshot, storageDerived: storageDerived)
            HomeTrustFooter(model: model)
        }
        .accessibilityElement(children: .contain)
    }
}

/// 首页稳定态中只依赖存储账本的派生数据，后台计算一次并随 generation 缓存。
private struct HomeStorageSlice: Sendable {
    let category: ArtifactCategory
    let bytes: UInt64
}

private struct HomeStorageDerived: Sendable {
    let slices: [HomeStorageSlice]
    let largestCategory: ArtifactCategory?
    let totalBytesByProduct: [String: UInt64]
}

private func computeHomeStorageDerived(snapshot: DeviceSnapshot) -> HomeStorageDerived {
    let slices = Dictionary(grouping: snapshot.storageLedger.artifacts, by: \.category)
        .map { HomeStorageSlice(category: $0.key, bytes: $0.value.reduce(UInt64(0)) { $0 &+ $1.storage.physicalBytes }) }
        .filter { $0.bytes > 0 }
        .sorted { $0.bytes > $1.bytes }
        .prefix(5)
        .map { $0 }

    var productByHomeID: [PhysicalResourceIdentity: String] = [:]
    for home in snapshot.homes {
        productByHomeID[home.id] = home.productID
    }
    var seenArtifactsByProduct: [String: Set<PhysicalResourceIdentity>] = [:]
    var totalBytesByProduct: [String: UInt64] = [:]
    for artifact in snapshot.storageLedger.artifacts {
        let productIDs = Set(artifact.homeIDs.compactMap { productByHomeID[$0] })
        for productID in productIDs
        where seenArtifactsByProduct[productID, default: []].insert(artifact.id).inserted {
            totalBytesByProduct[productID, default: 0] &+= artifact.storage.physicalBytes
        }
    }
    return HomeStorageDerived(
        slices: slices,
        largestCategory: slices.first?.category,
        totalBytesByProduct: totalBytesByProduct
    )
}

/// 读数带：四个等宽仪表卡，左侧文字信息、右侧图表，横向构图。
/// 使用 LazyVGrid 自适应四列，窄窗口自动回落到 2 列。
private struct HomeReadingsStrip: View {
    let model: AppModel
    let snapshot: DeviceSnapshot
    let storageDerived: HomeStorageDerived?

    private enum Metric: CaseIterable, Hashable {
        case confirmed, storage, skills, possible
    }

    private var confirmed: Int { snapshot.homes.filter { $0.confidence == .confirmed }.count }
    private var possible: Int { snapshot.homes.filter { $0.confidence == .possible }.count }
    private var totalHomes: Int { snapshot.homes.count }

    private var confirmedFraction: Double {
        totalHomes > 0 ? Double(confirmed) / Double(totalHomes) : 0
    }

    private var possibleFraction: Double {
        totalHomes > 0 ? Double(possible) / Double(totalHomes) : 0
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(minimum: DS.Layout.homeReadingTileMinWidth, maximum: DS.Layout.homeReadingTileMaxWidth),
                spacing: DS.Space.x300
            )],
            alignment: .center,
            spacing: DS.Space.x300
        ) {
            ForEach(Metric.allCases, id: \.self) { metric in
                tile(for: metric)
            }
        }
    }

    // MARK: 指标内容

    private func title(for metric: Metric) -> String {
        switch metric {
        case .confirmed: return model.localized("已确认 Home")
        case .storage: return model.localized("物理占用")
        case .skills: return model.localized("Skill 安装")
        case .possible: return model.localized("疑似位置")
        }
    }

    private func value(for metric: Metric) -> String {
        switch metric {
        case .confirmed: return "\(confirmed)"
        case .storage: return model.formatBytes(snapshot.totalStorage.physicalBytes)
        case .skills: return model.skillIndex.map { "\($0.installationCount)" } ?? "—"
        case .possible: return "\(possible)"
        }
    }

    private func valueColor(for metric: Metric) -> Color {
        switch metric {
        case .confirmed: return DS.Semantic.accentPrimary
        case .storage: return Color.primary
        case .skills: return skillColor
        case .possible: return possible > 0 ? DS.Semantic.statusCaution : Color.primary
        }
    }

    private func annotation(for metric: Metric) -> String {
        switch metric {
        case .confirmed: return model.localized("%d 个 Home", totalHomes)
        case .storage: return storageAnnotation
        case .skills: return skillAnnotation
        case .possible:
            return possible > 0
                ? model.localized("%d 个 Home · %d 个疑似", totalHomes, possible)
                : model.localized("发现结果已核验")
        }
    }

    @ViewBuilder
    private func chart(for metric: Metric) -> some View {
        switch metric {
        case .confirmed:
            DSDonut(fraction: confirmedFraction, color: DS.Semantic.statusPositive, size: 44)
        case .storage:
            HomeStorageCategoryBars(slices: storageDerived?.slices ?? [])
        case .skills:
            HomeSkillMeter(fraction: skillHealthFraction, color: skillColor)
        case .possible:
            DSDonut(
                fraction: possibleFraction,
                color: possible > 0 ? DS.Semantic.statusCaution : Color.secondary,
                size: 44
            )
        }
    }

    private func glyph(for metric: Metric) -> String {
        switch metric {
        case .confirmed: return "checkmark.seal.fill"
        case .storage: return "internaldrive.fill"
        case .skills: return "hammer.fill"
        case .possible: return "exclamationmark.triangle.fill"
        }
    }

    private func tile(for metric: Metric) -> some View {
        HomeMetricTile(
            glyph: glyph(for: metric),
            title: title(for: metric),
            value: value(for: metric),
            valueColor: valueColor(for: metric),
            annotation: annotation(for: metric)
        ) {
            chart(for: metric)
        }
    }

    // MARK: 辅助数据

    private var storageAnnotation: String {
        if let category = storageDerived?.largestCategory {
            return model.localized("最大类别：%@", model.artifactCategoryTitle(category))
        }
        return snapshot.storageLedger.artifacts.isEmpty ? model.localized("暂无物理资源") : " "
    }

    private var skillAnnotation: String {
        guard let index = model.skillIndex else { return model.localized("尚未索引") }
        if index.installationCount == 0 { return model.localized("当前 Agent 未声明 Skill 来源") }
        if index.conflictCount + index.invalidCount == 0 { return model.localized("无冲突") }
        return model.localized("%d 个冲突 · %d 个无效", index.conflictCount, index.invalidCount)
    }

    private var skillColor: Color {
        guard let index = model.skillIndex else { return Color.secondary }
        return index.conflictCount + index.invalidCount > 0
            ? DS.Semantic.statusCaution
            : DS.Semantic.accentSecondary
    }

    private var skillHealthFraction: Double {
        guard let index = model.skillIndex, index.installationCount > 0 else { return 0 }
        let valid = max(0, index.installationCount - index.invalidCount)
        return min(max(Double(valid) / Double(index.installationCount), 0), 1)
    }
}

/// 首页读数仪表卡：左侧为标签 + 数值 + 注脚，右侧为统一尺寸的辅助图表；
/// raised 表面与等宽网格让四个指标既独立成块，又保持同一水平重心。
private struct HomeMetricTile<Chart: View>: View {
    let glyph: String
    let title: String
    let value: String
    let valueColor: Color
    let annotation: String
    let chart: Chart

    init(
        glyph: String,
        title: String,
        value: String,
        valueColor: Color,
        annotation: String,
        @ViewBuilder chart: () -> Chart
    ) {
        self.glyph = glyph
        self.title = title
        self.value = value
        self.valueColor = valueColor
        self.annotation = annotation
        self.chart = chart()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.x300) {
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                HStack(spacing: DS.Space.x150) {
                    Image(systemName: glyph)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(valueColor)
                        .frame(width: 13)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(DS.Typeface.label)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(DS.Typeface.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(annotation)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: DS.Space.x250)
            chart
                .frame(
                    width: DS.Layout.homeReadingChartWidth,
                    height: DS.Layout.homeReadingChartHeight,
                    alignment: .center
                )
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Space.x300)
        .padding(.vertical, DS.Space.x250)
        .frame(maxWidth: .infinity, minHeight: DS.Layout.homeReadingTileHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(Color(nsColor: DS.Neutral.raised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}

/// 物理占用类别微柱图：前 5 类按字节高度绘制，颜色沿用 Agent 类别系列色。
/// 切片由 HomeStorageDerived 预计算注入，不在 body 中重复遍历账本。
private struct HomeStorageCategoryBars: View {
    let slices: [HomeStorageSlice]

    private var maxBytes: UInt64 {
        max(slices.first?.bytes ?? 1, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if slices.isEmpty {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(DS.Opacity.fillQuiet))
                        .frame(width: 9, height: 6)
                }
            } else {
                ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                    let fraction = min(max(Double(slice.bytes) / Double(maxBytes), 0), 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AgentCategoryPalette.color(for: slice.category))
                        .frame(width: 9, height: max(8, 38 * CGFloat(fraction)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Skill 安装健康度：8 段纵向仪表，按有效安装占比点亮。
private struct HomeSkillMeter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                let active = Double(index) < (min(max(fraction, 0), 1) * 8).rounded()
                Capsule(style: .continuous)
                    .fill(active ? color : Color.primary.opacity(0.10))
                    .frame(width: 5, height: 8 + CGFloat(index) * 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Agent 环境图：按产品的紧凑档案卡网格（产品级聚合）——品牌图标 + 产品名 + 信心点阵 +
/// 合计占用；单个产品即一张小卡、不撑满整行；Home 级明细在 Agent 页，两页职责区分。
private struct HomeEnvironmentMap: View {
    let model: AppModel
    let storageDerived: HomeStorageDerived?

    private var products: [AgentProduct] {
        model.activeAgentProducts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x300) {
                Text(model.localized("Agent 环境"))
                    .font(DS.Typeface.title)
                Spacer(minLength: DS.Space.x300)
                Text(model.localized("%d 个产品 · 只读分析", products.count))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, DS.Space.x300)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: DS.Space.x300)],
                alignment: .leading,
                spacing: DS.Space.x300
            ) {
                ForEach(products) { product in
                    HomeProductCard(
                        model: model,
                        product: product,
                        totalBytes: storageDerived?.totalBytesByProduct[product.id] ?? 0
                    )
                }
            }
        }
    }
}

/// 产品档案卡：紧凑小卡——首行品牌图标 + 产品名 + 右侧合计占用（type.title 等宽），
/// 次行信心点阵（每点一个 Home，绿=已核验/琥珀=疑似）+ 文字计数；hover 出 chevron，点击 → Agent 页。
private struct HomeProductCard: View {
    let model: AppModel
    let product: AgentProduct
    let totalBytes: UInt64
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var homes: [AgentHome] {
        product.homes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var possibleCount: Int {
        homes.filter { $0.confidence == .possible }.count
    }

    private var installation: AgentInstallation? {
        model.effectiveInstallation(for: product.id)
    }

    private var countLine: String {
        if possibleCount == 0 {
            return model.localized("%d 个 Home", homes.count)
        }
        return model.localized("%d 个 Home · %d 个疑似", homes.count, possibleCount)
    }

    private var installationLine: String {
        guard let installation else { return model.localized("未检测到生效可执行文件") }
        return model.localized("生效：%@", model.displayPath(installation.path))
    }

    var body: some View {
        Button {
            model.selection = .agents
            model.selectedAgentID = product.id
            model.selectedAgentHomeID = nil
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                HStack(spacing: DS.Space.x250) {
                    HomeBrandIcon(productID: product.id, size: 24)
                    Text(product.displayName)
                        .font(DS.Typeface.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.x200)
                    Text(model.formatBytes(totalBytes))
                        .font(DS.Typeface.title)
                        .monospacedDigit()
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                HStack(spacing: DS.Space.x100) {
                    HStack(spacing: 3) {
                        ForEach(homes) { home in
                            Circle()
                                .fill(home.confidence == .possible ? DS.Semantic.statusCaution : DS.Semantic.statusPositive)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(countLine)
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.leading, DS.Layout.homeProductCardContentInset)
                HStack(spacing: DS.Space.x100) {
                    Image(systemName: installation == nil ? "exclamationmark.triangle" : "terminal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(installation == nil ? DS.Semantic.statusCaution : DS.Semantic.statusPositive)
                    Text(installationLine)
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, DS.Layout.homeProductCardContentInset)
            }
            .padding(.horizontal, DS.Space.x300)
            .padding(.vertical, DS.Space.x250)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.dsCard)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(model.localized("%@ · %@", product.displayName, countLine + " · " + model.formatBytes(totalBytes)))
        .accessibilityHint(model.localized("打开%@详情", model.localized("Agent")))
    }
}



/// 管理入口：一行四个安静入口卡——裸色符号 + 标题 + 单行状态，chevron 仅 hover 出现。
private struct HomeManagementTiles: View {
    let model: AppModel
    let snapshot: DeviceSnapshot
    let storageDerived: HomeStorageDerived?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Text(model.localized("维护"))
                .font(DS.Typeface.title)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: DS.Layout.homeManagementTileMinWidth, maximum: 400), spacing: DS.Space.x300)],
                alignment: .leading,
                spacing: DS.Space.x300
            ) {
                HomeManagementTile(
                    model: model,
                    title: model.localized("Agent"),
                    glyph: "cpu",
                    tint: DS.Chart.series01,
                    status: agentStatus,
                    destination: .agents
                )
                HomeManagementTile(
                    model: model,
                    title: model.localized("Skill"),
                    glyph: "hammer",
                    tint: DS.Chart.series06,
                    status: skillStatus,
                    destination: .skills
                )
                HomeManagementTile(
                    model: model,
                    title: model.localized("空间"),
                    glyph: "internaldrive",
                    tint: DS.Chart.series03,
                    status: storageStatus,
                    destination: .storage
                )
                HomeManagementTile(
                    model: model,
                    title: model.localized("活动"),
                    glyph: "waveform.path.ecg",
                    tint: DS.Chart.series02,
                    status: activityStatus,
                    destination: .activity
                )
            }
        }
    }

    private var agentStatus: String {
        let sources = Set(snapshot.homes.map(\.source)).count
        let possible = snapshot.homes.filter { $0.confidence == .possible }.count
        if possible == 0 {
            return model.localized("%d 个来源 · 全部核验", sources)
        }
        return model.localized("%d 个来源 · %d 个疑似", sources, possible)
    }

    private var skillStatus: String {
        guard let index = model.skillIndex else { return model.localized("尚未索引") }
        if index.installationCount == 0 { return model.localized("当前 Agent 未声明 Skill 来源") }
        if index.conflictCount + index.invalidCount == 0 { return model.localized("无冲突") }
        return model.localized("%d 个冲突 · %d 个无效", index.conflictCount, index.invalidCount)
    }

    private var storageStatus: String {
        if let category = storageDerived?.largestCategory {
            return model.localized("最大类别：%@", model.artifactCategoryTitle(category))
        }
        return snapshot.storageLedger.artifacts.isEmpty ? model.localized("暂无物理资源") : " "
    }

    private var activityStatus: String {
        guard let activity = model.activitySnapshot else { return model.localized("正在建立基线") }
        let agents = activity.processes.filter { $0.attribution == .agent }.count
        return model.localized("%d 个已归因进程", agents)
    }
}

/// 管理入口卡：裸色符号（无图标底座）+ 标题 + 单行状态；dsCard 表面，chevron 仅 hover 出现。
private struct HomeManagementTile: View {
    let model: AppModel
    let title: String
    let glyph: String
    let tint: Color
    let status: String
    let destination: AppModel.Destination
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { model.selection = destination } label: {
            HStack(spacing: DS.Space.x300) {
                Image(systemName: glyph)
                    .font(.system(size: DS.IconSize.card, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.x050) {
                    Text(title)
                        .font(DS.Typeface.label)
                        .foregroundStyle(.secondary)
                    Text(status)
                        .font(DS.Typeface.body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.x200)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(DS.Space.x400)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }
        .buttonStyle(.dsCard)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(model.localized("%@：%@", title, status))
        .accessibilityHint(model.localized("打开%@详情", title))
    }
}

/// 信任行：与发现态呼应的安静事实行，顶部分隔线。
private struct HomeTrustFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: DS.Space.x200) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.localized("本机分析") + " · " + model.localized("只读元数据") + " · " + model.localized("不执行清理"))
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.Space.x300)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
                .frame(height: DS.Stroke.hairline)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 空态：无卡片容器，居中裸符号 + 标题 + 指引（扫描主操作在身份区右上角）。
private struct HomeEmptyState: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: DS.Space.x250) {
            Image(systemName: "bird")
                .font(.system(size: DS.IconSize.hero, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(model.localized("尚未建立 Agent 环境档案"))
                .font(DS.Typeface.section)
            Text(model.localized("点击右上角「扫描」开始发现本机 Agent 环境。"))
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}


private struct AgentListView: View {
    @Bindable var model: AppModel
    @State private var derived: AgentCardDerived?
    @State private var searchText = ""

    private var deriveKey: UUID? { model.snapshot?.generation }

    private var filteredProducts: [AgentProduct] {
        guard model.snapshot != nil else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return model.activeAgentProducts }
        return model.activeAgentProducts.filter { product in
            let installationPath = model.effectiveInstallation(for: product.id)?.path ?? ""
            let candidates = [product.displayName, product.id, installationPath]
                + product.homes.map(\.path)
            return candidates.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var agentIdentity: some View {
        DSPageIdentity(
            title: model.localized("Agent"),
            glyph: "cpu",
            detail: agentIdentityDetail
        ) {
            EmptyView()
        }
    }

    private var agentIdentityDetail: String? {
        guard model.snapshot != nil else { return nil }
        return model.localized(
            "%d 个生效 · %d 个 Agent 产品 · %d 个 Home",
            model.effectiveAgentCount,
            model.activeAgentProducts.count,
            model.activeAgentProducts.reduce(0) { $0 + $1.homes.count }
        )
    }

    var body: some View {
        Group {
            if model.snapshot != nil {
                if model.activeAgentProducts.isEmpty {
                    ContentUnavailableView(
                        model.localized("未检测到生效的 Agent 可执行文件"),
                        systemImage: "cpu",
                        description: Text(model.localized("Agent 列表只显示本机可执行文件真实生效的产品。"))
                    )
                } else if filteredProducts.isEmpty {
                    ContentUnavailableView(
                        model.localized("没有匹配的 Agent"),
                        systemImage: "magnifyingglass",
                        description: Text(model.localized("换个关键词试试。"))
                    )
                } else {
                    agentCardGrid(products: filteredProducts)
                }
            } else {
                AgentCardGridSkeleton()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            agentHeader
        }
        .task(id: deriveKey) { await recomputeDerived() }
    }

    private var agentHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            agentIdentity
            searchField
        }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .frame(maxWidth: DS.Layout.pageMaxWidth)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.x200) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(model.localized("搜索 Agent"), text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.Typeface.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.localized("清空搜索"))
            }
        }
        .padding(.horizontal, DS.Space.x250)
        .frame(height: DS.Layout.agentSearchHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
        .padding(.leading, DS.Layout.pageIdentityContentInset)
    }

    private func agentCardGrid(products: [AgentProduct]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: DS.Layout.agentCardColumnMinWidth, maximum: DS.Layout.agentCardColumnMaxWidth), spacing: DS.Space.x300)],
                alignment: .leading,
                spacing: DS.Space.x300
            ) {
                ForEach(products) { product in
                    AgentProductCard(
                        model: model,
                        product: product,
                        derived: derived?.productsByID[product.id]
                    )
                }
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    @MainActor
    private func recomputeDerived() async {
        guard let snapshot = model.snapshot else { return }
        let generation = snapshot.generation
        let value = await Task.detached(priority: .utility) {
            computeAgentCardDerived(snapshot: snapshot)
        }.value
        guard model.snapshot?.generation == generation else { return }
        derived = value
    }
}

private enum AgentCategoryPalette {
    static func color(for category: ArtifactCategory) -> Color {
        switch category {
        case .sessions: return DS.Chart.series01
        case .logs: return DS.Chart.series02
        case .cache: return DS.Chart.series03
        case .configuration: return DS.Chart.series04
        case .runtime: return DS.Chart.series05
        case .skill: return DS.Chart.series06
        case .browser: return DS.Chart.series07
        case .database: return DS.Chart.series08
        case .unattributed: return Color.secondary.opacity(0.55)
        }
    }
}

private struct AgentCategorySlice: Sendable {
    let category: ArtifactCategory
    let bytes: UInt64
    let itemCount: Int
}

private struct AgentProductDerived: Sendable {
    let slices: [AgentCategorySlice]
    let storage: StorageMeasurement
}

private struct AgentCardDerived: Sendable {
    let slicesByHome: [PhysicalResourceIdentity: [AgentCategorySlice]]
    let productsByID: [String: AgentProductDerived]
}

/// 纯数据派生（无 UI 依赖，后台执行）：Home 切片供详情页；
/// 产品切片与产品唯一物理占用供 Agent 产品卡。多 Home 共享资源按 device/inode 只计一次。
private func computeAgentCardDerived(snapshot: DeviceSnapshot) -> AgentCardDerived {
    var homeAccum: [PhysicalResourceIdentity: [ArtifactCategory: (bytes: UInt64, items: Int)]] = [:]
    var productAccum: [String: [ArtifactCategory: (bytes: UInt64, items: Int)]] = [:]
    var productItemIDs: [String: Set<PhysicalResourceIdentity>] = [:]
    var productStorage: [String: StorageMeasurement] = [:]
    var homeProductIDs: [PhysicalResourceIdentity: String] = [:]
    for home in snapshot.homes {
        homeProductIDs[home.id] = home.productID
    }

    for artifact in snapshot.storageLedger.artifacts {
        var productIDs = Set<String>()
        for homeID in artifact.homeIDs {
            var homeSlot = homeAccum[homeID, default: [:]][artifact.category] ?? (bytes: 0, items: 0)
            homeSlot.bytes &+= artifact.storage.physicalBytes
            homeSlot.items += 1
            homeAccum[homeID, default: [:]][artifact.category] = homeSlot
            if let productID = homeProductIDs[homeID] {
                productIDs.insert(productID)
            }
        }
        for productID in productIDs where productItemIDs[productID, default: []].insert(artifact.id).inserted {
            var productSlot = productAccum[productID, default: [:]][artifact.category] ?? (bytes: 0, items: 0)
            productSlot.bytes &+= artifact.storage.physicalBytes
            productSlot.items += 1
            productAccum[productID, default: [:]][artifact.category] = productSlot
            let current = productStorage[productID] ?? StorageMeasurement()
            productStorage[productID] = StorageMeasurement(
                logicalBytes: current.logicalBytes &+ artifact.storage.logicalBytes,
                physicalBytes: current.physicalBytes &+ artifact.storage.physicalBytes,
                itemCount: current.itemCount + 1
            )
        }
    }

    var slicesByHome: [PhysicalResourceIdentity: [AgentCategorySlice]] = [:]
    for (homeID, byCategory) in homeAccum {
        slicesByHome[homeID] = byCategory
            .filter { $0.value.bytes > 0 }
            .map { AgentCategorySlice(category: $0.key, bytes: $0.value.bytes, itemCount: $0.value.items) }
            .sorted { $0.bytes > $1.bytes }
    }

    var productsByID: [String: AgentProductDerived] = [:]
    for (productID, byCategory) in productAccum {
        productsByID[productID] = AgentProductDerived(
            slices: byCategory
                .filter { $0.value.bytes > 0 }
                .map { AgentCategorySlice(category: $0.key, bytes: $0.value.bytes, itemCount: $0.value.items) }
                .sorted { $0.bytes > $1.bytes },
            storage: productStorage[productID] ?? StorageMeasurement()
        )
    }
    return AgentCardDerived(slicesByHome: slicesByHome, productsByID: productsByID)
}

/// Agent 产品卡：沿用原 Agent 档案卡视觉，但身份是生效产品/可执行文件，Home 只作配置计数。
private struct AgentProductCard: View {
    let model: AppModel
    let product: AgentProduct
    let derived: AgentProductDerived?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var homes: [AgentHome] {
        product.homes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var installation: AgentInstallation? {
        model.effectiveInstallation(for: product.id)
    }

    private var isEffective: Bool { installation != nil }

    private var productName: String { product.displayName }
    private var displayedVersion: String? { model.installedVersion(for: product.id) }

    private var slices: [AgentCategorySlice] { derived?.slices ?? [] }
    private var totalBytes: UInt64 { derived?.storage.physicalBytes ?? 0 }
    private var logicalBytes: UInt64 { derived?.storage.logicalBytes ?? 0 }
    private var itemCount: Int { derived?.storage.itemCount ?? 0 }
    private var attributedBytes: UInt64 { slices.reduce(UInt64(0)) { $0 &+ $1.bytes } }
    private var remainderBytes: UInt64 { totalBytes > attributedBytes ? totalBytes - attributedBytes : 0 }
    private var possibleCount: Int { homes.filter { $0.confidence == .possible }.count }
    private var homeCountLine: String {
        if possibleCount == 0 { return model.localized("%d 个 Home", homes.count) }
        return model.localized("%d 个 Home · %d 个疑似", homes.count, possibleCount)
    }
    private var evidenceCount: Int {
        (installation?.evidence.count ?? 0) + homes.reduce(0) { $0 + $1.evidence.count }
    }
    private var evidenceHelp: String {
        var lines = installation?.evidence ?? []
        lines.append(contentsOf: homes.flatMap(\.evidence))
        if lines.isEmpty { return model.localized("暂无生效安装或 Home 证据。") }
        return Array(Set(lines)).sorted().joined(separator: "\n")
    }

    private var statusText: String {
        isEffective ? model.localized("生效") : model.localized("未生效")
    }

    private var statusColor: Color {
        isEffective ? DS.Semantic.statusPositive : DS.Semantic.statusCaution
    }

    private var statusSymbol: String {
        isEffective ? "terminal.fill" : "exclamationmark.triangle"
    }

    private var brandTint: Color {
        HomeProductStyle.brandColor(for: product.id) ?? HomeProductStyle.color(for: product.id)
    }

    private var categoryAccent: Color {
        slices.first.map { AgentCategoryPalette.color(for: $0.category) } ?? DS.Semantic.accentPrimary
    }

    private var skillSlice: AgentCategorySlice? {
        slices.first { $0.category == .skill }
    }

    private var isActiveHovering: Bool {
        isHovering && controlActiveState != .inactive
    }

    var body: some View {
        Button {
            model.selectedAgentID = product.id
            model.selectedAgentHomeID = nil
        } label: {
            cardSurface
        }
        .buttonStyle(AgentCardPressButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: DS.Motion.hover)) {
                    isHovering = hovering
                }
            }
        }
        .contextMenu { cardMenu }
        .accessibilityHint(model.localized("打开%@详情", product.displayName))
    }

    // MARK: 卡片表面

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            header
            pathPill
            metricStrip
            storageBreakdown
            footer
        }
        .padding(DS.Space.x400)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cardBackground }
        .overlay { cardBorder }
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
    }

    /// 与旧档案卡视觉一致的“基色 + 顶部高光”；accent 只通过描边和正文表达，
    /// 不在每张卡上再叠加第二层全尺寸渐变，避免窗口拖动时整卡反复重绘。
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .fill(Color(nsColor: DS.Neutral.raised))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.05 : 0.42),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(
                isActiveHovering
                    ? DS.Semantic.accentPrimary.opacity(0.78)
                    : Color.primary.opacity(DS.Opacity.borderStandard),
                lineWidth: isActiveHovering ? 1.25 : DS.Stroke.surface
            )
    }

    // MARK: 身份区

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.x300) {
            iconTile
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                Text(product.id)
                    .font(DS.Typeface.micro.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(categoryAccent)
                    .lineLimit(1)
                Text(productName)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .tracking(-0.15)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.x200)
            HStack(alignment: .center, spacing: DS.Space.x150) {
                if let version = displayedVersion {
                    versionBadge(version)
                }
                confidenceBadge
            }
        }
    }

    private func versionBadge(_ version: String) -> some View {
        Text("v\(version)")
            .font(DS.Typeface.micro.weight(.semibold))
            .foregroundStyle(DS.Semantic.accentPrimary)
            .padding(.horizontal, DS.Space.x200)
            .padding(.vertical, DS.Space.x100 + 1)
            .background(Capsule(style: .continuous).fill(DS.Semantic.accentPrimary.opacity(0.10)))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.Semantic.accentPrimary.opacity(0.26), lineWidth: DS.Stroke.hairline)
            )
            .accessibilityLabel(model.localized("已安装版本 %@", version))
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [brandTint.opacity(0.20), brandTint.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(brandTint.opacity(0.26), lineWidth: DS.Stroke.hairline)
            HomeBrandIcon(productID: product.id, size: 22)
        }
        .frame(width: 42, height: 42)
        .shadow(color: brandTint.opacity(0.16), radius: 3, y: 1)
        .accessibilityHidden(true)
    }

    private var confidenceBadge: some View {
        HStack(spacing: DS.Space.x100) {
            Image(systemName: statusSymbol)
                .font(.system(size: 8, weight: .bold))
            Text(statusText)
                .font(DS.Typeface.micro.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, DS.Space.x200)
        .padding(.vertical, DS.Space.x100 + 1)
        .background(Capsule(style: .continuous).fill(statusColor.opacity(0.11)))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(statusColor.opacity(0.28), lineWidth: DS.Stroke.hairline)
        )
    }

    // MARK: 路径与仪表

    private var pathPill: some View {
        HStack(spacing: DS.Space.x200) {
            Image(systemName: isEffective ? "terminal" : "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isEffective ? brandTint : DS.Semantic.statusCaution)
                .frame(width: 12)
            Text(installationPathText)
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive()
                .help(installation?.path ?? "")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.x250)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .fill(Color.primary.opacity(DS.Opacity.fillFaint))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
    }

    private var installationPathText: String {
        guard let installation else { return model.localized("未检测到生效可执行文件") }
        return model.displayPath(installation.path)
    }

    private var metricStrip: some View {
        HStack(alignment: .center, spacing: 0) {
            metricCell(
                icon: "internaldrive",
                label: model.localized("物理占用"),
                value: model.formatBytes(totalBytes),
                tint: categoryAccent,
                emphasized: true
            )
            metricDivider
            metricCell(
                icon: "square.stack.3d.up",
                label: model.localized("逻辑占用"),
                value: model.formatBytes(logicalBytes)
            )
            metricDivider
            metricCell(
                icon: "doc.on.doc",
                label: model.localized("条目数"),
                value: "\(itemCount)"
            )
            metricDivider
            metricCell(
                icon: "checkmark.shield",
                label: model.localized("证据数"),
                value: "\(evidenceCount)",
                helpText: evidenceHelp
            )
        }
        .padding(.vertical, DS.Space.x250)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .fill(Color(nsColor: DS.Neutral.recessed))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
    }

    private func metricCell(
        icon: String,
        label: String,
        value: String,
        helpText: String? = nil,
        tint: Color = .primary,
        emphasized: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            HStack(spacing: DS.Space.x100) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint.opacity(0.85))
                Text(label)
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: emphasized ? 14 : 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(emphasized ? tint : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.x250)
        .help(Text(helpText ?? ""))
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
            .frame(width: DS.Stroke.hairline, height: 28)
            .accessibilityHidden(true)
    }

    // MARK: 容量构成

    private var storageBreakdown: some View {
        VStack(alignment: .leading, spacing: DS.Space.x150) {
            HStack(spacing: DS.Space.x200) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(categoryAccent)
                Text(model.localized("容量分析"))
                    .font(DS.Typeface.label)
                Spacer(minLength: DS.Space.x200)
                Text(model.localized("%@ / %@", model.formatBytes(attributedBytes), model.formatBytes(totalBytes)))
                    .font(DS.Typeface.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            storageBar
            if legendItems.isEmpty {
                Text(model.localized("暂无容量明细。"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            } else {
                legendLine
            }
        }
    }

    private var legendItems: [AgentCardLegendItem] {
        var items = slices.prefix(3).map {
            AgentCardLegendItem(
                id: .category($0.category),
                title: model.artifactCategoryTitle($0.category),
                bytes: $0.bytes,
                color: AgentCategoryPalette.color(for: $0.category)
            )
        }
        if remainderBytes > 0 {
            items.append(
                AgentCardLegendItem(
                    id: .remainder,
                    title: model.localized("未归属"),
                    bytes: remainderBytes,
                    color: Color.secondary.opacity(0.62)
                )
            )
        }
        return items
    }

    private var storageBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let total = Double(totalBytes)
            HStack(spacing: 2) {
                ForEach(slices, id: \.category) { slice in
                    Rectangle()
                        .fill(AgentCategoryPalette.color(for: slice.category))
                        .frame(width: segmentWidth(fraction: total > 0 ? Double(slice.bytes) / total : 0, totalWidth: width))
                }
                if remainderBytes > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: segmentWidth(fraction: total > 0 ? Double(remainderBytes) / total : 0, totalWidth: width))
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
        }
        .frame(height: DS.Layout.agentStorageBarHeight)
        .background(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.primary.opacity(DS.Opacity.fillQuiet))
        )
        .accessibilityHidden(true)
    }

    private func segmentWidth(fraction: Double, totalWidth: CGFloat) -> CGFloat {
        fraction > 0 ? max(2.5, totalWidth * CGFloat(fraction)) : 0
    }

    private var legendLine: some View {
        HStack(spacing: DS.Space.x250) {
            ForEach(legendItems) { item in
                legendChip(item)
            }
            Spacer(minLength: 0)
        }
    }

    private func legendChip(_ item: AgentCardLegendItem) -> some View {
        HStack(spacing: DS.Space.x100) {
            Circle()
                .fill(item.color)
                .frame(width: 6, height: 6)
            Text(item.title)
                .foregroundStyle(.secondary)
            Text(model.formatBytes(item.bytes))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(DS.Typeface.micro)
        .lineLimit(1)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: DS.Space.x200) {
            metadataChip(
                icon: isEffective ? "terminal" : "exclamationmark.triangle",
                text: statusText
            )
            metadataChip(icon: "folder", text: homeCountLine)
            if let skillSlice {
                metadataChip(
                    icon: "sparkles",
                    text: "\(model.artifactCategoryTitle(.skill)) \(skillSlice.itemCount)"
                )
            }
            Spacer(minLength: DS.Space.x200)
            detailAffordance
        }
    }

    private func metadataChip(icon: String, text: String) -> some View {
        HStack(spacing: DS.Space.x100) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(DS.Typeface.micro)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.x200)
        .padding(.vertical, DS.Space.x100)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(DS.Opacity.fillFaint)))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
    }

    private var detailAffordance: some View {
        HStack(spacing: DS.Space.x100) {
            Text(model.localized("详情"))
            Image(systemName: "chevron.right")
                .offset(x: isActiveHovering ? 2 : 0)
        }
        .font(DS.Typeface.micro.weight(.semibold))
        .foregroundStyle(isActiveHovering ? DS.Semantic.accentPrimary : Color.secondary)
        .opacity(isActiveHovering ? 1 : 0.70)
    }

    @ViewBuilder
    private var cardMenu: some View {
        Button(model.localized("打开%@详情", product.displayName)) {
            model.selectedAgentID = product.id
            model.selectedAgentHomeID = nil
        }
    }
}

private struct AgentCardLegendItem: Identifiable {
    enum Kind: Hashable {
        case category(ArtifactCategory)
        case remainder
    }

    let id: Kind
    let title: String
    let bytes: UInt64
    let color: Color
}

/// 卡片按压反馈：只负责 pressed 缩放；hover 上浮、描边与柔光由 AgentProductCard 本体驱动。
private struct AgentCardPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: DS.Motion.press),
                value: configuration.isPressed
            )
    }
}

/// 骨架屏：镜像档案卡网格（4 张骨架卡，固定尺寸防跳动），数据未就绪时的占位。
private struct AgentCardGridSkeleton: View {
    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: DS.Layout.agentCardColumnMinWidth, maximum: DS.Layout.agentCardColumnMaxWidth), spacing: DS.Space.x300)],
                alignment: .leading,
                spacing: DS.Space.x300
            ) {
                ForEach(0..<4, id: \.self) { _ in
                    AgentCardSkeleton()
                }
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// 骨架卡：镜像新档案卡的信息层级（图标砖 + 身份 + 路径胶囊 + 仪表带 + 容量构成 + 底栏）。
private struct AgentCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .center, spacing: DS.Space.x300) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(DS.Opacity.fillSkeleton))
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: DS.Space.x100) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 84, height: 8)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 138, height: 13)
                }
                Spacer(minLength: DS.Space.x200)
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(DS.Opacity.fillSkeleton))
                    .frame(width: 54, height: 20)
            }

            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .fill(Color.primary.opacity(DS.Opacity.fillFaint))
                .frame(height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .frame(maxWidth: 260, alignment: .leading)
                        .frame(height: 9)
                        .padding(.horizontal, DS.Space.x250)
                )

            skeletonMetricStrip

            VStack(alignment: .leading, spacing: DS.Space.x150) {
                HStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 72, height: 11)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 96, height: 10)
                }
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.primary.opacity(DS.Opacity.fillSkeleton))
                    .frame(height: DS.Layout.agentStorageBarHeight)
                HStack(spacing: DS.Space.x250) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: DS.Space.x100) {
                            Circle()
                                .fill(Color.primary.opacity(0.10))
                                .frame(width: 6, height: 6)
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 66, height: 9)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: DS.Space.x200) {
                skeletonChip(width: 68)
                skeletonChip(width: 82)
                Spacer(minLength: DS.Space.x200)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 48, height: 10)
            }
        }
        .padding(DS.Space.x400)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(Color(nsColor: DS.Neutral.raised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderStandard), lineWidth: DS.Stroke.surface)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
    }

    private var skeletonMetricStrip: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                VStack(alignment: .leading, spacing: DS.Space.x100) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 46, height: 8)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 56, height: 11)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.x250)
                if index < 3 {
                    Rectangle()
                        .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
                        .frame(width: DS.Stroke.hairline, height: 28)
                }
            }
        }
        .padding(.vertical, DS.Space.x250)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .fill(Color(nsColor: DS.Neutral.recessed))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
    }

    private func skeletonChip(width: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(Color.primary.opacity(DS.Opacity.fillFaint))
            .frame(width: width, height: 20)
    }
}



private struct AgentDetailStatCard: View {
    let title: String
    let value: String
    let glyph: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            HStack(spacing: DS.Space.x100) {
                Image(systemName: glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(DS.Typeface.label)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(DS.Typeface.metricValue)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(DS.Space.x300)
        .background(Color(nsColor: DS.Neutral.raised), in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        }
    }
}

/// Agent 产品详情页：一层只回答「本机生效的是哪个可执行文件」，
/// Home 配置列表是产品内部可选项；点击 Home 才进入该 Home 的存储/Skill/会话详情。
private struct AgentProductDetailView: View {
    @Bindable var model: AppModel
    let productID: String
    @State private var insight: AgentInsightSnapshot?

    private var product: AgentProduct? { model.agentProduct(withID: productID) }
    private var homes: [AgentHome] { model.agentHomes(for: productID) }
    private var installation: AgentInstallation? { model.effectiveInstallation(for: productID) }

    private var skillInstallations: [SkillInstallation] {
        model.skillInstallations(for: productID)
    }
    private var insightKey: String? {
        guard let generation = model.snapshot?.generation else { return nil }
        let homeSignature = homes.map { $0.path }.joined(separator: "|")
        return "\(generation.uuidString)-\(productID)-\(homeSignature)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x400) {
                heroStats
                installationSection
                usageSection
                configurationSection
                mcpSection
                skillsSection
                homeConfigurationSection
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            detailHeader
        }
        .task(id: insightKey) {
            await model.refreshSkillIndexIfNeeded()
            await recomputeInsight()
        }
    }

    @MainActor
    private func recomputeInsight() async {
        guard let product else { insight = nil; return }
        let value = await Task.detached(priority: .utility) {
            AgentInsightUseCase().execute(product: product)
        }.value
        guard self.product?.id == productID else { return }
        insight = value
    }

    private var detailHeader: some View {
        detailIdentity
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Space.x300)
            .frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: DS.Neutral.canvas))
    }

    private var detailIdentity: some View {
        DSPageIdentity(
            title: product?.displayName ?? productID,
            glyph: "cpu",
            detail: detailLine
        ) {
            Button {
                model.selectedAgentID = nil
                model.selectedAgentHomeID = nil
            } label: {
                Label(model.localized("返回"), systemImage: "chevron.left")
            }
            .buttonStyle(.dsAction(size: .regular))
        }
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let installation {
            parts.append(model.localized("生效：%@", model.displayPath(installation.path)))
        } else {
            parts.append(model.localized("未检测到生效可执行文件"))
        }
        if let version = model.installedVersion(for: productID) {
            parts.append("v\(version)")
        }
        parts.append(model.localized("%d 个 Home", homes.count))
        return parts.joined(separator: " · ")
    }

    // MARK: 生效安装

    private var installationSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Text(model.localized("生效安装"))
                .font(DS.Typeface.title)
            DSCard(padding: DS.Space.x400) {
                if let installation {
                    VStack(alignment: .leading, spacing: DS.Space.x250) {
                        HStack(spacing: DS.Space.x200) {
                            Image(systemName: "terminal")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Semantic.statusPositive)
                                .frame(width: 18)
                            Text(model.displayPath(installation.path))
                                .font(DS.Typeface.body.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .privacySensitive()
                                .help(installation.path)
                            Spacer(minLength: DS.Space.x300)
                            DSBadge(text: model.localized("生效"), color: DS.Semantic.statusPositive)
                        }
                        ForEach(Array(installation.evidence.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "seal")
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: DS.Space.x200) {
                        Image(systemName: "questionmark.diamond")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Semantic.statusCaution)
                        Text(model.localized("未检测到生效可执行文件。只有 Home 目录不足以证明 Agent 当前生效；请检查安装或 PATH。"))
                            .font(DS.Typeface.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 概览读数

    private var heroStats: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: DS.Space.x300)],
            alignment: .leading,
            spacing: DS.Space.x300
        ) {
            AgentDetailStatCard(
                title: model.localized("版本"),
                value: model.installedVersion(for: productID).map { "v\($0)" } ?? "—",
                glyph: "number",
                tint: DS.Semantic.accentPrimary
            )
            AgentDetailStatCard(
                title: model.localized("Home 配置"),
                value: "\(homes.count)",
                glyph: "folder",
                tint: DS.Chart.series02
            )
            AgentDetailStatCard(
                title: model.localized("Skill"),
                value: model.skillIndex == nil ? "—" : "\(skillInstallations.count)",
                glyph: "hammer",
                tint: DS.Chart.series06
            )
            AgentDetailStatCard(
                title: model.localized("MCP"),
                value: "\(insight?.mcpInstallations.count ?? 0)",
                glyph: "point.3.connected.trianglepath.dotted",
                tint: DS.Chart.series05
            )
            AgentDetailStatCard(
                title: model.localized("Token"),
                value: tokenText(insight?.usage?.inputTokens),
                glyph: "text.word.spacing",
                tint: DS.Chart.series04
            )
        }
    }

    // MARK: 用量与套餐

    @ViewBuilder
    private var usageSection: some View {
        if let usage = insight?.usage {
            VStack(alignment: .leading, spacing: DS.Space.x300) {
                Text(model.localized("用量与套餐"))
                    .font(DS.Typeface.title)
                DSCard(padding: DS.Space.x400) {
                    VStack(alignment: .leading, spacing: DS.Space.x300) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: DS.Space.x300)],
                            alignment: .leading,
                            spacing: DS.Space.x300
                        ) {
                            usageMetric("输入 Token", usage.inputTokens)
                            usageMetric("输出 Token", usage.outputTokens)
                            usageMetric("缓存读取", usage.cacheReadInputTokens)
                            usageMetric("缓存写入", usage.cacheCreationInputTokens)
                            usageMetric("费用", usage.costUSD, isCost: true)
                            usageMetric("代码增行", usage.linesAdded)
                            usageMetric("代码删行", usage.linesRemoved)
                            usageMetric("使用时长", usage.durationSeconds, isDuration: true)
                        }
                        if usage.modelUsage.isEmpty == false {
                            Divider()
                            Text(model.localized("模型用量"))
                                .font(DS.Typeface.label)
                                .foregroundStyle(.secondary)
                            ForEach(usage.modelUsage.prefix(5)) { item in
                                modelUsageRow(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func usageMetric(_ title: String, _ value: UInt64, isCost: Bool = false, isDuration: Bool = false) -> some View {
        usageMetricView(title: title, text: isCost ? costText(Double(value)) : isDuration ? durationText(value) : tokenText(value))
    }

    private func usageMetric(_ title: String, _ value: Double, isCost: Bool = false, isDuration: Bool = false) -> some View {
        usageMetricView(title: title, text: isCost ? costText(value) : isDuration ? durationText(UInt64(value)) : tokenText(UInt64(value)))
    }

    private func usageMetricView(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            Text(title)
                .font(DS.Typeface.label)
                .foregroundStyle(.secondary)
            Text(text)
                .font(DS.Typeface.metricValue)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.x250)
        .background(Color.primary.opacity(DS.Opacity.fillFaint), in: RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous))
    }

    private func modelUsageRow(_ item: AgentModelUsage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            HStack {
                Text(item.model)
                    .font(DS.Typeface.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(costText(item.costUSD))
                    .font(DS.Typeface.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.Semantic.accentPrimary)
            }
            Text(model.localized("输入 %@ · 输出 %@ · 缓存读取 %@", tokenText(item.inputTokens), tokenText(item.outputTokens), tokenText(item.cacheReadInputTokens)))
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, DS.Space.x100)
    }

    // MARK: 基础配置

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Text(model.localized("基础配置"))
                .font(DS.Typeface.title)
            if let entries = insight?.configurationEntries, entries.isEmpty == false {
                DSCard(padding: DS.Space.x300) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries.prefix(12)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x250) {
                                Text(entry.key)
                                    .font(DS.Typeface.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 160, alignment: .leading)
                                Text(entry.value)
                                    .font(DS.Typeface.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .help(entry.source)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, DS.Space.x100)
                            if entry.id != entries.prefix(12).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                DSCard(padding: DS.Space.x400) {
                    Text(model.localized("未发现可安全展示的配置文件。"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: MCP

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.localized("MCP 安装项"))
                    .font(DS.Typeface.title)
                Spacer()
                Text(model.localized("%d 个", insight?.mcpInstallations.count ?? 0))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let mcp = insight?.mcpInstallations, mcp.isEmpty == false {
                DSCard(padding: DS.Space.x300) {
                    VStack(alignment: .leading, spacing: DS.Space.x100) {
                        ForEach(mcp) { item in
                            HStack(spacing: DS.Space.x250) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.Chart.series05)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: DS.Space.x050) {
                                    Text(item.name)
                                        .font(DS.Typeface.body.weight(.semibold))
                                    if let command = item.command {
                                        Text(model.displayPath(command))
                                            .font(DS.Typeface.caption)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .privacySensitive()
                                    }
                                }
                                Spacer()
                                DSBadge(
                                    text: model.localized(item.enabled ? "已启用" : "已停用"),
                                    color: item.enabled ? DS.Semantic.statusPositive : DS.Semantic.statusCaution
                                )
                            }
                            .padding(.vertical, DS.Space.x100)
                        }
                    }
                }
            } else {
                DSCard(padding: DS.Space.x400) {
                    Text(model.localized("未发现 MCP 安装项。"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Skills

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.localized("Skills 加载列表"))
                    .font(DS.Typeface.title)
                Spacer()
                Text(model.localized("%d 个", skillInstallations.count))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.skillIndex == nil {
                DSCard(padding: DS.Space.x400) {
                    HStack(spacing: DS.Space.x200) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.localized("正在加载 Skill…"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if skillInstallations.isEmpty {
                DSCard(padding: DS.Space.x400) {
                    Text(model.localized("此 Agent 没有已加载的 Skill。"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                DSCard(padding: DS.Space.x300) {
                    VStack(alignment: .leading, spacing: DS.Space.x100) {
                        ForEach(skillInstallations) { installation in
                            HStack(spacing: DS.Space.x250) {
                                Image(systemName: "hammer.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.Chart.series06)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: DS.Space.x050) {
                                    Text(installation.name)
                                        .font(DS.Typeface.body.weight(.semibold))
                                    Text(model.displayPath(installation.path))
                                        .font(DS.Typeface.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .privacySensitive()
                                }
                                Spacer()
                                Text(model.localized("%d 个文件", installation.fileCount))
                                    .font(DS.Typeface.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                DSBadge(
                                    text: model.localized(installation.state == .valid ? "有效" : (installation.state == .conflict ? "冲突" : "无效")),
                                    color: installation.state == .valid ? DS.Semantic.statusPositive : DS.Semantic.statusCaution
                                )
                            }
                            .padding(.vertical, DS.Space.x100)
                        }
                    }
                }
            }
        }
    }

    // MARK: 格式化

    private func tokenText(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func costText(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private func durationText(_ seconds: UInt64) -> String {
        if seconds >= 3600 { return String(format: "%.1f h", Double(seconds) / 3600) }
        if seconds >= 60 { return String(format: "%.1f min", Double(seconds) / 60) }
        return "\(seconds) s"
    }

    // MARK: Home 配置

    private var homeConfigurationSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.localized("Home 配置"))
                    .font(DS.Typeface.title)
                Spacer(minLength: DS.Space.x300)
                Text(model.localized("%d 个", homes.count))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if homes.isEmpty {
                DSCard(padding: DS.Space.x400) {
                    Text(model.localized("未发现此 Agent 的 Home。该产品可能不落盘配置，或 Home 不在当前扫描范围内。"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                DSCard(padding: DS.Space.x300) {
                    VStack(alignment: .leading, spacing: DS.Space.x100) {
                        ForEach(homes) { home in
                            homeConfigurationRow(home)
                        }
                    }
                }
            }
        }
    }

    private func homeConfigurationRow(_ home: AgentHome) -> some View {
        HStack(spacing: DS.Space.x250) {
            HomeBrandIcon(productID: home.productID, size: 22)
            VStack(alignment: .leading, spacing: DS.Space.x050) {
                Text(model.displayPath(home.path))
                    .font(DS.Typeface.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive()
                HStack(spacing: DS.Space.x150) {
                    Circle()
                        .fill(home.confidence == .confirmed ? DS.Semantic.statusPositive : DS.Semantic.statusCaution)
                        .frame(width: 6, height: 6)
                    Text(model.discoverySourceTitle(home.source))
                        .foregroundStyle(.secondary)
                    if let version = home.version {
                        Text("v\(version)")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .font(DS.Typeface.caption)
            }
            Spacer(minLength: DS.Space.x300)
            Text(model.formatBytes(home.storage.physicalBytes))
                .font(DS.Typeface.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                model.selectedAgentHomeID = home.id
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.localized("打开%@详情", home.displayName))
        }
        .padding(.horizontal, DS.Space.x150)
        .padding(.vertical, DS.Space.x200)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(model.localized("打开%@详情", home.displayName)) {
                model.selectedAgentHomeID = home.id
            }
            if home.confidence == .possible {
                Button(model.localized("确认为 %@", home.displayName)) {
                    model.confirmCandidate(home)
                }
                Button(model.localized("忽略此位置"), role: .destructive) {
                    model.ignoreCandidate(home)
                }
            } else if home.source == .userConfirmed {
                Button(model.localized("撤销本机确认")) {
                    model.revokeCandidateConfirmation(home)
                }
            }
        }
    }
}


// MARK: - Agent 详情页

/// Agent Home 详情页：仅展示所选 Home 配置内的概览读数 + 容量分析 + 对话管理 + Skills + 证据。
/// 由 Agent 产品详情页的 Home 配置行进入；左上「返回」清空 selectedAgentHomeID 回到产品详情。
private struct AgentHomeDetailView: View {
    @Bindable var model: AppModel
    let home: AgentHome
    @State private var derived: AgentCardDerived?
    @State private var pendingCleanupUnits: [CleanupUnit] = []
    @State private var showingCleanupReview = false

    private var deriveKey: String? {
        guard let generation = model.snapshot?.generation else { return nil }
        return "\(generation.uuidString)-home-\(home.id.device)-\(home.id.inode)-\(home.id.kind.rawValue)"
    }

    private var slices: [AgentCategorySlice] {
        derived?.slicesByHome[home.id] ?? []
    }

    private var attributedBytes: UInt64 { slices.reduce(UInt64(0)) { $0 &+ $1.bytes } }
    private var remainderBytes: UInt64 {
        home.storage.physicalBytes > attributedBytes ? home.storage.physicalBytes - attributedBytes : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x400) {
                overviewStrip
                capacitySection
                conversationsSection
                skillsSection
                evidenceSection
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
            .frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            detailHeader
        }
        .task(id: deriveKey) { await recomputeDerived() }
        .sheet(isPresented: $showingCleanupReview) {
            CleanupReviewSheet(model: model, units: pendingCleanupUnits) {
                model.executeCleanup(pendingCleanupUnits)
                showingCleanupReview = false
            }
        }
    }

    // MARK: 身份区

    /// 固定页头：与列表页一致，身份区共享 pageMaxWidth 内容列并铺满安全区背景。
    private var detailHeader: some View {
        detailIdentity
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Space.x300)
            .frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: DS.Neutral.canvas))
    }

    private var detailIdentity: some View {
        DSPageIdentity(
            title: home.displayName,
            glyph: "cpu",
            detail: detailLine
        ) {
            Button {
                model.selectedAgentHomeID = nil
            } label: {
                Label(model.localized("返回"), systemImage: "chevron.left")
            }
            .buttonStyle(.dsAction(size: .regular))
            if home.confidence == .possible || home.source == .userConfirmed {
                Menu {
                    if home.confidence == .possible {
                        Button(model.localized("确认为 %@", home.displayName)) {
                            model.confirmCandidate(home)
                        }
                        Button(model.localized("忽略此位置"), role: .destructive) {
                            model.ignoreCandidate(home)
                        }
                    } else if home.source == .userConfirmed {
                        Button(model.localized("撤销本机确认")) {
                            model.revokeCandidateConfirmation(home)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(model.localized("管理此位置"))
                .help(model.localized("管理此位置"))
            }
        }
    }

    private var detailLine: String? {
        guard let product = model.snapshot?.products.first(where: { $0.id == home.productID }) else {
            return nil
        }
        let confidence = model.localized(home.confidence == .confirmed ? "已确认" : "疑似")
        var line = model.localized("%@ · %@", product.displayName, model.displayPath(home.path))
            + " · " + model.discoverySourceTitle(home.source) + " · " + confidence
        if let version = model.installedVersion(for: home.productID) {
            line += " · v\(version)"
        }
        return line
    }

    // MARK: 概览读数

    private var overviewStrip: some View {
        HStack(alignment: .center, spacing: DS.Layout.homeReadingSpacing) {
            detailReading(model.localized("物理占用"), model.formatBytes(home.storage.physicalBytes))
            readingDivider
            detailReading(model.localized("逻辑占用"), model.formatBytes(home.storage.logicalBytes))
            readingDivider
            detailReading(model.localized("条目数"), model.localized("%d 项", home.storage.itemCount))
            readingDivider
            detailReading(model.localized("证据数"), "\(home.evidence.count)")
        }
    }

    private func detailReading(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            Text(label)
                .font(DS.Typeface.label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DS.Typeface.reading)
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private var readingDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
            .frame(width: DS.Stroke.hairline, height: 44)
            .accessibilityHidden(true)
    }

    // MARK: 容量分析

    private struct CapacityRow: Identifiable {
        let id: String
        let title: String
        let bytes: UInt64
        let items: Int
        let color: Color
    }

    private var capacityRows: [CapacityRow] {
        var rows = slices.map {
            CapacityRow(
                id: $0.category.rawValue,
                title: model.artifactCategoryTitle($0.category),
                bytes: $0.bytes,
                items: $0.itemCount,
                color: AgentCategoryPalette.color(for: $0.category)
            )
        }
        if remainderBytes > 0 {
            rows.append(CapacityRow(
                id: "unattributed",
                title: model.localized("未归属"),
                bytes: remainderBytes,
                items: 0,
                color: Color.secondary.opacity(0.55)
            ))
        }
        return rows
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Text(model.localized("容量分析"))
                .font(DS.Typeface.title)
            DSCard(padding: DS.Space.x400) {
                VStack(alignment: .leading, spacing: DS.Space.x300) {
                    capacityBar
                    if slices.isEmpty {
                        Text(model.localized("暂无容量明细。"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(capacityRows) { row in
                            capacityRow(row)
                        }
                    }
                }
            }
        }
    }

    private var capacityBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let total = Double(home.storage.physicalBytes)
            HStack(spacing: 1) {
                ForEach(slices, id: \.category) { slice in
                    segment(
                        color: AgentCategoryPalette.color(for: slice.category),
                        fraction: total > 0 ? Double(slice.bytes) / total : 0,
                        totalWidth: width
                    )
                }
                if remainderBytes > 0 {
                    segment(
                        color: Color.secondary.opacity(0.55),
                        fraction: total > 0 ? Double(remainderBytes) / total : 0,
                        totalWidth: width
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: DS.Layout.agentStorageBarHeight)
        .background(
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.primary.opacity(DS.Opacity.fillQuiet))
        )
        .accessibilityHidden(true)
    }

    private func segment(color: Color, fraction: Double, totalWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color)
            .frame(
                width: fraction > 0 ? max(2, totalWidth * fraction) : 0,
                height: DS.Layout.agentStorageBarHeight
            )
    }

    private func capacityRow(_ row: CapacityRow) -> some View {
        HStack(spacing: DS.Space.x250) {
            Circle()
                .fill(row.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(row.title)
                .font(DS.Typeface.body)
            Spacer(minLength: DS.Space.x300)
            if row.items > 0 {
                Text(model.localized("%d 项", row.items))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(model.formatBytes(row.bytes))
                .font(DS.Typeface.body.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 对话

    private var sessionUnits: [CleanupUnit] {
        model.cleanupUnits
            .filter { $0.homeIdentity == home.id && $0.category == ArtifactCategory.sessions.rawValue }
            .sorted { ($0.lastActivity.date ?? .distantPast) > ($1.lastActivity.date ?? .distantPast) }
    }

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Text(model.localized("对话"))
                .font(DS.Typeface.title)
            DSCard(padding: DS.Space.x300) {
                VStack(alignment: .leading, spacing: DS.Space.x250) {
                    if sessionUnits.isEmpty {
                        Text(model.localized("此 Home 没有对话记录。"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sessionUnits) { unit in
                            conversationRow(unit)
                        }
                    }
                }
            }
            if let message = model.cleanupOperationMessage {
                Text(message)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.cleanupResults) { result in
                HStack(spacing: DS.Space.x200) {
                    Image(systemName: result.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(result.status == .succeeded ? DS.Semantic.statusPositive : DS.Semantic.statusCaution)
                        .accessibilityHidden(true)
                    Text(result.name)
                        .font(DS.Typeface.caption)
                    Text(model.cleanupResultCodeTitle(result.code))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func conversationRow(_ unit: CleanupUnit) -> some View {
        HStack(spacing: DS.Space.x250) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Chart.series01)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.x050) {
                Text(model.cleanupUnitTitle(unit))
                    .font(DS.Typeface.body.weight(.semibold))
                    .lineLimit(1)
                if let date = unit.lastActivity.date {
                    Text(model.localized("最后活动：%@", date.formatted(.relative(presentation: .named).locale(model.appLocale))))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: DS.Space.x300)
            Text(model.formatBytes(unit.storage.physicalBytes))
                .font(DS.Typeface.body.weight(.semibold))
                .monospacedDigit()
            Button(model.localized("清理")) {
                pendingCleanupUnits = [unit]
                showingCleanupReview = true
            }
            .buttonStyle(.dsAction(.destructive, size: .compact))
            .disabled(!model.allows(.cleanup))
        }
        .padding(.vertical, DS.Space.x100)
        .accessibilityElement(children: .contain)
    }

    // MARK: Skills

    private var homeSkills: [SkillInstallation] {
        model.skillIndex?.logicalSkills
            .flatMap(\.variants)
            .flatMap(\.installations)
            .filter { $0.homeID == home.id } ?? []
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.localized("Skill"))
                    .font(DS.Typeface.title)
                Spacer(minLength: DS.Space.x300)
                Button(model.localized("在 Skill 页管理")) {
                    model.selection = .skills
                }
                .buttonStyle(.dsFooterLink())
            }
            DSCard(padding: DS.Space.x300) {
                VStack(alignment: .leading, spacing: DS.Space.x250) {
                    if homeSkills.isEmpty {
                        Text(model.localized("此 Home 未发现 Skill。"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(homeSkills) { installation in
                            skillRow(installation)
                        }
                    }
                }
            }
        }
    }

    private func skillRow(_ installation: SkillInstallation) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x050) {
            HStack(spacing: DS.Space.x200) {
                Text(installation.name)
                    .font(DS.Typeface.body.weight(.semibold))
                    .lineLimit(1)
                if installation.state != .valid {
                    DSBadge(
                        text: model.localized(installation.state == .conflict ? "冲突" : "无效"),
                        color: DS.Semantic.statusCaution
                    )
                }
                Spacer(minLength: DS.Space.x200)
                Text(model.formatBytes(installation.totalBytes))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(model.displayPath(installation.path))
                .font(DS.Typeface.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive()
        }
        .padding(.vertical, DS.Space.x050)
        .accessibilityElement(children: .combine)
    }

    // MARK: 证据

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Text(model.localized("证据"))
                .font(DS.Typeface.title)
            DSCard(padding: DS.Space.x300) {
                VStack(alignment: .leading, spacing: DS.Space.x150) {
                    if home.evidence.isEmpty {
                        Text(model.localized("此 Home 没有证据记录。"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(home.evidence.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "seal")
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 派生

    @MainActor
    private func recomputeDerived() async {
        guard let snapshot = model.snapshot else { return }
        let generation = snapshot.generation
        let value = await Task.detached(priority: .utility) {
            computeAgentCardDerived(snapshot: snapshot)
        }.value
        guard model.snapshot?.generation == generation else { return }
        derived = value
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

    /// 页面身份区：标题 + 大号物理占用数据 + 最大类别信息行。
    private var storageIdentity: some View {
        DSPageIdentity(
            title: model.localized("空间"),
            glyph: "internaldrive",
            value: storageIdentityValue,
            detail: storageIdentityDetail
        ) { EmptyView() }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

    private var storageIdentityValue: String? {
        guard let derived else { return nil }
        return model.formatBytes(derived.totalPhysicalBytes)
    }

    private var storageIdentityDetail: String? {
        guard let snapshot = model.snapshot else { return nil }
        let totals = Dictionary(grouping: snapshot.storageLedger.artifacts, by: \.category).mapValues {
            $0.reduce(UInt64(0)) { $0 &+ $1.storage.physicalBytes }
        }
        guard let largest = totals.max(by: { $0.value < $1.value }) else { return model.localized("暂无物理资源") }
        return model.localized("最大类别：%@", model.artifactCategoryTitle(largest.key))
    }

    var body: some View {
        Group {
            if let snapshot = model.snapshot, let derived {
                storageContent(snapshot: snapshot, derived: derived)
            } else {
                DSSkeletonList(sections: [3, 4, 3])
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            storageIdentity
        }
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

private struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("sampleInterval") private var sampleInterval = ActivitySamplingPolicy.defaultInterval
    @State private var confirmUninstall = false

    /// 页面身份区：标题 + 授权状态信息行。
    private var settingsIdentity: some View {
        DSPageIdentity(
            title: model.localized("设置"),
            glyph: "gearshape",
            detail: model.licenseStatusText
        ) { EmptyView() }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

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
                Stepper(
                    model.localized("采样间隔：%d 秒", Int(sampleInterval)),
                    value: $sampleInterval,
                    in: ActivitySamplingPolicy.minimumInterval...ActivitySamplingPolicy.maximumInterval
                )
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
                if model.licenseConfigurationAvailable {
                    HStack {
                        TextField(model.localized("License Key"), text: $model.licenseKey)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Typeface.data)
                            .onSubmit { model.activate() }
                        Button(model.localized("激活")) { model.activate() }
                            .buttonStyle(.dsAction(.accent))
                            .disabled(
                                model.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || model.activationPhase != .idle
                            )
                    }
                    if let message = model.licenseActionError {
                        HStack(spacing: DS.Space.x150) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DS.Semantic.statusCaution)
                                .accessibilityHidden(true)
                            Text(message)
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            settingsIdentity
        }
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

    /// 页面身份区：标题 + 样本统计，主操作（导出）右对齐在标题基线行。
    private var historyIdentity: some View {
        DSPageIdentity(
            title: model.localized("历史"),
            glyph: "clock.arrow.circlepath",
            detail: model.historyEnabled ? model.localized("最近 %d 个样本", model.historyPoints.count) : nil
        ) {
            Menu("导出") {
                Button("CSV") { model.exportHistoryCSV() }
                Button("PDF") { model.exportHistoryPDF() }
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!model.historyEnabled || !model.allows(.export))
        }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

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
        .safeAreaInset(edge: .top, spacing: 0) {
            historyIdentity
        }
        .task { await model.refreshHistory() }
    }

    private var historyCPU: [Double?] {
        model.historyPoints.map(\.cpuFraction)
    }
}
