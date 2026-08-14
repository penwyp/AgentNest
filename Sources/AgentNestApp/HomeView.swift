//
//  HomeView.swift
//  AgentNest
//
//  首页：吸收 find-disk-killer Storage Map 首页语言——
//  - 扫描中 = 「发现界面」（借鉴 StorageMapDiscoveryView）：已发现计数滚动、
//    刚发现的 Agent 卡片、确认芯片逐个出现、发现来源范围、信任底栏；
//  - 扫描后：摘要指标带（大数值滚动）+ Agent 空间地图（加权马赛克）+ 快速入口。
//
//  交互响应优先：搜索词为本地 @State，过滤在 body 一次计算复用；
//  UI 只消费不可变快照（DeviceSnapshot）与渐进 ScanProgress。
//

import AgentNestCore
import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x400) {
                header

                if let progress = model.progress, model.isScanning {
                    HomeDiscoveryView(model: model, progress: progress)
                }

                if let snapshot = model.snapshot {
                    HomeSummaryBand(model: model, snapshot: snapshot)
                    HomeAgentMap(model: model, snapshot: snapshot, searchText: $searchText)
                    HomeQuickLinks(model: model, snapshot: snapshot)
                } else if !model.isScanning {
                    HomeEmptyState(model: model)
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
        .onAppear {
            // 首次进入：自动开始发现（无快照时），复现「第一次进入 storage map 即发现」的体验。
            model.autoStartInitialScanIfNeeded()
        }
    }

    private var header: some View {
        DSPageHeader(
            title: model.localized(model.isScanning ? "正在发现本机 Agent 环境" : "发现并维护你的 Agent 环境"),
            subtitle: model.localized("仅扫描 Agent Definition 声明和你明确添加的 Agent Home，数据只在本机分析。"),
            systemImage: model.isScanning ? "magnifyingglass" : "bird.fill"
        ) {
            HStack(spacing: DS.Space.x300) {
                DSSearchField(
                    prompt: model.localized("搜索 Agent"),
                    text: $searchText,
                    clearAccessibilityLabel: model.localized("清空搜索")
                )
                .frame(width: DS.Layout.homeSearchWidth)
                .disabled(model.snapshot == nil)

                scanButton
            }
        }
    }

    private var scanButton: some View {
        Button {
            if model.isScanning {
                model.stopScan()
            } else {
                model.startScan()
            }
        } label: {
            HStack(spacing: DS.Space.x250) {
                ZStack {
                    if model.isScanning {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: DS.Space.x050) {
                    Text(model.localized(model.isScanning ? "停止" : (model.snapshot == nil ? "扫描" : "重新扫描")))
                        .font(DS.Typeface.body.weight(.semibold))
                        .lineLimit(1)
                    Text(model.localized(model.isScanning ? (model.isStoppingScan ? "正在停止…" : "中止本次扫描") : "更新 Agent 清单"))
                        .font(DS.Typeface.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DS.Space.x300 + DS.Space.x050)
            .frame(width: DS.Layout.homeActionWidth, height: DS.Layout.homeActionHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        }
        .buttonStyle(HomeScanButtonStyle(
            tint: model.isScanning ? DS.Semantic.statusCaution : DS.Semantic.accentPrimary,
            showsFlow: model.isScanning
        ))
        .disabled(model.isStoppingScan)
        .keyboardShortcut(.defaultAction)
        .help(model.localized(model.isScanning ? "停止分析" : "重新扫描 Agent 环境"))
        .accessibilityLabel(model.localized(model.isScanning ? "停止" : (model.snapshot == nil ? "扫描" : "重新扫描")))
    }

}

/// 产品视觉映射：SF Symbol + 稳定色相（djb2 散列 → chart series 固定映射）。
enum HomeProductStyle {
    private static let symbols: [String: String] = [
        "openai.codex": "sparkles",
        "anthropic.claude-code": "quote.bubble",
        "cursor.cursor": "cursorarrow.click",
        "bytedance.trae": "chevron.left.forwardslash.chevron.right",
        "workbuddy": "hammer",
    ]

    static func symbol(for productID: String) -> String {
        symbols[productID] ?? "cpu"
    }

    static func color(for productID: String) -> Color {
        let series: [Color] = [
            DS.Chart.series01, DS.Chart.series02, DS.Chart.series03, DS.Chart.series04,
            DS.Chart.series05, DS.Chart.series06, DS.Chart.series07, DS.Chart.series08,
        ]
        var hash: UInt64 = 5381
        for byte in productID.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return series[Int(hash % UInt64(series.count))]
    }
}

/// 发现界面（扫描中）：借鉴 find-disk-killer StorageMapDiscoveryView——
/// 逐个确认设备上的 Agent Home：已发现计数滚动、刚发现卡片、确认芯片逐个出现、
/// 来源范围实时计数、进度行、信任底栏。全部动效为状态切换一次性过渡，无循环。
private struct HomeDiscoveryView: View {
    let model: AppModel
    let progress: ScanProgress

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let scopeAreas: [HomeDiscoveryScopeArea] = [
        .init(source: .defaultPath, symbol: "folder", color: DS.Chart.series01),
        .init(source: .environment, symbol: "terminal", color: DS.Chart.series02),
        .init(source: .custom, symbol: "plus.circle", color: DS.Chart.series03),
        .init(source: .userConfirmed, symbol: "checkmark.circle", color: DS.Chart.series05),
    ]

    var body: some View {
        let homes = progress.confirmedHomes
        DSCard(padding: DS.Space.x450) {
            VStack(alignment: .leading, spacing: DS.Space.x400) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Space.x400) {
                        headerCopy
                        Spacer(minLength: DS.Space.x300)
                        latestConfirmation(homes)
                            .frame(minWidth: 230, maxWidth: 320, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.x400) {
                        headerCopy
                        latestConfirmation(homes)
                            .frame(minWidth: 230, maxWidth: 320, alignment: .leading)
                    }
                }

                confirmedSection(homes)
                scopeSection(homes)

                if progress.phase != .discoveringAgents, progress.phase != .validatingHomes {
                    progressRow
                }

                trustBar
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.enter), value: homes.map(\.id))
        .accessibilityElement(children: .contain)
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: DS.Space.x200) {
            Label(model.scanPhaseTitle(progress.phase), systemImage: "scope")
                .font(DS.Typeface.body.weight(.semibold))
                .foregroundStyle(DS.Semantic.accentPrimary)
            Text(model.localized("%d 个 Agent Home 已发现", progress.confirmedHomes.count))
                .font(DS.Typeface.title)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.sample), value: progress.confirmedHomes.count)
            Text(model.localized("确认后立即加入下方列表，扫描完成后生成完整报告。"))
                .font(DS.Typeface.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func latestConfirmation(_ homes: [AgentHome]) -> some View {
        if let latest = homes.last {
            HStack(spacing: DS.Space.x300) {
                Image(systemName: HomeProductStyle.symbol(for: latest.productID))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(HomeProductStyle.color(for: latest.productID))
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                            .fill(HomeProductStyle.color(for: latest.productID).opacity(DS.Opacity.fillSubtle))
                    )
                VStack(alignment: .leading, spacing: DS.Space.x100) {
                    Label(model.localized("刚刚发现"), systemImage: "checkmark.circle.fill")
                        .font(DS.Typeface.caption.weight(.semibold))
                        .foregroundStyle(DS.Semantic.statusPositive)
                    Text(latest.displayName)
                        .font(DS.Typeface.section)
                        .lineLimit(1)
                    Text(model.discoverySourceTitle(latest.source))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(latest.id)
            .transition(.opacity.combined(with: .offset(y: DS.Space.x200)))
        } else {
            HStack(spacing: DS.Space.x300) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: DS.Space.x100) {
                    Text(model.localized("正在检查已知位置"))
                        .font(DS.Typeface.body.weight(.medium))
                    Text(model.localized("发现仍在进行"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func confirmedSection(_ homes: [AgentHome]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.localized("已发现的 Agent"))
                    .font(DS.Typeface.section)
                Spacer()
                if !homes.isEmpty {
                    Text(model.localized("%d 个已发现", homes.count))
                        .font(DS.Typeface.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if homes.isEmpty {
                HStack(spacing: DS.Space.x250) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.localized("正在检查已知位置"))
                        .font(DS.Typeface.body)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 58)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: DS.Space.x250)],
                    alignment: .leading,
                    spacing: DS.Space.x250
                ) {
                    ForEach(homes) { home in
                        HomeDiscoveryChip(model: model, home: home)
                    }
                }
            }
        }
    }

    private func scopeSection(_ homes: [AgentHome]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.localized("正在确认的范围"))
                    .font(DS.Typeface.section)
                Spacer()
                Label(model.localized("只读取位置，不读取文件内容"), systemImage: "lock.shield")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: DS.Space.x250)],
                alignment: .leading,
                spacing: DS.Space.x250
            ) {
                ForEach(Self.scopeAreas) { area in
                    let count = homes.filter { $0.source == area.source }.count
                    HStack(spacing: DS.Space.x300) {
                        Image(systemName: area.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(area.color)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: DS.Space.x050) {
                            Text(model.discoverySourceTitle(area.source))
                                .font(DS.Typeface.body.weight(.semibold))
                            Text(count > 0 ? model.localized("%d 个已发现", count) : model.localized("正在检查"))
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var progressRow: some View {
        DSRecessed {
            HStack(alignment: .center, spacing: DS.Space.x300) {
                Image(systemName: "scope")
                    .font(.system(size: DS.IconSize.card, weight: .medium))
                    .foregroundStyle(DS.Semantic.accentPrimary)
                    .accessibilityHidden(true)
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
                Spacer(minLength: DS.Space.x400)
                Text(model.localized("已处理 %d 项 · %@", progress.processedCount, model.formatBytes(progress.processedBytes)))
                    .font(DS.Typeface.data)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.sample), value: progress.processedCount)
            }
        }
    }

    private var trustBar: some View {
        HStack(spacing: DS.Space.x400) {
            trustItem(model.localized("本机分析"), symbol: "macbook")
            trustItem(model.localized("只读元数据"), symbol: "doc.text.magnifyingglass")
            trustItem(model.localized("不执行清理"), symbol: "hand.raised.fill")
            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.x300)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
                .frame(height: DS.Stroke.hairline)
                .accessibilityHidden(true)
        }
    }

    private func trustItem(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(DS.Typeface.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// 已发现 Agent 芯片：产品图标 + 名称 + 来源；疑似以徽章标注，确认以绿色勾标注。
private struct HomeDiscoveryChip: View {
    let model: AppModel
    let home: AgentHome

    var body: some View {
        HStack(spacing: DS.Space.x250) {
            Image(systemName: HomeProductStyle.symbol(for: home.productID))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HomeProductStyle.color(for: home.productID))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: DS.Space.x050) {
                Text(home.displayName)
                    .font(DS.Typeface.body.weight(.semibold))
                    .lineLimit(1)
                Text(model.discoverySourceTitle(home.source))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.x100)
            if home.confidence == .possible {
                DSBadge(text: model.localized("疑似"), color: DS.Semantic.statusCaution)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Semantic.statusPositive)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DS.Space.x250)
        .frame(minHeight: 58)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.52),
            in: RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
        )
        .transition(.opacity.combined(with: .offset(y: DS.Space.x200)))
        .accessibilityElement(children: .combine)
    }
}

