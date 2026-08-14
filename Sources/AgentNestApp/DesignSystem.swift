//
//  DesignSystem.swift
//  AgentNest
//
//  基于 Instrument Interface Visual System（DESIGN.md）的轻量原生实现。
//
//  性能策略：保持原生性能优先——
//  - 不透明表面，不叠加多层 systemMaterial / 模糊；
//  - 层级用“细描边 + 顶部高光 + 极浅投影”表达，不用多层阴影堆叠；
//  - 动效只在交互（hover/press/state）时发生，无循环动画；
//  - 列表仍使用原生 List / 系统控件。
//

import SwiftUI

// MARK: - Token 表

/// 设计 Token 命名空间（对应 DESIGN.md 的 reference / semantic / component tokens）。
enum DS {

    // MARK: 间距 space.050 … space.450

    enum Space {
        static let x050: CGFloat = 2
        static let x100: CGFloat = 4
        static let x150: CGFloat = 6
        static let x200: CGFloat = 8
        static let x250: CGFloat = 10
        static let x300: CGFloat = 12
        static let x400: CGFloat = 16
        static let x450: CGFloat = 18
    }

    // MARK: 组件布局 layout.*

    /// 页面级几何只在这里定义，消费 View 不直接散落尺寸常量。
    enum Layout {
        static let pageMaxWidth: CGFloat = 920
        static let activityPageMaxWidth: CGFloat = 1_320
        static let discoveryPageMaxWidth: CGFloat = 1_320
        static let homeDiscoveryScanCenterWidth: CGFloat = 248
        static let homeDiscoveryScanCenterCompactWidth: CGFloat = 200
        static let pageHorizontalInset: CGFloat = 32
        static let pageVerticalInset: CGFloat = 24
        /// 无标题栏窗口下，侧边栏顶部让出红绿灯（traffic lights）区域的高度。
        static let windowChromeTopInset: CGFloat = 44
        /// 页面身份区信息/数据行与标题文字左对齐的缩进（符号 20 + space.200）。
        static let pageIdentityContentInset: CGFloat = 28
        static let heroIconFrame: CGFloat = 40
        static let homeActionMinWidth: CGFloat = 168
        static let activationMaxWidth: CGFloat = 960
        static let activationFeatureIconFrame: CGFloat = 32
        static let activitySectionPickerWidth: CGFloat = 280
        static let activityRangePickerWidth: CGFloat = 260
        static let activityTrendPickerWidth: CGFloat = 240
        static let activitySearchWidth: CGFloat = 300
        static let activitySearchHeight: CGFloat = 30
        static let activityMetricDividerHeight: CGFloat = 38
        static let activityMetricIconFrame: CGFloat = 30
        static let activityDirectionMetricWidth: CGFloat = 90
        static let activityLegendWidth: CGFloat = 18
        static let activityChartHeight: CGFloat = 220
        static let activityChartAxisHeight: CGFloat = 22
        static let activityCPUColumnWidth: CGFloat = 84
        static let activityRateColumnWidth: CGFloat = 116
        static let activityAttributionColumnWidth: CGFloat = 92
        static let activityTableHeaderHeight: CGFloat = 38
        static let activityProcessIconFrame: CGFloat = 28
        static let activityProcessRowHeight: CGFloat = 58
        static let activityEmptyTableHeight: CGFloat = 220
        static let activityCapacityWidth: CGFloat = 180
        static let activitySkeletonLineHeight: CGFloat = 12
        /// 首页稳定态（环境总览台）最大内容宽度：读数带、环境图与管理入口共用。
        static let homeOverviewMaxWidth: CGFloat = 1_160
        /// 读数带相邻读数间距（分隔线居中于其间）。
        static let homeReadingSpacing: CGFloat = 64
        /// 管理入口自适应网格的最小列宽。
        static let homeManagementTileMinWidth: CGFloat = 240
        /// 产品档案卡次行（信心点阵 + 计数）相对卡片的缩进（图标 24 + space.250）。
        static let homeProductCardContentInset: CGFloat = 34
        /// Agent 页档案卡网格的最小 / 最大列宽。
        static let agentCardColumnMinWidth: CGFloat = 380
        static let agentCardColumnMaxWidth: CGFloat = 460
        /// Agent 档案卡类别空间构成条高度。
        static let agentStorageBarHeight: CGFloat = 4
    }

