//
//  HomeView.swift
//  AgentNest
//
//  首页发现界面：借鉴 find-disk-killer StorageMapDiscoveryView——
//  扫描中直接铺在画布上（无卡片容器），逐个确认设备上的 Agent Home：
//  - 已发现计数滚动（numericText）
//  - 刚发现的 Agent（fade + 位移过渡换新，无容器样式）
//  - 已发现芯片逐个插入
//  - 来源范围实时计数 + 信任底栏
//  全部动效为状态切换一次性过渡，无循环、无材质、无阴影。
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

/// 发现界面（扫描中）：直接铺在画布上，不用卡片容器，与页面融为整体。
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
        VStack(alignment: .leading, spacing: DS.Space.x400) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.x400) {
                    headerCopy
                    Spacer(minLength: DS.Space.x300)
                    latestConfirmation(homes)
                        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: DS.Space.x400) {
                    headerCopy
                    latestConfirmation(homes)
                        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
                }
            }

            confirmedSection(homes)
            scopeSection(homes)

            if progress.phase != .discoveringAgents, progress.phase != .validatingHomes {
                progressRow
            }

            trustBar
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