/// 发现范围区（来源分类 → 图标 + 实时计数）。
private struct HomeDiscoveryScopeArea: Identifiable {
    let source: DiscoverySource
    let symbol: String
    let color: Color

    var id: String { source.rawValue }
}


/// 首页主操作按钮样式：着色填充 + hover/按压加深 + 一次性流动描边（扫描中）。
private struct HomeScanButtonStyle: ButtonStyle {
    let tint: Color
    let showsFlow: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && controlActiveState == .active
        let isActiveHovering = isHovering && controlActiveState == .active
        configuration.label
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(tint.opacity(isPressed ? 0.20 : (isActiveHovering ? 0.16 : 0.09)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(
                        tint.opacity(isPressed ? 0.55 : (isActiveHovering ? 0.45 : 0.25)),
                        lineWidth: 1
                    )
            )
            .dsFlowStroke(isActive: showsFlow, color: tint, cornerRadius: DS.Radius.panel)
            .scaleEffect(isPressed && isEnabled ? 0.985 : 1)
            .opacity(isEnabled ? 1 : DS.Opacity.disabledControl)
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.hover)) {
                    isHovering = hovering
                }
            }
            .onChange(of: controlActiveState) { _, state in
                if state != .active { isHovering = false }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.press), value: isPressed)
    }
}