    enum IconSize {
        static let brand: CGFloat = 16
        static let navigation: CGFloat = 13
        static let page: CGFloat = 20
        static let hero: CGFloat = 40
        static let card: CGFloat = 20
        static let sortIndicator: CGFloat = 8
    }

    // MARK: 圆角 radius.*

    enum Radius {
        static let small: CGFloat = 5
        static let controlCompact: CGFloat = 6
        static let controlRegular: CGFloat = 7
        static let icon: CGFloat = 7
        static let panel: CGFloat = 8
    }

    // MARK: 描边 stroke.*

    enum Stroke {
        static let hairline: CGFloat = 0.6
        static let surface: CGFloat = 0.75
        static let focus: CGFloat = 2
    }

    // MARK: 色彩 color.*（固定色值来自 DESIGN.md 参考表）

    enum Chroma {
        static let blue = Color(red: 0.30, green: 0.46, blue: 0.62)          // #4D759E 主强调
        static let cyan = Color(red: 0.28, green: 0.60, blue: 0.65)          // #4799A6 方向 A
        static let amber = Color(red: 0.75, green: 0.47, blue: 0.18)         // #BF782E 方向 B / 警示
        static let graphite = Color(red: 0.52, green: 0.57, blue: 0.62)      // #85919E 中性对比
        static let green = Color(red: 0.31, green: 0.62, blue: 0.47)         // #4F9E78 建设性动作
        static let green600 = Color(red: 0.31, green: 0.61, blue: 0.35)      // #4F9C59 正向状态
        static let violet = Color(red: 0.53, green: 0.38, blue: 0.64)        // #8761A3 次强调
        static let indigo = Color(red: 0.45, green: 0.38, blue: 0.65)        // #7361A6 次方向
        static let red = Color(red: 0.75, green: 0.24, blue: 0.22)           // #BF3D38 临界
        static let teal = Color(red: 0.28, green: 0.59, blue: 0.53)          // #479687 建设性次动作
    }

