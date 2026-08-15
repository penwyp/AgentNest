import AgentNestCore
import AppKit
import SwiftUI

// MARK: - 市场分区

private enum MarketSection: String, CaseIterable, Identifiable {
    case agents = "Agent 市场"
    case skills = "Skills 市场"
    case mcp = "MCP 市场"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .agents: "cpu"
        case .skills: "hammer"
        case .mcp: "network"
        }
    }
}

// MARK: - 市场页

/// 市场页：侧边栏一级目的地。使用分段控件在 Agent / Skills / MCP 三类目录间切换，
/// 每类目录都提供搜索、状态横幅与自适应卡片网格。
struct MarketView: View {
    @Bindable var model: AppModel
    @State private var section: MarketSection = .agents
    @State private var searchText = ""
    @State private var copiedItemID: String?

    private var summary: String {
        model.localized(
            "%d 个 Agent · %d 个 Skill · %d 个 MCP",
            model.marketDefinitions.count,
            model.marketplaceSkillItems.count,
            model.marketplaceMCPServers.count
        )
    }

    var body: some View {
        ScrollView {
            marketContent
                .padding(.horizontal, DS.Layout.pageHorizontalInset)
                .padding(.vertical, DS.Layout.pageVerticalInset)
                .frame(maxWidth: DS.Layout.marketPageMaxWidth)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            marketHeader
        }
        .animation(.easeInOut(duration: DS.Motion.state), value: section)
    }

    @ViewBuilder
    private var marketContent: some View {
        switch section {
        case .agents:
            AgentMarketCatalogView(model: model, searchText: searchText)
        case .skills:
            SkillsMarketCatalogView(
                model: model,
                searchText: searchText,
                copiedItemID: copiedItemID,
                copy: copy
            )
        case .mcp:
            MCPServerMarketCatalogView(
                model: model,
                searchText: searchText,
                copiedItemID: copiedItemID,
                copy: copy
            )
        }
    }

    /// 固定页头：页面身份在上，分段控件与搜索栏同处一行；tab 栏保持紧凑宽度。
    private var marketHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            DSPageIdentity(
                title: model.localized("市场"),
                glyph: "storefront",
                detail: summary
            ) {
                EmptyView()
            }
            HStack(alignment: .center, spacing: DS.Space.x300) {
                marketSectionPicker
                Spacer(minLength: DS.Space.x250)
                marketSearchField
            }
        }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .frame(maxWidth: DS.Layout.marketPageMaxWidth)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

    /// 业界目录型市场常用的 segmented filter：图标 + 标题 + 数量，选中态为抬升胶囊。
    private var marketSectionPicker: some View {
        HStack(spacing: DS.Space.x100) {
            ForEach(MarketSection.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: DS.Motion.state)) {
                        section = item
                        searchText = ""
                    }
                } label: {
                    HStack(spacing: DS.Space.x200) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.localized(item.rawValue))
                            .font(DS.Typeface.body.weight(.semibold))
                        Text("\(count(for: item))")
                            .font(DS.Typeface.micro.monospacedDigit())
                            .foregroundStyle(section == item ? DS.Semantic.accentPrimary : Color.secondary)
                            .padding(.horizontal, DS.Space.x150)
                            .padding(.vertical, 1)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(DS.Opacity.fillQuiet))
                            )
                    }
                    .foregroundStyle(section == item ? DS.Semantic.accentPrimary : Color.secondary)
                    .padding(.horizontal, DS.Space.x300)
                    .frame(height: 34)
                    .background {
                        if section == item {
                            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                                .fill(Color(nsColor: DS.Neutral.raised))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                            .strokeBorder(
                                section == item
                                    ? DS.Semantic.accentPrimary.opacity(0.30)
                                    : Color.clear,
                                lineWidth: DS.Stroke.surface
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.x100)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.controlRegular, style: .continuous)
                .fill(Color(nsColor: DS.Neutral.recessed))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.controlRegular, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
    }

    private var marketSearchField: some View {
        HStack(spacing: DS.Space.x200) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.Typeface.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !searchText.isEmpty {
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
        .frame(width: DS.Layout.marketSearchWidth, height: DS.Layout.agentSearchHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderQuiet), lineWidth: DS.Stroke.hairline)
        )
    }

    private var searchPlaceholder: String {
        switch section {
        case .agents: model.localized("搜索 Agent")
        case .skills: model.localized("搜索 Skill")
        case .mcp: model.localized("搜索 MCP 服务器")
        }
    }

    private func count(for section: MarketSection) -> Int {
        switch section {
        case .agents: model.marketDefinitions.count
        case .skills: model.marketplaceSkillItems.count
        case .mcp: model.marketplaceMCPServers.count
        }
    }

    private func copy(_ text: String, id: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedItemID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if copiedItemID == id { copiedItemID = nil }
        }
    }
}