/// 摘要指标带：主数值（已分析空间）+ 指标组（Agent Home / Skill 安装 / 文件条目 / 完整度）。
private struct HomeSummaryBand: View {
    let model: AppModel
    let snapshot: DeviceSnapshot

    var body: some View {
        DSCard(padding: DS.Space.x400) {
            HStack(alignment: .center, spacing: DS.Space.x300) {
                primarySummary
                    .frame(minWidth: 216, alignment: .leading)
                divider
                DSHeaderMetric(value: confirmedHomeCount, label: model.localized("Agent Home"))
                divider
                DSHeaderMetric(
                    value: model.localized("%d 个安装", model.skillIndex?.installationCount ?? 0),
                    label: model.localized("Skill 安装")
                )
                divider
                DSHeaderMetric(
                    value: snapshot.totalStorage.itemCount.formatted(.number),
                    label: model.localized("文件条目")
                )
                divider
                DSHeaderMetric(
                    value: model.localized(snapshot.isPartial ? "部分" : "完整"),
                    label: model.localized("完整度")
                )
                Spacer(minLength: DS.Space.x300)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
            .frame(width: DS.Stroke.hairline, height: DS.Layout.homeSummaryDividerHeight)
    }

    private var confirmedHomeCount: String {
        snapshot.homes.filter { $0.confidence == .confirmed }.count.formatted(.number)
    }

    private var primarySummary: some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            Text(model.localized("已分析空间"))
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
            Text(model.formatBytes(snapshot.totalStorage.physicalBytes))
                .font(DS.Typeface.display)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: DS.Motion.sample), value: snapshot.totalStorage.physicalBytes)
            Text(model.localized("更新于 %@", snapshot.createdAt.formatted(date: .omitted, time: .shortened)))
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Agent 空间地图：按物理占用加权的已安装 Agent 马赛克，支持搜索过滤。
private struct HomeAgentMap: View {
    @Bindable var model: AppModel
    let snapshot: DeviceSnapshot
    @Binding var searchText: String