    /// 中性色：随系统外观切换（动态），对应 color.neutral.*
    enum Neutral {
        /// 基底画布
        static let canvas = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedRed: 0x09 / 255, green: 0x0B / 255, blue: 0x0D / 255, alpha: 1)
                : NSColor(calibratedRed: 0xEC / 255, green: 0xF0 / 255, blue: 0xF2 / 255, alpha: 1)
        }
        /// 抬升表面
        static let raised = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedRed: 0x0F / 255, green: 0x13 / 255, blue: 0x15 / 255, alpha: 1)
                : NSColor(calibratedRed: 0xF6 / 255, green: 0xF8 / 255, blue: 0xF9 / 255, alpha: 1)
        }
        /// 沉入表面（比画布略深，模拟 recessed）
        static let recessed = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 1.0, alpha: 0.025)
                : NSColor(calibratedWhite: 0.0, alpha: 0.035)
        }
        static let white = Color.white
        static let black = Color.black
    }

    /// 语义色别名（color.surface / color.accent / color.status）
    enum Semantic {
        static let accentPrimary = DS.Chroma.blue
        static let accentSecondary = DS.Chroma.violet
        static let directionA = DS.Chroma.cyan
        static let directionB = DS.Chroma.amber
        static let statusPositive = DS.Chroma.green600
        static let statusCaution = DS.Chroma.amber
        static let statusCritical = DS.Chroma.red
    }

    // MARK: 不透明度 opacity.*

    enum Opacity {
        static let fillSubtle: Double = 0.10
        static let fillStandard: Double = 0.12
        static let borderStandard: Double = 0.13
        static let iconBorder: Double = 0.18
        static let disabledControl: Double = 0.46
        static let disabledIcon: Double = 0.42
        static let unavailable: Double = 0.30
        static let inactiveAccent: Double = 0.72
        static let fillFaint: Double = 0.025
        static let fillQuiet: Double = 0.05
        static let fillSkeleton: Double = 0.06
        static let borderQuiet: Double = 0.08
    }

    // MARK: 字体 type.*

    enum Typeface {
        static let displayLarge = Font.system(size: 34, weight: .semibold, design: .default)
        static let display = Font.system(size: 26, weight: .semibold, design: .default)
        static let pageTitle = Font.system(size: 28, weight: .semibold, design: .default)
        static let pageValue = Font.system(size: 28, weight: .semibold, design: .monospaced)
        static let title = Font.system(size: 20, weight: .semibold, design: .default)
        static let metricValue = Font.system(size: 24, weight: .semibold, design: .monospaced)
        /// 首页稳定态读数带大号数值（36 Light，配 monospacedDigit 使用）。
        static let reading = Font.system(size: 36, weight: .light, design: .default)
        static let section = Font.system(size: 17, weight: .medium, design: .default)
        static let body = Font.system(size: 13, weight: .regular, design: .default)
        static let lead = Font.system(size: 15, weight: .regular, design: .default)
        static let label = Font.system(size: 12, weight: .medium, design: .default)
        static let caption = Font.system(size: 11, weight: .regular, design: .default)
        static let micro = Font.system(size: 10, weight: .regular, design: .default)
        static let valueLarge = Font.system(size: 48, weight: .light, design: .default)
        static let valueMedium = Font.system(size: 36, weight: .regular, design: .default)
        static let data = Font.system(size: 12, weight: .regular, design: .monospaced)
    }

    // MARK: 动效 motion.*（轻量，尊重 Reduce Motion）

    enum Motion {
        static let press = 0.10
        static let hover = 0.12
        static let state = 0.20
        static let enter = 0.28
        static let sample = 0.36
        static let settle = 0.40
        static let chartHistogram = 0.50
        static let chartMeter = 0.48
        static let chartDonut = 0.55
        static let entranceStagger = 0.06
    }

    // MARK: 图表色序 chart.color.series.*

    enum Chart {
        static let series01 = DS.Chroma.blue
        static let series02 = DS.Chroma.cyan
        static let series03 = DS.Chroma.amber
        static let series04 = DS.Chroma.graphite
        static let series05 = DS.Chroma.green
        static let series06 = DS.Chroma.violet
        static let series07 = DS.Chroma.indigo
        static let series08 = DS.Chroma.teal
        static let threshold = DS.Semantic.statusCritical

        static let plotFill = Color.secondary.opacity(0.035)
        static let grid = Color.secondary.opacity(0.10)
        static let axis = Color.secondary.opacity(0.26)
        static let lineWidth: CGFloat = 1.7
        static let areaOpacity: Double = 0.12
        static let secondaryDash: [CGFloat] = [6, 4]
    }
}

// MARK: - 轻量表面组件

/// 画布背景：不透明、零模糊，保持原生性能。
/// 对应 DESIGN.md canvas 配方的不透明回退（Reduced Transparency 行为即长期策略）。
struct DSCanvasBackground: View {
    var body: some View {
        Color(nsColor: DS.Neutral.canvas)
            .ignoresSafeArea()
    }
}

/// 原生列表/表单继续负责滚动与可访问性，只移除系统自带的不透明内容底色。
private struct DSInstrumentListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}

extension View {
    func dsInstrumentList() -> some View {
        modifier(DSInstrumentListModifier())
    }
}

/// 骨架屏：数据未就绪时的占位列表。
/// 精确镜像列表页的信息架构（分组 + 行结构），固定尺寸防止数据到达时布局跳动；
/// 装饰性占位对无障碍隐藏、不接收命中。
struct DSSkeletonList: View {
    var sections: [Int] = [3, 5]

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, rowCount in
                Section {
                    ForEach(0..<rowCount, id: \.self) { _ in
                        HStack(spacing: DS.Space.x300) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: DS.Space.x150) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.09))
                                    .frame(height: 12)
                                    .frame(maxWidth: 260, alignment: .leading)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                                    .frame(height: 10)
                                    .frame(maxWidth: 180, alignment: .leading)
                            }
                            Spacer()
                        }
                        .padding(.vertical, DS.Space.x100)
                    }
                }
            }
        }
        .dsInstrumentList()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// 页面身份区（Headerless 页面的左上角标头）：纯排版层级，不设横幅与图标底座。
