import AgentNestCore
import SwiftUI

/// 激活门户 v2：参考 Raycast / Linear / Arc / CleanShot 的 onboarding 惯例。
/// 固定深色外观；分屏 Hero（左：overline + 主标题 + 副标题 + 双 CTA + 信任徽章；右：产品预览窗口）；
/// 2×2 能力卡；页脚。动效为一次性入场编排（无循环），尊重 Reduce Motion。
struct ActivationView: View {
    @Bindable var model: AppModel
    @State private var showKeyEntry = false
    @State private var appeared = false
    @State private var showAbout = false
    @State private var showPrivacy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            DSCanvasBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.x400) {
                    topBar
                    hero
                    featureGrid
                    footerRow
                }
                .frame(maxWidth: DS.Layout.activationMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Layout.pageHorizontalInset)
                .padding(.vertical, DS.Layout.pageVerticalInset)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { appeared = true }
        .sheet(isPresented: $showAbout) { AboutSheet(model: model).preferredColorScheme(.dark) }
        .sheet(isPresented: $showPrivacy) { PrivacySheet(model: model).preferredColorScheme(.dark) }
    }

    /// 一次性入场编排：各段按 entranceStagger 错峰 fade + 8pt 上移；Reduce Motion 直接落定。
    private func entranceAnimation(stage: Int) -> Animation {
        .easeOut(duration: DS.Motion.enter).delay(DS.Motion.entranceStagger * Double(stage))
    }

    // MARK: 顶部品牌行

    private var topBar: some View {
        HStack(spacing: DS.Space.x250) {
            Image(systemName: "bird.fill")
                .font(.system(size: DS.IconSize.brand, weight: .medium))
                .foregroundStyle(DS.Semantic.accentPrimary)
            Text("AgentNest")
                .font(DS.Typeface.section)
            Spacer()
            Button(model.localized("关于")) { showAbout = true }
                .buttonStyle(.dsFooterLink())
            portalDot
            Button(model.localized("隐私说明")) { showPrivacy = true }
                .buttonStyle(.dsFooterLink())
            portalDot
            Button(model.localized("退出")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.dsFooterLink())
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(reduceMotion ? nil : entranceAnimation(stage: 0), value: appeared)
    }

    private var portalDot: some View {
        Text("·")
            .font(DS.Typeface.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: DS.Space.x400) {
            heroCopy
                .frame(maxWidth: 440, alignment: .leading)
            Spacer(minLength: 0)
            DSProductPreview(model: model)
        }
        .padding(.vertical, DS.Space.x450)
        .background(
            DSHeroWash()
                .frame(width: 760, height: 480)
                .offset(x: 300, y: -140)
                .allowsHitTesting(false)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(reduceMotion ? nil : entranceAnimation(stage: 1), value: appeared)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Text(model.localized("AGENTNEST · 本机 AGENT 环境"))
                .font(DS.Typeface.label)
                .tracking(1.1)
                .foregroundStyle(DS.Semantic.accentPrimary)
            Text(model.localized("你的 Agent，一站式打理。"))
                .font(DS.Typeface.displayLarge)
                .tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.localized("安装、空间、配置与 Skill——发现、整理、观测、维护，一站式完成。"))
                .font(DS.Typeface.lead)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.x100)

            actionArea
                .padding(.top, DS.Space.x250)

            statusArea
                .padding(.top, DS.Space.x200)

            trustRow
                .padding(.top, DS.Space.x300)
        }
    }

    // MARK: 行动区（双路径）

    @ViewBuilder
    private var actionArea: some View {
        if model.licenseConfigurationAvailable {
            VStack(alignment: .leading, spacing: DS.Space.x250) {
                trialButton
                activationDisclosure
            }
        } else {
            devBuildHint
        }
    }

    @ViewBuilder
    private var trialButton: some View {
        if model.activationPhase == .trialInFlight {
            Button {} label: {
                HStack(spacing: DS.Space.x150) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(model.localized("正在请求授权…"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dsAction(.accent, size: .hero))
            .frame(width: 320)
            .disabled(true)
            .accessibilityLabel(model.localized("正在请求授权…"))
        } else {
            Button { model.startTrial() } label: {
                Text(model.localized("免费试用 7 天"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dsAction(.accent, size: .hero))
            .frame(width: 320)
            .keyboardShortcut(.defaultAction)
            .disabled(model.activationPhase == .activateInFlight)
        }
    }

    private var activationDisclosure: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.state)) {
                    showKeyEntry.toggle()
                }
            } label: {
                HStack(spacing: DS.Space.x100) {
                    Text(model.localized("已有授权密钥？"))
                        .foregroundStyle(.secondary)
                    Text(model.localized("输入密钥激活"))
                        .foregroundStyle(DS.Semantic.accentPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.IconSize.sortIndicator, weight: .semibold))
                        .foregroundStyle(DS.Semantic.accentPrimary)
                        .rotationEffect(.degrees(showKeyEntry ? 90 : 0))
                }
                .font(DS.Typeface.body)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.activationPhase != .idle)
            .accessibilityHint(model.localized("输入授权密钥并激活这台设备。"))

            if showKeyEntry {
                keyEntryForm
                    .transition(.opacity)
            }
        }
    }

    private var keyEntryForm: some View {
        HStack(spacing: DS.Space.x200) {
                SecureField(model.localized("License Key"), text: $model.licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typeface.data)
                    .onSubmit { model.activate() }
                    .disabled(model.activationPhase != .idle)
                if model.activationPhase == .activateInFlight {
                    Button {} label: {
                        HStack(spacing: DS.Space.x150) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text(model.localized("正在请求授权…"))
                        }
                    }
                    .buttonStyle(.dsAction(.accent))
                    .disabled(true)
                } else {
                    Button(model.localized("激活")) { model.activate() }
                        .buttonStyle(.dsAction(.accent))
                        .disabled(
                            model.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.activationPhase != .idle
                        )
                }
        }
    }

    private var devBuildHint: some View {
        DSRecessed {
            Text(model.localized("开发构建需配置 AGENTNEST_LICENSE_SERVER_URL 与 AGENTNEST_LICENSE_PUBLIC_KEY。"))
                .font(DS.Typeface.caption)
                .foregroundStyle(DS.Semantic.statusCaution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 状态区（只在有真实信息时出现）

    @ViewBuilder
    private var statusArea: some View {
        if let message = activationErrorMessage {
            DSRecessed {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.x200) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Semantic.statusCritical)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(DS.Typeface.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !isMissingState {
            HStack(spacing: DS.Space.x200) {
                DSBadge(text: model.licenseStatusText, color: statusBadgeColor, filled: statusBadgeFilled)
                if case .serviceUnavailable = model.licenseState {
                    Button(model.localized("重试授权服务")) { model.retryLicense() }
                        .buttonStyle(.dsAction(size: .compact))
                        .disabled(model.activationPhase != .idle)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var isMissingState: Bool {
        if case .missing = model.licenseState { return true }
        return false
    }

    private var statusBadgeColor: Color {
        switch model.licenseState {
        case .missing: DS.Semantic.statusCaution
        case .valid(let payload): payload.plan == "trial" ? DS.Semantic.statusPositive : DS.Semantic.accentPrimary
        case .needsRefresh: DS.Semantic.statusCaution
        case .expired, .invalid, .rejected: DS.Semantic.statusCritical
        case .serviceUnavailable: DS.Semantic.directionA
        }
    }

    private var statusBadgeFilled: Bool {
        switch model.licenseState {
        case .valid: true
        default: false
        }
    }

    private var activationErrorMessage: String? {
        switch model.licenseState {
        case .expired: model.localized("试用或授权已到期")
        case .invalid(let error): model.localized("本地授权无效：%@", error.rawValue)
        case .rejected(let code): model.localized("授权被服务端拒绝：%@", code)
        default: nil
        }
    }

    // MARK: 信任徽章

    private var trustRow: some View {
        HStack(spacing: DS.Space.x300) {
            DSTrustBadge(systemImage: "cpu", text: model.localized("本机分析"))
            DSTrustBadge(systemImage: "lock.shield", text: model.localized("数据不出这台 Mac"))
            DSTrustBadge(systemImage: "checkmark.seal", text: model.localized("设备绑定 · Ed25519 验签"))
        }
    }

    // MARK: 能力卡（2×2）

    private var featureGrid: some View {
        DSCard(padding: DS.Space.x300) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: DS.Space.x300) {
                    DSFeatureRow(
                        systemImage: "magnifyingglass",
                        title: model.localized("安装"),
                        detail: model.localized("自动定位 Agent 安装与 Home，核验归属与证据。"),
                        color: DS.Semantic.accentPrimary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DSFeatureRow(
                        systemImage: "internaldrive",
                        title: model.localized("空间"),
                        detail: model.localized("唯一物理账本，可回收空间一眼可见。"),
                        color: DS.Semantic.directionA
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: DS.Stroke.hairline)
                    .padding(.vertical, DS.Space.x300)
                HStack(alignment: .top, spacing: DS.Space.x300) {
                    DSFeatureRow(
                        systemImage: "waveform.path.ecg",
                        title: model.localized("活动"),
                        detail: model.localized("CPU、磁盘、网络，实时一览。"),
                        color: DS.Semantic.directionB
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DSFeatureRow(
                        systemImage: "hammer",
                        title: model.localized("Skill"),
                        detail: model.localized("索引、编辑、补齐，一步到位。"),
                        color: DS.Semantic.accentSecondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(reduceMotion ? nil : entranceAnimation(stage: 2), value: appeared)
    }

    // MARK: 页脚

    private var footerRow: some View {
        HStack(spacing: DS.Space.x300) {
            Text(model.localized("版本 %@", versionText))
                .font(DS.Typeface.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button(model.localized("删除本地数据"), role: .destructive) { model.deleteLocalData() }
                .buttonStyle(.dsFooterLink(destructive: true))
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(reduceMotion ? nil : entranceAnimation(stage: 3), value: appeared)
    }

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

/// 门户 Hero 氛围渐变（DESIGN.md §5.7 登记的装饰渐变例外）：
/// 单层静态 RadialGradient，无模糊、无辉光、无循环、不覆盖内容区。
struct DSHeroWash: View {
    var body: some View {
        RadialGradient(
            colors: [
                DS.Semantic.accentPrimary.opacity(0.12),
                DS.Semantic.accentPrimary.opacity(0.04),
                Color.clear
            ],
            center: UnitPoint(x: 0.72, y: 0.02),
            startRadius: 10,
            endRadius: 620
        )
        .allowsHitTesting(false)
    }
}

/// 信任徽章：图标 + 一句真实事实，caption 字号。
struct DSTrustBadge: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.x150) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Semantic.accentPrimary)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 能力行：图标 + 标题 + 一句话，用于门户 2×2 能力卡。
struct DSFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String
    var color: Color = DS.Semantic.accentPrimary

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.x300) {
            Image(systemName: systemImage)
                .font(.system(size: DS.IconSize.card, weight: .medium))
                .foregroundStyle(color)
                .frame(
                    width: DS.Layout.activationFeatureIconFrame,
                    height: DS.Layout.activationFeatureIconFrame
                )
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .fill(color.opacity(DS.Opacity.fillSubtle))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .strokeBorder(color.opacity(DS.Opacity.iconBorder), lineWidth: DS.Stroke.hairline)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                Text(title)
                    .font(DS.Typeface.section)
                Text(detail)
                    .font(DS.Typeface.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 产品预览窗口：用真实 DS 原语绘制 Home 页缩影（窗口 chrome + 首部 + 进度 + 图表 + 徽章）。
/// 它是产品本身，不是虚构装饰；柱图与环形做一次性绘制入场，面积折线静态。
struct DSProductPreview: View {
    let model: AppModel
    @State private var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lineSamples: [Double?] {
        [0.30, 0.38, 0.34, 0.46, 0.42, 0.54, 0.49, 0.60, 0.56, 0.65, 0.61, 0.71]
    }

    private var histogramSamples: [Double?] {
        [0.25, 0.48, 0.36, 0.68, 0.52, 0.78, 0.60, 0.42, 0.57, 0.72, 0.50, 0.84]
    }

    var body: some View {
        DSCard(padding: 0) {
            VStack(spacing: 0) {
                chromeBar
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: DS.Stroke.hairline)
                interior
            }
        }
        .frame(width: 440)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.chartDonut).delay(DS.Motion.entranceStagger * 2)) {
                live = true
            }
        }
    }

    private var chromeBar: some View {
        HStack(spacing: DS.Space.x150) {
            Circle().fill(Color(nsColor: .systemRed).opacity(0.92)).frame(width: 10, height: 10)
            Circle().fill(Color(nsColor: .systemYellow).opacity(0.92)).frame(width: 10, height: 10)
            Circle().fill(Color(nsColor: .systemGreen).opacity(0.92)).frame(width: 10, height: 10)
            Spacer()
            Text("AgentNest")
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Color.clear.frame(width: 10, height: 10)
        }
        .padding(.horizontal, DS.Space.x300)
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private var interior: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            headerRow
            progressRow
            chartRow
            histogramRow
            badgesRow
        }
        .padding(DS.Space.x300)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

    private var headerRow: some View {
        HStack(spacing: DS.Space.x250) {
            Image(systemName: "bird.fill")
                .font(.system(size: DS.IconSize.navigation, weight: .medium))
                .foregroundStyle(DS.Semantic.accentPrimary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .fill(DS.Semantic.accentPrimary.opacity(DS.Opacity.fillSubtle))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .strokeBorder(DS.Semantic.accentPrimary.opacity(DS.Opacity.iconBorder), lineWidth: DS.Stroke.hairline)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.x050) {
                Text(model.localized("发现并维护你的 Agent 环境"))
                    .font(DS.Typeface.body)
                    .fontWeight(.semibold)
                Text(model.localized("数据只在本机分析。"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(model.localized("扫描"))
                .font(DS.Typeface.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Space.x250)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                        .fill(DS.Semantic.accentPrimary.opacity(0.86))
                )
        }
    }

    private var progressRow: some View {
        DSRecessed {
            HStack(spacing: DS.Space.x250) {
                Image(systemName: "scope")
                    .font(.system(size: DS.IconSize.navigation, weight: .medium))
                    .foregroundStyle(DS.Semantic.accentPrimary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.x150) {
                    HStack {
                        Text(model.localized("正在分析 Agent 目录"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("62%")
                            .font(DS.Typeface.data)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(DS.Semantic.accentPrimary.opacity(0.80))
                                .frame(width: proxy.size.width * (live ? 0.62 : 0))
                        }
                    }
                    .frame(height: 4)
                    .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.chartDonut), value: live)
                }
            }
        }
    }

    private var chartRow: some View {
        HStack(alignment: .top, spacing: DS.Space.x300) {
            VStack(alignment: .leading, spacing: DS.Space.x150) {
                Text(model.localized("CPU 趋势"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                DSLineChart(samples: lineSamples, showArea: true, height: 44)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: DS.Space.x150) {
                Text(model.localized("磁盘"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                DSDonut(fraction: live ? 0.62 : 0, color: DS.Chart.series02, size: 44)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 120)
        }
    }

    private var histogramRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.x150) {
            Text(model.localized("速率分布"))
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
            DSMicroHistogram(
                values: live ? histogramSamples : histogramSamples.map { _ in nil },
                height: 24
            )
        }
    }

    private var badgesRow: some View {
        HStack(spacing: DS.Space.x200) {
            DSBadge(text: model.localized("已确认"), color: DS.Semantic.statusPositive, filled: true)
            DSBadge(text: model.localized("疑似"), color: DS.Semantic.statusCaution)
            Text(model.localized("%d 个 Home", 3))
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// 关于：品牌、版本与一句定位。
private struct AboutSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return model.localized("版本 %@", version)
    }

    var body: some View {
        VStack(spacing: DS.Space.x300) {
            Image(systemName: "bird.fill")
                .font(.system(size: DS.IconSize.page, weight: .medium))
                .foregroundStyle(DS.Semantic.accentPrimary)
                .frame(width: DS.Layout.heroIconFrame, height: DS.Layout.heroIconFrame)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .fill(DS.Semantic.accentPrimary.opacity(DS.Opacity.fillSubtle))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .strokeBorder(DS.Semantic.accentPrimary.opacity(DS.Opacity.iconBorder), lineWidth: DS.Stroke.hairline)
                )
                .accessibilityHidden(true)

            Text("AgentNest")
                .font(DS.Typeface.title)
            Text(model.localized("本机 Agent 环境仪器"))
                .font(DS.Typeface.body)
                .foregroundStyle(.secondary)
            Text(versionText)
                .font(DS.Typeface.caption)
                .foregroundStyle(.tertiary)

            Button(model.localized("关闭")) { dismiss() }
                .buttonStyle(.dsAction())
        }
        .padding(DS.Space.x400)
        .frame(width: 380)
        .background(Color(nsColor: DS.Neutral.canvas))
    }
}

/// 隐私说明：三个要点，全部复用既有事实性文案，不新增承诺。
private struct PrivacySheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x400) {
            HStack(spacing: DS.Space.x250) {
                Image(systemName: "hand.raised")
                    .font(.system(size: DS.IconSize.card, weight: .medium))
                    .foregroundStyle(DS.Semantic.accentPrimary)
                Text(model.localized("隐私说明"))
                    .font(DS.Typeface.title)
            }

            DSCard(padding: DS.Space.x400) {
                VStack(alignment: .leading, spacing: DS.Space.x300) {
                    privacySection(
                        title: model.localized("扫描范围"),
                        detail: model.localized("仅扫描 Agent Definition 声明和你明确添加的 Agent Home，数据只在本机分析。")
                    )
                    privacyDivider
                    privacySection(
                        title: model.localized("历史与导出"),
                        detail: model.localized("在设置中明确开启后才创建本地历史数据库。")
                    )
                    privacyDivider
                    privacySection(
                        title: model.localized("授权信息"),
                        detail: model.localized("试用和设备额度由授权服务记录。本机只信任绑定设备且经过 Ed25519 验签的限时 Receipt。")
                    )
                }
            }

            HStack {
                Spacer()
                Button(model.localized("关闭")) { dismiss() }
                    .buttonStyle(.dsAction())
            }
        }
        .padding(DS.Space.x400)
        .frame(width: 460)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

    private func privacySection(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            Text(title)
                .font(DS.Typeface.label)
            Text(detail)
                .font(DS.Typeface.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: DS.Stroke.hairline)
    }
}