// MARK: - Agent 市场

private struct AgentMarketCatalogView: View {
    @Bindable var model: AppModel
    let searchText: String

    private var filteredDefinitions: [AgentDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.marketDefinitions }
        return model.marketDefinitions.filter { definition in
            definition.displayName.localizedCaseInsensitiveContains(query) ||
                definition.id.localizedCaseInsensitiveContains(query) ||
                (definition.marketplace?.summary.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var hasCompletedInstall: Bool {
        model.marketInstallations.values.contains { $0.phase == .completed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            if hasCompletedInstall {
                completedBanner
            }
            if filteredDefinitions.isEmpty {
                marketEmptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360, maximum: 480), spacing: DS.Space.x300)],
                    alignment: .leading,
                    spacing: DS.Space.x300
                ) {
                    ForEach(filteredDefinitions, id: \.id) { definition in
                        AgentMarketCard(model: model, definition: definition)
                    }
                }
            }
        }
    }

    private var completedBanner: some View {
        DSRecessed {
            HStack(spacing: DS.Space.x300) {
                Label(model.localized("已安装的 Agent 会在下次扫描后纳入环境。"), systemImage: "checkmark.circle.fill")
                    .font(DS.Typeface.body)
                    .foregroundStyle(DS.Semantic.statusPositive)
                Spacer(minLength: DS.Space.x300)
                Button {
                    model.startScan()
                } label: {
                    Label(model.localized("重新扫描"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.dsAction(.accent, size: .compact))
            }
        }
    }

    private var marketEmptyState: some View {
        ContentUnavailableView(
            model.localized("暂无匹配的市场项目。"),
            systemImage: "magnifyingglass",
            description: Text(model.localized("试试其它关键词或切换市场分类。"))
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

/// Agent 市场卡：品牌图标 + 名称/简介 + 安装方式徽章/主页链接 + 状态（已安装/安装/安装中/失败）。
private struct AgentMarketCard: View {
    let model: AppModel
    let definition: AgentDefinition

    private var state: AppModel.MarketInstallState? {
        model.marketInstallations[definition.id]
    }

    private var installed: Bool {
        if state?.phase == .completed { return true }
        if model.installedMarketProductIDs.contains(definition.id) { return true }
        return model.snapshot?.products.contains { $0.id == definition.id && !$0.homes.isEmpty } ?? false
    }

    private var isBusy: Bool {
        state?.phase == .locatingBrew || state?.phase == .running
    }

    var body: some View {
        DSCard(padding: DS.Space.x400) {
            VStack(alignment: .leading, spacing: DS.Space.x300) {
                HStack(alignment: .top, spacing: DS.Space.x300) {
                    HomeBrandIcon(productID: definition.id, size: 32)
                    VStack(alignment: .leading, spacing: DS.Space.x050) {
                        Text(definition.displayName)
                            .font(DS.Typeface.section)
                            .lineLimit(1)
                        if let summary = definition.marketplace?.summary {
                            Text(summary)
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: DS.Space.x200)
                    if installed {
                        DSBadge(text: model.localized("已安装"), color: DS.Semantic.statusPositive)
                    } else if definition.marketplace?.install == nil {
                        Text(model.localized("暂无安装方式"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        actionButton
                    }
                }

                HStack(spacing: DS.Space.x200) {
                    if let method = definition.marketplace?.install {
                        DSBadge(text: method.kind == .brew ? "brew" : "cask", color: .secondary)
                    }
                    if let url = definition.marketplace?.homepageURL, let link = URL(string: url) {
                        Link(destination: link) {
                            Text(url)
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button {
                            NSWorkspace.shared.open(link)
                        } label: {
                            Label(model.localized("打开主页"), systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.dsAction(size: .compact))
                        .accessibilityHint(model.localized("打开主页"))
                    }
                }

                if isBusy {
                    installProgress
                } else if case let .failed(failure) = state?.phase {
                    Label(model.installFailureTitle(failure), systemImage: "exclamationmark.triangle")
                        .font(DS.Typeface.caption)
                        .foregroundStyle(DS.Semantic.statusCritical)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var actionButton: some View {
        Group {
            if isBusy {
                Button(model.localized("取消")) { model.cancelMarketInstall(definition.id) }
                    .buttonStyle(.dsAction(size: .compact))
            } else if case .failed = state?.phase {
                Button(model.localized("重试")) { model.startMarketInstall(definition.id) }
                    .buttonStyle(.dsAction(.accent, size: .compact))
                    .disabled(model.isAnyMarketInstallRunning || !model.allows(.install))
            } else {
                Button { model.startMarketInstall(definition.id) } label: {
                    Label(model.localized("安装"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.dsAction(.accent, size: .compact))
                .disabled(model.isAnyMarketInstallRunning || !model.allows(.install))
            }
        }
    }

    private var installProgress: some View {
        DSRecessed {
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                HStack(spacing: DS.Space.x200) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(state?.phase == .locatingBrew
                        ? model.localized("正在定位 Homebrew")
                        : model.localized("正在安装 %@", definition.displayName))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
                if let tail = state?.outputTail, !tail.isEmpty {
                    Text(tail.joined(separator: "\n"))
                        .font(DS.Typeface.data)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Skills 市场

private struct SkillsMarketCatalogView: View {
    @Bindable var model: AppModel
    let searchText: String
    let copiedItemID: String?
    let copy: (String, String) -> Void

    private var filteredItems: [SkillMarketplaceItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.marketplaceSkillItems }
        return model.marketplaceSkillItems.filter { item in
            item.name.localizedCaseInsensitiveContains(query) ||
                item.publisher.localizedCaseInsensitiveContains(query) ||
                item.summary.localizedCaseInsensitiveContains(query) ||
                item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            DSRecessed {
                Label(
                    model.localized("Skills 通过 git clone 安装到 Agent 的 skills 目录，安装后请重新扫描。"),
                    systemImage: "terminal"
                )
                .font(DS.Typeface.body)
                .foregroundStyle(.secondary)
            }
            if filteredItems.isEmpty {
                ContentUnavailableView(
                    model.localized("暂无匹配的市场项目。"),
                    systemImage: "magnifyingglass",
                    description: Text(model.localized("试试其它关键词或切换市场分类。"))
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320, maximum: 400), spacing: DS.Space.x300)],
                    alignment: .leading,
                    spacing: DS.Space.x300
                ) {
                    ForEach(filteredItems) { item in
                        SkillMarketCard(
                            model: model,
                            item: item,
                            copied: copiedItemID == item.id,
                            copy: copy
                        )
                    }
                }
            }
        }
    }
}

private struct SkillMarketCard: View {
    let model: AppModel
    let item: SkillMarketplaceItem
    let copied: Bool
    let copy: (String, String) -> Void

    private var tint: Color {
        MarketCategoryStyle.color(for: item.category)
    }

    var body: some View {
        DSCard(padding: DS.Space.x400) {
            VStack(alignment: .leading, spacing: DS.Space.x300) {
                HStack(alignment: .top, spacing: DS.Space.x300) {
                    MarketIconTile(symbol: MarketCategoryStyle.symbol(for: item.category), tint: tint)
                    VStack(alignment: .leading, spacing: DS.Space.x050) {
                        Text(item.publisher)
                            .font(DS.Typeface.micro.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        Text(item.name)
                            .font(DS.Typeface.section)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.x200)
                    VStack(alignment: .trailing, spacing: DS.Space.x100) {
                        DSBadge(
                            text: model.localized(item.verified ? "官方" : "社区"),
                            color: item.verified ? DS.Semantic.statusPositive : DS.Semantic.directionB
                        )
                        DSBadge(text: model.localized(item.category), color: tint)
                    }
                }

                Text(item.summary)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                marketTags

                HStack(spacing: DS.Space.x200) {
                    if let url = URL(string: item.homepageURL) {
                        Link(destination: url) {
                            Label(model.localized("打开主页"), systemImage: "safari")
                                .font(DS.Typeface.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Semantic.accentPrimary)
                    }
                    Spacer(minLength: DS.Space.x200)
                    Button {
                        copy(item.installCommand, item.id)
                    } label: {
                        Label(
                            copied ? model.localized("已复制") : model.localized("复制安装命令"),
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.dsAction(.accent, size: .compact))
                }
            }
        }
    }

    private var marketTags: some View {
        HStack(spacing: DS.Space.x150) {
            ForEach(Array(item.tags.prefix(4).enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.x200)
                    .padding(.vertical, DS.Space.x050 + 1)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(DS.Opacity.fillFaint)))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - MCP 市场

private struct MCPServerMarketCatalogView: View {
    @Bindable var model: AppModel
    let searchText: String
    let copiedItemID: String?
    let copy: (String, String) -> Void

    private var filteredItems: [MCPServerMarketplaceItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.marketplaceMCPServers }
        return model.marketplaceMCPServers.filter { item in
            item.name.localizedCaseInsensitiveContains(query) ||
                item.publisher.localizedCaseInsensitiveContains(query) ||
                item.summary.localizedCaseInsensitiveContains(query) ||
                item.category.localizedCaseInsensitiveContains(query) ||
                item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x300) {
            DSRecessed {
                Label(
                    model.localized("MCP 配置可直接粘贴到 Claude Desktop 或支持 MCP 的客户端。"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(DS.Typeface.body)
                .foregroundStyle(.secondary)
            }
            if filteredItems.isEmpty {
                ContentUnavailableView(
                    model.localized("暂无匹配的市场项目。"),
                    systemImage: "magnifyingglass",
                    description: Text(model.localized("试试其它关键词或切换市场分类。"))
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 430, maximum: 560), spacing: DS.Space.x300)],
                    alignment: .leading,
                    spacing: DS.Space.x300
                ) {
                    ForEach(filteredItems) { item in
                        MCPServerMarketCard(
                            model: model,
                            item: item,
                            copiedItemID: copiedItemID,
                            copy: copy
                        )
                    }
                }
            }
        }
    }
}

private struct MCPServerMarketCard: View {
    let model: AppModel
    let item: MCPServerMarketplaceItem
    let copiedItemID: String?
    let copy: (String, String) -> Void
    @State private var showsConfiguration = false

    private var configurationCopied: Bool { copiedItemID == item.id }
    private var commandCopied: Bool { copiedItemID == "\(item.id)-command" }

    private var tint: Color {
        MarketCategoryStyle.color(for: item.category)
    }

    private var transportTitle: String {
        model.localized(item.transport.rawValue)
    }

    var body: some View {
        DSCard(padding: DS.Space.x400) {
            VStack(alignment: .leading, spacing: DS.Space.x300) {
                HStack(alignment: .top, spacing: DS.Space.x300) {
                    MarketIconTile(symbol: MarketCategoryStyle.symbol(for: item.category), tint: tint)
                    VStack(alignment: .leading, spacing: DS.Space.x050) {
                        Text(item.publisher)
                            .font(DS.Typeface.micro.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        Text(item.name)
                            .font(DS.Typeface.section)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.x200)
                    VStack(alignment: .trailing, spacing: DS.Space.x100) {
                        DSBadge(
                            text: model.localized(item.verified ? "官方" : "社区"),
                            color: item.verified ? DS.Semantic.statusPositive : DS.Semantic.directionB
                        )
                        DSBadge(text: transportTitle, color: .secondary)
                    }
                }

                Text(item.summary)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                marketTags

                commandPreview

                if showsConfiguration {
                    configurationPreview
                }

                HStack(spacing: DS.Space.x200) {
                    if let url = URL(string: item.homepageURL) {
                        Link(destination: url) {
                            Label(model.localized("打开主页"), systemImage: "safari")
                                .font(DS.Typeface.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Semantic.accentPrimary)
                    }
                    Spacer(minLength: DS.Space.x200)
                    Button {
                        withAnimation(.easeInOut(duration: DS.Motion.state)) {
                            showsConfiguration.toggle()
                        }
                    } label: {
                        Label(
                            showsConfiguration ? model.localized("收起配置") : model.localized("查看配置"),
                            systemImage: showsConfiguration ? "chevron.up" : "chevron.down"
                        )
                    }
                    .buttonStyle(.dsAction(size: .compact))
                    Button {
                        copy(item.configurationJSON(serverKey: item.id) ?? item.installCommand, item.id)
                    } label: {
                        Label(
                            configurationCopied ? model.localized("已复制") : model.localized("复制 MCP 配置"),
                            systemImage: configurationCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.dsAction(.accent, size: .compact))
                }
            }
        }
    }

    private var marketTags: some View {
        HStack(spacing: DS.Space.x150) {
            DSBadge(text: model.localized(item.category), color: tint)
            ForEach(Array(item.tags.prefix(5).enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.x200)
                    .padding(.vertical, DS.Space.x050 + 1)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(DS.Opacity.fillFaint)))
            }
            Spacer(minLength: 0)
        }
    }

    private var commandPreview: some View {
        DSRecessed {
            HStack(spacing: DS.Space.x300) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(item.installCommand)
                    .font(DS.Typeface.data)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: DS.Space.x200)
                Button {
                    copy(item.installCommand, "\(item.id)-command")
                } label: {
                    Image(systemName: commandCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.dsIcon)
                .accessibilityLabel(model.localized("复制命令"))
            }
        }
    }

    private var configurationPreview: some View {
        DSRecessed {
            VStack(alignment: .leading, spacing: DS.Space.x200) {
                Label(model.localized("MCP 配置"), systemImage: "curlybraces")
                    .font(DS.Typeface.label)
                    .foregroundStyle(.secondary)
                Text(item.configurationJSON(serverKey: item.id) ?? "")
                    .font(DS.Typeface.data)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - 市场卡共用视觉

private struct MarketIconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.20), tint.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.26), lineWidth: DS.Stroke.hairline)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }
}

private enum MarketCategoryStyle {
    static func symbol(for category: String) -> String {
        switch category {
        case "development": "chevron.left.forwardslash.chevron.right"
        case "documents": "doc.richtext"
        case "research": "safari"
        case "productivity": "checklist"
        case "browser": "globe"
        case "data": "cylinder.split.1x2"
        case "web": "network"
        case "search": "magnifyingglass"
        case "communication": "bubble.left.and.bubble.right"
        case "observability": "waveform.path.ecg"
        case "creative": "paintpalette"
        default: "square.grid.2x2"
        }
    }

    static func color(for category: String) -> Color {
        switch category {
        case "development": DS.Chart.series01
        case "documents": DS.Chart.series02
        case "research": DS.Chart.series03
        case "productivity": DS.Chart.series04
        case "browser": DS.Chart.series05
        case "data": DS.Chart.series06
        case "web": DS.Chart.series07
        case "search": DS.Chart.series08
        case "communication": DS.Chroma.indigo
        case "observability": DS.Chroma.teal
        case "creative": DS.Chroma.violet
        default: DS.Semantic.accentPrimary
        }
    }
}