/// 行一：裸色强调符号（20 pt Medium）+ 大标题（type.pageTitle，28 Semibold，负字距 −0.4），右侧为页面主操作（基线对齐）。
/// 行二（可选）：大号等宽数据值（type.pageValue，28 Semibold monospaced，accent）——页面数据展示位。
/// 行三（可选）：信息行（type.body，13，secondary，等宽数字），与标题文字左对齐。
/// 静态排版、无动画，遵守 Reduce Motion 与单层绘制预算。
struct DSPageIdentity<Accessory: View>: View {
    let title: String
    var glyph: String = "circle.hexagongrid"
    var glyphColor: Color = DS.Semantic.accentPrimary
    var value: String? = nil
    var detail: String? = nil
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x200) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x200) {
                Image(systemName: glyph)
                    .font(.system(size: DS.IconSize.page, weight: .medium))
                    .foregroundStyle(glyphColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(DS.Typeface.pageTitle)
                    .tracking(-0.4)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: DS.Space.x400)
                accessory
            }
            if let value {
                Text(value)
                    .font(DS.Typeface.pageValue)
                    .monospacedDigit()
                    .foregroundStyle(DS.Semantic.accentPrimary)
                    .padding(.leading, DS.Layout.pageIdentityContentInset)
            }
            if let detail {
                Text(detail)
                    .font(DS.Typeface.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, DS.Layout.pageIdentityContentInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 抬升表面（玻璃的轻量替代）：不透明 raised 色 + 细描边 + 顶部高光 + 极浅投影。
/// 相比 DESIGN.md 的 ultraThinMaterial 玻璃配方，去掉多层模糊与双层阴影，性能接近纯色绘制。
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.Space.x400
    var cornerRadius: CGFloat = DS.Radius.panel
    var insetHighlight: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: DS.Neutral.raised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(DS.Opacity.borderStandard), lineWidth: DS.Stroke.surface)
            )
            .overlay(alignment: .top) {
                if insetHighlight {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.30), Color.clear, Color.black.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: DS.Stroke.hairline
                        )
                        .padding(1.25)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
    }
}

/// 沉入表面（recessed）：比画布略深，无投影，用于输入/证据区。
struct DSRecessed<Content: View>: View {
    var cornerRadius: CGFloat = DS.Radius.controlRegular
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DS.Space.x300)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: DS.Neutral.recessed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: DS.Stroke.hairline)
            )
    }
}

// MARK: - 文本组件

/// 数值 + 单位：共享首行基线、等宽数字（type.value / type.unit）
struct DSValue<Unit: View>: View {
    let value: String
    var size: Font = .system(size: 36, weight: .regular, design: .default)
    @ViewBuilder var unit: Unit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.x100) {
            Text(value)
                .font(size)
                .monospacedDigit()
            unit
        }
    }
}

// MARK: - 控件

/// 自定义 Action Button（对应 DESIGN.md control.action.regular）
/// 原生性能：仅改变填充色与 0.985 按压缩放，无模糊、无动态阴影。
struct DSActionButtonStyle: ButtonStyle {
    var variant: Variant = .neutral
    var size: Size = .regular

    enum Variant {
        case neutral, accent, destructive
    }

    enum Size {
        case compact, regular, large, hero

        var height: CGFloat {
            switch self {
            case .compact: return 30
            case .regular: return 34
            case .large: return 38
            case .hero: return 44
            }
        }

        var horizontalInset: CGFloat {
            switch self {
            case .compact: return 10
            case .regular: return 13
            case .large: return 16
            case .hero: return 22
            }
        }

        var font: Font {
            switch self {
            case .compact: return .system(size: 11, weight: .semibold)
            case .regular: return .system(size: 12, weight: .semibold)
            case .large: return .system(size: 13, weight: .semibold)
            case .hero: return .system(size: 15, weight: .semibold)
            }
        }

        var cornerRadius: CGFloat {
            self == .compact ? DS.Radius.controlCompact : DS.Radius.controlRegular
        }
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    private func fill(isPressed: Bool) -> Color {
        let isActiveHovering = isHovering && controlActiveState == .active
        switch variant {
        case .neutral: return Color(nsColor: .controlBackgroundColor).opacity(0.92)
        case .accent: return DS.Semantic.accentPrimary.opacity(isPressed ? 0.78 : (isActiveHovering ? 0.92 : 0.86))
        case .destructive: return DS.Semantic.statusCritical.opacity(isPressed ? 0.78 : (isActiveHovering ? 0.90 : 1.0))
        }
    }

    private var foreground: Color {
        switch variant {
        case .neutral: return .primary
        case .accent, .destructive: return .white
        }
    }

