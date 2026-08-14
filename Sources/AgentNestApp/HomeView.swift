//
//  HomeView.swift
//  AgentNest
//
//  首页发现界面：借鉴 find-disk-killer StorageMapFirstRunView 的桌面拓扑布局——
//  左列「扫描中心」（刚发现的 Agent + 指标 + 底部信任事实），
//  右列「本次扫描路径」拓扑栏（按发现来源分组的 Canvas 连线分支 + 芯片网格），
//  整体加宽并设最小高度，充分利用窗口空间；全部动效为状态切换一次性过渡，
//  无循环、无材质、无阴影。
//

import AgentNestCore
import SwiftUI

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

/// 发现界面（扫描中）：左扫描中心 + 右拓扑栏，直接铺在画布上、无卡片容器。
struct HomeDiscoveryView: View {
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
        let isDiscovering = progress.phase == .discoveringAgents || progress.phase == .validatingHomes
        VStack(alignment: .leading, spacing: DS.Space.x400) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.x450) {
                    scanCenter(homes)
                        .frame(width: DS.Layout.homeDiscoveryScanCenterWidth, alignment: .topLeading)
                    topologyRail(homes)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: DS.Space.x400) {
                    scanCenter(homes)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    topologyRail(homes)
                }
            }

            if !isDiscovering {
                progressRow
            }
        }
        .frame(minHeight: 440)
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.enter), value: homes.map(\.id))
        .accessibilityElement(children: .contain)
    }

    /// 左列扫描中心：刚发现的 Agent（fade/位移换新）→ 指标 → 底部信任事实。
    private func scanCenter(_ homes: [AgentHome]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let latest = homes.last {
                HStack(spacing: DS.Space.x300) {
                    Image(systemName: HomeProductStyle.symbol(for: latest.productID))
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(HomeProductStyle.color(for: latest.productID))
                    VStack(alignment: .leading, spacing: DS.Space.x100) {
                        Label(model.localized("刚刚发现"), systemImage: "checkmark.circle.fill")
                            .font(DS.Typeface.caption.weight(.semibold))
                            .foregroundStyle(DS.Semantic.statusPositive)
                        Text(latest.displayName)
                            .font(DS.Typeface.title)
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
                        Text(model.scanPhaseTitle(progress.phase))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x400) {
                scanMetric(model.localized("来源"), "\(activeSourceCount(homes))", color: DS.Semantic.accentPrimary)
                scanMetric(model.localized("疑似"), "\(homes.filter { $0.confidence == .possible }.count)", color: DS.Semantic.statusCaution)
            }
            .padding(.top, DS.Space.x450)

            Spacer(minLength: DS.Space.x400)

            VStack(alignment: .leading, spacing: DS.Space.x250) {
                trustItem(model.localized("本机分析"), symbol: "macbook")
                trustItem(model.localized("只读元数据"), symbol: "doc.text.magnifyingglass")
                trustItem(model.localized("不执行清理"), symbol: "hand.raised.fill")
            }
            .padding(.top, DS.Space.x300)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
                    .frame(height: DS.Stroke.hairline)
                    .accessibilityHidden(true)
            }
        }
    }

    private func scanMetric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x050) {
            Text(value)
                .font(DS.Typeface.section)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func trustItem(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(DS.Typeface.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func activeSourceCount(_ homes: [AgentHome]) -> Int {
        Set(homes.map(\.source)).count
    }

    /// 右列拓扑栏：按发现来源分组，Canvas 连线表示扫描归属。
    private func topologyRail(_ homes: [AgentHome]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x300) {
                VStack(alignment: .leading, spacing: DS.Space.x100) {
                    Text(model.localized("本次扫描路径"))
                        .font(DS.Typeface.title)
                    Text(model.localized("连线表示扫描来源，不表示容量大小"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.localized("只读取位置，不读取文件内容"), systemImage: "lock.shield")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, DS.Space.x300)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.scopeAreas.enumerated()), id: \.element.id) { index, area in
                    HomeDiscoveryBranch(
                        model: model,
                        area: area,
                        homes: homes.filter { $0.source == area.source },
                        isFirst: index == 0,
                        isLast: index == Self.scopeAreas.count - 1
                    )
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
}

/// 拓扑分支：来源标题 + 该来源已发现的芯片网格，左侧 Canvas 连线与色点。
private struct HomeDiscoveryBranch: View {
    let model: AppModel
    let area: HomeDiscoveryScopeArea
    let homes: [AgentHome]
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            HStack(spacing: DS.Space.x200) {
                Image(systemName: area.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(area.color)
                    .frame(width: 22, height: 22)
                Text(model.discoverySourceTitle(area.source))
                    .font(DS.Typeface.section)
                Text(homes.isEmpty ? model.localized("正在检查") : model.localized("%d 个已发现", homes.count))
                    .font(DS.Typeface.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if !homes.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: DS.Space.x250)],
                    alignment: .leading,
                    spacing: DS.Space.x250
                ) {
                    ForEach(homes) { home in
                        HomeDiscoveryChip(model: model, home: home)
                    }
                }
            }
        }
        .padding(.leading, 34)
        .padding(.bottom, isLast ? 0 : DS.Space.x400)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            topologyConnector
                .frame(width: 34)
        }
    }

    private var topologyConnector: some View {
        Canvas { context, size in
            let x: CGFloat = 9
            let branchY: CGFloat = 11
            var vertical = Path()
            vertical.move(to: CGPoint(x: x, y: isFirst ? branchY : 0))
            vertical.addLine(to: CGPoint(x: x, y: isLast ? branchY : size.height))
            context.stroke(vertical, with: .color(Color.secondary.opacity(0.24)), lineWidth: 1)
            var branch = Path()
            branch.move(to: CGPoint(x: x, y: branchY))
            branch.addLine(to: CGPoint(x: size.width - 5, y: branchY))
            context.stroke(branch, with: .color(area.color.opacity(0.72)), lineWidth: 1.5)
            context.fill(
                Path(ellipseIn: CGRect(x: x - 3, y: branchY - 3, width: 6, height: 6)),
                with: .color(area.color)
            )
        }
        .accessibilityHidden(true)
    }
}

/// 已发现 Agent 芯片：产品图标 + 名称 + 路径；疑似以徽章标注，确认以绿色勾标注。
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
                Text(model.displayPath(home.path))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive()
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

/// 发现来源区（来源分类 → 图标 + 色相，用于拓扑分支）。
private struct HomeDiscoveryScopeArea: Identifiable {
    let source: DiscoverySource
    let symbol: String
    let color: Color

    var id: String { source.rawValue }
}
