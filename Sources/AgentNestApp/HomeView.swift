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
import AppKit
import SwiftUI

/// 产品视觉映射：官方图标（thesvg.org，MIT）+ 品牌色 + SF Symbol 回退。
@MainActor
enum HomeProductStyle {
    private static let symbols: [String: String] = [
        "openai.codex": "sparkles",
        "anthropic.claude-code": "quote.bubble",
        "cursor.cursor": "cursorarrow.click",
        "bytedance.trae": "chevron.left.forwardslash.chevron.right",
        "workbuddy": "hammer",
    ]

    private static var brandImageCache: [String: NSImage] = [:]

    /// 打包文件名映射：产品 ID → BrandIcons 内的 PNG 文件名（不带 .png 后缀）。
    /// SwiftPM `.process` 会拍平资源目录，按文件名在包根查找；文件名与产品 ID 不一致的产品必须在此登记。
    private static let iconFiles: [String: String] = [
        "openai.codex": "codex",
        "anthropic.claude-code": "claude-code",
        "cursor.cursor": "cursor",
        "bytedance.trae": "trae",
        "workbuddy": "workbuddy",
    ]

    /// AgentNestCore 资源包（裸可执行文件与 .app 两种布局都兼容）。
    private static let resourceBundle: Bundle = {
        let mainURL = Bundle.main.bundleURL
        let candidates = [
            Bundle.main.url(forResource: "AgentNest_AgentNestCore", withExtension: "bundle"),
            mainURL.appending(path: "Contents/Resources/AgentNest_AgentNestCore.bundle"),
        ]
        for candidate in candidates {
            if let candidate, let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return Bundle.main
    }()

    /// 官方图标（无对应图标时为 nil → SF Symbol 回退）。
    /// 注意：SwiftPM `.process` 会把资源目录拍平，因此按文件名在包根查找。
    static func brandImage(for productID: String) -> NSImage? {
        if let cached = brandImageCache[productID] { return cached }
        let fileName = iconFiles[productID] ?? productID
        guard let url = resourceBundle.url(forResource: fileName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        brandImageCache[productID] = image
        return image
    }

    /// 官方品牌色（模板渲染用）；单色品牌（Codex / Cursor）返回 nil → 自适应主色。
    static func brandColor(for productID: String) -> Color? {
        switch productID {
        case "anthropic.claude-code": return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case "bytedance.trae": return Color(red: 0x32 / 255, green: 0xF0 / 255, blue: 0x8C / 255)
        default: return nil
        }
    }

    /// 以原色渲染的品牌（应用图标样式，如 WorkBuddy），其余品牌用模板渲染。
    static func rendersOriginalColor(for productID: String) -> Bool {
        productID == "workbuddy"
    }

    static func symbol(for productID: String) -> String {
        symbols[productID] ?? "cpu"
    }

    /// SF Symbol 回退色相（djb2 散列 → chart series 固定映射）。
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

/// 官方品牌图标：模板 + 品牌色/自适应主色；WorkBuddy 以原色渲染；无资源时回退 SF Symbol。
struct HomeBrandIcon: View {
    let productID: String
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image = HomeProductStyle.brandImage(for: productID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(HomeProductStyle.rendersOriginalColor(for: productID) ? .original : .template)
                    .foregroundStyle(HomeProductStyle.brandColor(for: productID) ?? Color.primary)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: HomeProductStyle.symbol(for: productID))
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(HomeProductStyle.color(for: productID))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: DS.Space.x400) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.x450) {
                    scanCenter(homes)
                        .frame(width: DS.Layout.homeDiscoveryScanCenterWidth, alignment: .topLeading)
                    topologyRail(homes)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                HStack(alignment: .top, spacing: DS.Space.x450) {
                    scanCenter(homes)
                        .frame(width: DS.Layout.homeDiscoveryScanCenterCompactWidth, alignment: .topLeading)
                    topologyRail(homes)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                compactDiscovery(homes)
            }
        }
        .frame(minHeight: 440)
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.enter), value: homes.map(\.id))
        .accessibilityElement(children: .contain)
    }

    /// 左列扫描中心：已发现计数 → 刚发现的 Agent（fade/位移换新）→ 指标 → 信任事实（紧贴内容，不再 Spacer 撑底）。
    private func scanCenter(_ homes: [AgentHome]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let latest = homes.last {
                Text(discoveredCountText(homes))
                    .font(DS.Typeface.title)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(alignment: .top, spacing: DS.Space.x300) {
                    HomeBrandIcon(productID: latest.productID, size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Label(model.localized("刚刚发现"), systemImage: "checkmark.circle.fill")
                            .font(DS.Typeface.caption.weight(.semibold))
                            .foregroundStyle(DS.Semantic.statusPositive)
                        Text(latest.displayName)
                            .font(DS.Typeface.title)
                            .lineLimit(1)
                            .padding(.top, DS.Space.x150)
                        Text(model.discoverySourceTitle(latest.source))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, DS.Space.x050)
                    }
                }
                .id(latest.id)
                .transition(.opacity.combined(with: .offset(y: DS.Space.x200)))
                .padding(.top, DS.Space.x300)
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
                scanMetric(model.localized("来源"), "\(activeSourceCount(homes))")
                scanMetric(model.localized("疑似"), "\(homes.filter { $0.confidence == .possible }.count)")
            }
            .padding(.top, DS.Space.x400)

            VStack(alignment: .leading, spacing: DS.Space.x250) {
                trustItem(model.localized("本机分析"), symbol: "macbook")
                trustItem(model.localized("只读元数据"), symbol: "doc.text.magnifyingglass")
                trustItem(model.localized("不执行清理"), symbol: "hand.raised.fill")
            }
            .padding(.top, DS.Space.x400)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(DS.Opacity.borderQuiet))
                    .frame(height: DS.Stroke.hairline)
                    .accessibilityHidden(true)
            }
        }
    }

    /// 窄窗口单列：紧凑扫描带（计数/指标同行 + 刚发现 + 信任事实横排）+ 整宽拓扑栏。
    private func compactDiscovery(_ homes: [AgentHome]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            compactHeader(homes)
            topologyRail(homes)
        }
    }

    private func compactHeader(_ homes: [AgentHome]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x200) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x300) {
                Text(discoveredCountText(homes))
                    .font(DS.Typeface.title)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: DS.Space.x200)
                HStack(spacing: DS.Space.x400) {
                    scanMetric(model.localized("来源"), "\(activeSourceCount(homes))")
                    scanMetric(model.localized("疑似"), "\(homes.filter { $0.confidence == .possible }.count)")
                }
            }
            if let latest = homes.last {
                HStack(alignment: .top, spacing: DS.Space.x200) {
                    HomeBrandIcon(productID: latest.productID, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Label(model.localized("刚刚发现"), systemImage: "checkmark.circle.fill")
                            .font(DS.Typeface.caption.weight(.semibold))
                            .foregroundStyle(DS.Semantic.statusPositive)
                        Text(latest.displayName)
                            .font(DS.Typeface.body.weight(.semibold))
                            .lineLimit(1)
                            .padding(.top, DS.Space.x100)
                    }
                }
                .id(latest.id)
                .transition(.opacity.combined(with: .offset(y: DS.Space.x200)))
            } else {
                HStack(spacing: DS.Space.x300) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.localized("正在检查已知位置"))
                        .font(DS.Typeface.body.weight(.medium))
                }
            }
            HStack(spacing: DS.Space.x250) {
                trustItem(model.localized("本机分析"), symbol: "macbook")
                trustItem(model.localized("只读元数据"), symbol: "doc.text.magnifyingglass")
                trustItem(model.localized("不执行清理"), symbol: "hand.raised.fill")
            }
        }
    }

    private func discoveredCountText(_ homes: [AgentHome]) -> String {
        model.localized("%d 个 Agent Home 已发现", homes.count)
    }

    private func scanMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x050) {
            Text(value)
                .font(DS.Typeface.metricValue)
                .monospacedDigit()
            Text(title)
                .font(DS.Typeface.label)
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
                    columns: [GridItem(.adaptive(minimum: 200, maximum: 340), spacing: DS.Space.x250)],
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
            HomeBrandIcon(productID: home.productID, size: 24)
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