    private var border: Color {
        switch variant {
        case .neutral: return Color(nsColor: .separatorColor).opacity(0.90)
        case .accent: return Color.white.opacity(0.18)
        case .destructive: return Color.white.opacity(0.20)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && controlActiveState == .active
        configuration.label
            .font(size.font)
            .foregroundStyle(isEnabled ? foreground : foreground.opacity(DS.Opacity.disabledControl))
            .padding(.horizontal, size.horizontalInset)
            .frame(minHeight: size.height)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(isEnabled ? fill(isPressed: isPressed) : fill(isPressed: false).opacity(DS.Opacity.disabledControl))
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: size.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(border, lineWidth: variant == .neutral ? DS.Stroke.surface : 0.5)
            )
            .overlay(alignment: .top) {
                // 顶部白色高光（0.5 pt）
                RoundedRectangle(
                    cornerRadius: size.cornerRadius - 0.5,
                    style: .continuous
                )
                .strokeBorder(
                    Color.white.opacity(variant == .neutral ? 0.07 : 0.16),
                    lineWidth: 0.5
                )
                .padding(.horizontal, 4)
                .padding(.top, 1.5)
                .allowsHitTesting(false)
            }
            .scaleEffect(isPressed && isEnabled ? 0.985 : 1)
            .opacity(isEnabled ? 1 : DS.Opacity.disabledControl)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.controlRegular, style: .continuous))
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

extension ButtonStyle where Self == DSActionButtonStyle {
    static func dsAction(_ variant: DSActionButtonStyle.Variant = .neutral, size: DSActionButtonStyle.Size = .regular) -> DSActionButtonStyle {
        DSActionButtonStyle(variant: variant, size: size)
    }
}

/// 图标控制按钮（对应 DESIGN.md icon.control.frame.regular）
struct DSIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && controlActiveState == .active
        let isActiveHovering = isHovering && controlActiveState == .active
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                    .fill(
                        isPressed
                            ? Color.primary.opacity(0.14)
                            : (isActiveHovering ? Color.primary.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.78))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 0.5)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: DS.Radius.controlCompact - 0.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    .padding(.horizontal, 4)
                    .padding(.top, 1.5)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : DS.Opacity.disabledIcon)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.hover)) {
                    self.isHovering = hovering
                }
            }
            .onChange(of: controlActiveState) { _, state in
                if state != .active { self.isHovering = false }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.press), value: isPressed)
    }
}

extension ButtonStyle where Self == DSIconButtonStyle {
    static var dsIcon: DSIconButtonStyle { DSIconButtonStyle() }
}

/// 卡片按钮（用于可点击的表面卡片）：raised 表面 + hover 轻反馈，不透明、无模糊。
struct DSCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = DS.Radius.panel
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && controlActiveState == .active
        let isActiveHovering = isHovering && controlActiveState == .active
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isPressed
                            ? Color.primary.opacity(0.06)
                            : (isActiveHovering ? Color.primary.opacity(0.04) : Color(nsColor: DS.Neutral.raised))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isActiveHovering ? 0.22 : DS.Opacity.borderStandard),
                        lineWidth: isActiveHovering ? 1 : DS.Stroke.surface
                    )
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.30), Color.clear, Color.black.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: DS.Stroke.hairline
                    )
                    .padding(1.25)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isPressed && isEnabled ? 0.99 : 1)
            .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.hover)) {
                    self.isHovering = hovering
                }
            }
            .onChange(of: controlActiveState) { _, state in
                if state != .active { self.isHovering = false }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.press), value: isPressed)
    }
}

extension ButtonStyle where Self == DSCardButtonStyle {
    static var dsCard: DSCardButtonStyle { DSCardButtonStyle() }
}

/// 语义标签（badge / tag，radius.small）
struct DSBadge: View {
    let text: String
    var color: Color = .primary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(DS.Typeface.micro)
            .fontWeight(.medium)
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, DS.Space.x150)
            .padding(.vertical, DS.Space.x050 + 1)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? color : color.opacity(DS.Opacity.fillSubtle))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(filled ? 0 : 0.24), lineWidth: DS.Stroke.hairline)
            )
    }
}

// MARK: - 轻量图表原语（对应 DESIGN.md Chart Visual Language）