    @State private var mapRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let displayLimit = 6

    private var rankedHomes: [AgentHome] {
        snapshot.homes.sorted { lhs, rhs in
            if lhs.storage.physicalBytes != rhs.storage.physicalBytes {
                return lhs.storage.physicalBytes > rhs.storage.physicalBytes
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredHomes: [AgentHome] {
        guard isSearching else { return rankedHomes }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rankedHomes.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.productID.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let visibleHomes = isSearching ? filteredHomes : Array(rankedHomes.prefix(Self.displayLimit))
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x300) {
                Text(model.localized("Agent 空间地图"))
                    .font(DS.Typeface.title)
                Spacer(minLength: DS.Space.x300)
                Text(model.localized("按物理占用排列 · %d 个 Home", visibleHomes.count))
                    .font(DS.Typeface.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if visibleHomes.isEmpty {
                mapEmptyState
            } else {
                DSMosaicLayout(spacing: DS.Layout.homeMapCardSpacing) {
                    ForEach(Array(visibleHomes.enumerated()), id: \.element.id) { index, home in
                        HomeAgentMapCard(
                            model: model,
                            home: home,
                            totalBytes: totalVisibleBytes(visibleHomes),
                            color: productColor(home.productID),
                            emphasized: index == 0
                        )
                        .layoutValue(
                            key: DSMosaicWeightKey.self,
                            value: Double(max(home.storage.physicalBytes, 1))
                        )
                    }
                }
                .frame(height: DS.Layout.homeMapIdealHeight)
                .opacity(mapRevealed ? 1 : 0)
                .offset(y: mapRevealed ? 0 : DS.Space.x200)
                .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.enter), value: visibleHomes.map(\.id))
                .onAppear {
                    guard !reduceMotion else {
                        mapRevealed = true
                        return
                    }
                    withAnimation(.easeOut(duration: DS.Motion.enter)) {
                        mapRevealed = true
                    }
                }

                if !isSearching, rankedHomes.count > Self.displayLimit {
                    Button {
                        model.selection = .agents
                    } label: {
                        HStack(spacing: DS.Space.x100) {
                            Text(model.localized("查看全部 %d 个 Agent", rankedHomes.count))
                            Image(systemName: "chevron.right")
                                .font(.system(size: DS.IconSize.sortIndicator, weight: .semibold))
                        }
                    }
                    .buttonStyle(.dsFooterLink())
                }
            }
        }
    }

    private var mapEmptyState: some View {
        DSCard {
            HStack(spacing: DS.Space.x300) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.IconSize.card, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                if isSearching {
                    VStack(alignment: .leading, spacing: DS.Space.x100) {
                        Text(model.localized("没有与“%@”匹配的 Agent", searchText.trimmingCharacters(in: .whitespacesAndNewlines)))
                            .font(DS.Typeface.section)
                        Text(model.localized("换一个名称、产品或路径试试。"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.x300)
                    Button(model.localized("清空搜索")) {
                        searchText = ""
                    }
                    .buttonStyle(.dsAction(size: .compact))
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.x100) {
                        Text(model.localized("尚无 Agent 结果"))
                            .font(DS.Typeface.section)
                        Text(model.localized("先在首页扫描。"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func totalVisibleBytes(_ homes: [AgentHome]) -> UInt64 {
        max(1, homes.reduce(0) { $0 &+ $1.storage.physicalBytes })
    }

    private func productColor(_ productID: String) -> Color {
        HomeProductStyle.color(for: productID)
    }
}

/// 空间地图卡片：产品色点 + 名称 + 大号 light 数值（滚动）+ 占比 + 状态。
private struct HomeAgentMapCard: View {
    let model: AppModel
    let home: AgentHome
    let totalBytes: UInt64
    let color: Color
    let emphasized: Bool

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            model.selection = .agents
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.x200) {
                HStack(spacing: DS.Space.x200) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(home.displayName)
                        .font(emphasized ? DS.Typeface.body.weight(.semibold) : DS.Typeface.label.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DS.Space.x200)
                    if home.confidence == .possible {
                        DSBadge(text: model.localized("疑似"), color: DS.Semantic.statusCaution)
                    }
                }

                Text(model.formatBytes(home.storage.physicalBytes))
                    .font(emphasized ? DS.Typeface.valueMapEmphasized : DS.Typeface.valueMap)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.sample), value: home.storage.physicalBytes)

                Text(model.formatPercent(Double(home.storage.physicalBytes) / Double(totalBytes)))
                    .font(emphasized ? DS.Typeface.label : DS.Typeface.micro)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: DS.Space.x250) {
                    Text(model.localized(home.confidence == .confirmed ? "已确认" : "疑似"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.x200)
                    Image(systemName: HomeProductStyle.symbol(for: home.productID))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(color.opacity(0.72))
                        .accessibilityHidden(true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(DS.Space.x400)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(Color(nsColor: DS.Neutral.raised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(
                        isHovering
                            ? color.opacity(0.52)
                            : Color.primary.opacity(colorScheme == .dark ? 0.16 : DS.Opacity.borderStandard),
                        lineWidth: isHovering ? 1.1 : DS.Stroke.surface
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.localized(
            "%@：%@。%@",
            home.displayName,
            model.formatBytes(home.storage.physicalBytes),
            model.localized(home.confidence == .confirmed ? "已确认" : "疑似")
        ))
        .accessibilityHint(model.localized("查看 Agent 列表"))
    }
}

/// 快速入口：Agent / Skill / 空间 / 活动 四张紧凑卡。
private struct HomeQuickLinks: View {
    @Bindable var model: AppModel
    let snapshot: DeviceSnapshot

    var body: some View {
        Grid(horizontalSpacing: DS.Space.x300, verticalSpacing: DS.Space.x300) {
            GridRow {
                quickCard(
                    title: "Agent",
                    value: model.localized("%d 个 Home", snapshot.homes.filter { $0.confidence == .confirmed }.count),
                    detail: model.localized(snapshot.homes.contains { $0.confidence == .possible } ? "有疑似位置待确认" : "发现结果已核验"),
                    icon: "cpu",
                    tint: DS.Chart.series01,
                    destination: .agents
                )
                quickCard(
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
                quickCard(
                    title: model.localized("空间"),
                    value: model.formatBytes(snapshot.totalStorage.physicalBytes),
                    detail: largestStorageCategory(snapshot),
                    icon: "internaldrive",
                    tint: DS.Chart.series03,
                    destination: .storage
                )
                quickCard(
                    title: model.localized("活动"),
                    value: activityValue,
                    detail: activityDetail,
                    icon: "waveform.path.ecg",
                    tint: DS.Chart.series02,
                    destination: .activity
                )
            }
        }
    }

    private func quickCard(
        title: String,
        value: String,
        detail: String,
        icon: String,
        tint: Color,
        destination: AppModel.Destination
    ) -> some View {
        Button {
            model.selection = destination
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.x150) {
                HStack(spacing: DS.Space.x200) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(DS.Typeface.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(DS.Typeface.section)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text(detail)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(DS.Space.x300)
            .frame(maxWidth: .infinity, minHeight: DS.Layout.homeQuickLinkHeight, alignment: .leading)
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

/// 首页空态：尚未扫描时的引导。
private struct HomeEmptyState: View {
    let model: AppModel

    var body: some View {
        DSCard {
            VStack(spacing: DS.Space.x200) {
                Image(systemName: "tray")
                    .font(.system(size: DS.IconSize.hero, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(model.localized("尚无 Agent 结果"))
                    .font(DS.Typeface.section)
                Text(model.localized("先在首页扫描。"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