/// 微柱状图（chart.bar.radius 1.5 / gap 3 / 最小值 2×3）
struct DSMicroHistogram: View {
    let values: [Double?]         // 0…1；nil 是缺失样本，0 是已知零值
    var color: Color = DS.Chart.series01
    var height: CGFloat = 36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let barWidth = max(2, (proxy.size.width - CGFloat(max(values.count - 1, 0)) * 3) / CGFloat(max(values.count, 1)))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let clamped = value.map { min(max($0, 0), 1) }
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(clamped == nil ? Color.secondary.opacity(0.14) : color.opacity(0.70))
                        .frame(width: barWidth, height: max(3, height * (clamped ?? 0)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.chartHistogram), value: values)
    }
}

/// 十段校准仪表（chart.meter.segment.*）
struct DSSegmentedMeter: View {
    let progress: Double          // 0…1
    var color: Color = DS.Chart.series01
    var cautionColor: Color? = DS.Semantic.statusCaution
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 1.25) {
            ForEach(0..<10, id: \.self) { index in
                let active = Double(index) < round(progress * 10)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(active ? segmentColor(index: index) : Color.primary.opacity(0.15))
                    .frame(width: 14, height: 8)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.chartMeter), value: progress)
    }

    private func segmentColor(index: Int) -> Color {
        guard let cautionColor, index >= 8 else { return color }
        return cautionColor
    }
}

/// 迷你环形进度（chart.donut.*，8 pt 描边）
struct DSDonut: View {
    let fraction: Double
    var color: Color = DS.Chart.series01
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color.opacity(0.78), style: StrokeStyle(lineWidth: 8, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                .font(DS.Typeface.data)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.chartDonut), value: fraction)
    }
}

/// 面积折线（轻量：单一 Path 绘制，无模糊无阴影）
struct DSLineChart: View {
    let samples: [Double?]        // 0…1；nil 表示缺失，不与真实 0 混淆
    var color: Color = DS.Chart.series01
    var showArea: Bool = true
    var height: CGFloat = 48
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let n = max(samples.count - 1, 1)
            let points: [CGPoint?] = samples.enumerated().map { index, value in
                value.map {
                    CGPoint(
                    x: n == 0 ? 0 : (CGFloat(index) / CGFloat(n)) * w,
                        y: h - CGFloat(min(max($0, 0), 1)) * (h - 4) - 2
                    )
                }
            }
            ZStack {
                if showArea {
                    areaPath(points: points, height: h).fill(
                        LinearGradient(
                            colors: [color.opacity(DS.Chart.areaOpacity), color.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                linePath(points: points).stroke(
                    color,
                    style: StrokeStyle(lineWidth: DS.Chart.lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.sample), value: samples)
    }

    private func linePath(points: [CGPoint?]) -> Path {
        var path = Path()
        var startsSegment = true
        for point in points {
            guard let point else {
                startsSegment = true
                continue
            }
            if startsSegment {
                path.move(to: point)
                startsSegment = false
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func areaPath(points: [CGPoint?], height: CGFloat) -> Path {
        var path = Path()
        var segment: [CGPoint] = []

        func appendSegment(_ segment: [CGPoint], to path: inout Path) {
            guard segment.count > 1, let first = segment.first, let last = segment.last else { return }
            path.move(to: first)
            for point in segment.dropFirst() { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
        }

        for point in points {
            if let point {
                segment.append(point)
            } else {
                appendSegment(segment, to: &path)
                segment.removeAll(keepingCapacity: true)
            }
        }
        appendSegment(segment, to: &path)
        return path
    }
}
// MARK: - 激活门户组件

/// 门户页脚链接：caption 字号、secondary 色，hover 转 primary 并加下划线。
struct DSFooterButtonStyle: ButtonStyle {
    var destructive: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isHovering && controlActiveState == .active
        configuration.label
            .font(DS.Typeface.caption)
            .foregroundStyle(destructive ? DS.Semantic.statusCritical : (active ? Color.primary : Color.secondary))
            .underline(active)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.hover)) {
                    isHovering = hovering
                }
            }
            .onChange(of: controlActiveState) { _, state in
                if state != .active { isHovering = false }
            }
    }
}

extension ButtonStyle where Self == DSFooterButtonStyle {
    static func dsFooterLink(destructive: Bool = false) -> DSFooterButtonStyle {
        DSFooterButtonStyle(destructive: destructive)
    }
}

