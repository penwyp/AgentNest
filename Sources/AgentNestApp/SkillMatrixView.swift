import AgentNestCore
import SwiftUI

/// Skill 覆盖矩阵主视图：行 = 逻辑 Skill，列 = 具备 Skill 能力的已确认 Home。
/// 横向滚动 + 最小列宽；单元格状态徽标可点击进入安装详情或补齐向导；行尾菜单承载补齐与整体删除。
struct SkillView: View {
    @Bindable var model: AppModel

    @State private var patchSkill: LogicalSkill?
    @State private var patchPreselectedHomeIDs: Set<PhysicalResourceIdentity> = []
    @State private var detailSkill: LogicalSkill?
    @State private var detailHome: AgentHome?
    @State private var resolveSkill: LogicalSkill?
    @State private var resolveHome: AgentHome?
    @State private var deletingSkill: LogicalSkill?
    @State private var localError: String?
    @State private var hoveredRowID: String?
    @State private var hoveredCellKey: String?

    private var homes: [AgentHome] { model.skillCapableHomes }
    private var skillRows: [SkillMatrixRow] {
        guard let index = model.skillIndex else { return [] }
        return index.logicalSkills.map { skill in
            SkillMatrixRow(
                skill: skill,
                cells: homes.map { home in
                    let installations = skill.variants.flatMap(\.installations).filter { $0.homeID == home.id }
                    return SkillMatrixCell(kind: Self.cellKind(for: installations), installations: installations)
                }
            )
        }
    }

    private static func cellKind(for installations: [SkillInstallation]) -> SkillCellKind {
        guard !installations.isEmpty else { return .missing }
        let hashes = Set(installations.map(\.contentHash))
        if hashes.count > 1 { return .conflict }
        if installations.contains(where: { $0.state == .invalid || $0.state == .unreadable }) {
            return .invalid(count: installations.count)
        }
        return .valid(count: installations.count)
    }

    private var identityDetail: String? {
        guard let index = model.skillIndex else { return nil }
        return model.localized(
            "%d 个安装 · %d 个冲突 · %d 个无效",
            index.installationCount, index.conflictCount, index.invalidCount
        )
    }

    var body: some View {
        Group {
            if let index = model.skillIndex, !index.logicalSkills.isEmpty, !homes.isEmpty {
                matrix
            } else if model.snapshot == nil || model.skillIndex == nil {
                DSSkeletonList(sections: [2, 3])
            } else {
                ContentUnavailableView(
                    model.localized("已扫描，但没有已适配的 Skill 来源"),
                    systemImage: "hammer",
                    description: Text(model.localized("已确认的 Agent Home 中没有可识别的 SKILL.md。"))
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { identity }
        .sheet(item: $patchSkill) { skill in
            SkillPatchSheet(
                model: model,
                skill: skill,
                initialTargetHomeIDs: patchPreselectedHomeIDs
            )
        }
        .sheet(item: $detailSkill) { skill in
            if let home = detailHome {
                SkillInstallationDetailSheet(model: model, skill: skill, home: home)
            }
        }
        .sheet(item: $resolveSkill) { skill in
            if let home = resolveHome {
                SkillConflictResolutionSheet(model: model, skill: skill, home: home)
            }
        }
        .alert(
            model.localized("删除整个 Skill %@？", deletingSkill?.name ?? ""),
            isPresented: Binding(get: { deletingSkill != nil }, set: { if !$0 { deletingSkill = nil } }),
            presenting: deletingSkill
        ) { skill in
            Button(model.localized("移到废纸篓"), role: .destructive) {
                model.deleteLogicalSkill(skill)
                deletingSkill = nil
            }
            Button(model.localized("取消"), role: .cancel) { deletingSkill = nil }
        } message: { skill in
            let installations = skill.variants.flatMap(\.installations).filter { $0.isWritable }
            Text(model.localized(
                "将把 %d 个安装移入废纸篓（%d 个 Home）。不会修改 Agent 配置。",
                installations.count,
                Set(installations.map(\.homeID)).count
            ))
        }
        .alert(model.localized("无法打开安装详情"), isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button(model.localized("关闭"), role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    // MARK: - 页面身份区

    private var identity: some View {
        DSPageIdentity(
            title: model.localized("Skill"),
            glyph: "hammer",
            detail: identityDetail
        ) {
            Button {
                guard let first = model.skillWriteTargets.first else { return }
                openCreateSheet(with: first)
            } label: {
                Label(model.localized("新建 Skill"), systemImage: "plus")
            }
            .buttonStyle(.dsAction(.accent, size: .regular))
            .disabled(!model.allows(.skillWrite) || model.skillWriteTargets.isEmpty)
        }
        .padding(.horizontal, DS.Layout.pageHorizontalInset)
        .padding(.vertical, DS.Space.x300)
        .background(Color(nsColor: DS.Neutral.canvas))
    }

    // MARK: - 新建 Skill（沿用既有表单）

    @State private var isCreating = false
    @State private var createTargetID = ""
    @State private var createName = ""
    @State private var createDescription = ""

    private func openCreateSheet(with first: SkillWriteTarget) {
        createTargetID = first.id
        createName = ""
        createDescription = ""
        isCreating = true
    }

    // MARK: - 矩阵

    private var matrix: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: DS.Space.x300) {
                if let message = model.skillOperationMessage {
                    DSRecessed {
                        HStack(spacing: DS.Space.x300) {
                            Label(message, systemImage: "info.circle")
                                .font(DS.Typeface.body)
                            Spacer(minLength: DS.Space.x200)
                            Button(model.localized("关闭")) { model.clearSkillOperationMessage() }
                                .buttonStyle(.dsAction(size: .compact))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.localized("Skill 操作结果：%@", message))
                }
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    ForEach(skillRows) { row in
                        matrixRow(row)
                    }
                }
            }
            .padding(.horizontal, DS.Layout.pageHorizontalInset)
            .padding(.vertical, DS.Layout.pageVerticalInset)
        }
        .overlay(alignment: .bottomTrailing) {
            if let skill = hoveredSkill {
                skillPreviewCard(skill)
                    .padding(DS.Space.x300)
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                Form {
                    Picker(model.localized("目标"), selection: $createTargetID) {
                        ForEach(model.skillWriteTargets) { target in
                            Text(model.displayPath(target.rootPath)).tag(target.id)
                        }
                    }
                    TextField(model.localized("名称"), text: $createName)
                    TextField(model.localized("描述"), text: $createDescription)
                }
                .formStyle(.grouped)
                .navigationTitle(model.localized("新建 Skill"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.localized("取消")) { isCreating = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.localized("创建")) {
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
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: DS.Space.x150) {
                Text(model.localized("Skill"))
                    .font(DS.Typeface.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(model.localized("%d 列", homes.count))
                    .font(DS.Typeface.micro)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(width: SkillMatrixLayout.leadingColumnWidth, alignment: .leading)
            .padding(.horizontal, DS.Space.x200)
            .frame(height: SkillMatrixLayout.headerHeight)
            ForEach(Array(homes.enumerated()), id: \.element.id) { index, home in
                VStack(alignment: .leading, spacing: DS.Space.x050) {
                    Text(productDisplayName(home))
                        .font(DS.Typeface.micro)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(homeColumnSubtitle(home))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, DS.Space.x150)
                .frame(width: SkillMatrixLayout.homeColumnWidth, height: SkillMatrixLayout.headerHeight, alignment: .leading)
                .overlay(alignment: .leading) {
                    if index > 0, homes[index - 1].productID != home.productID {
                        Rectangle()
                            .fill(Color.primary.opacity(0.16))
                            .frame(width: 1)
                            .padding(.vertical, DS.Space.x100)
                    }
                }
                .help(model.displayPath(home.path))
            }
        }
        .background(Color(nsColor: DS.Neutral.recessed))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: DS.Stroke.hairline)
        }
    }

    private func productDisplayName(_ home: AgentHome) -> String {
        model.snapshot?.products.first { $0.id == home.productID }?.displayName ?? home.productID
    }

    /// 列头副行：Home 标识（隐藏敏感路径时用 Home 序号，否则用路径末段）。
    private func homeColumnSubtitle(_ home: AgentHome) -> String {
        if model.hideSensitivePaths,
           let product = model.snapshot?.products.first(where: { $0.id == home.productID }),
           let index = product.homes
               .sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
               .firstIndex(where: { $0.id == home.id }) {
            return model.localized("Home %d", index + 1)
        }
        return URL(fileURLWithPath: home.path).lastPathComponent
    }

    private func columnTitle(_ home: AgentHome) -> String {
        let productName = model.snapshot?.products.first { $0.id == home.productID }?.displayName ?? home.productID
        if model.hideSensitivePaths,
           let product = model.snapshot?.products.first(where: { $0.id == home.productID }),
           let index = product.homes
               .sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
               .firstIndex(where: { $0.id == home.id }) {
            return model.localized("%@ · Home %d", productName, index + 1)
        }
        return model.localized("%@ · %@", productName, model.displayPath(home.path))
    }

    private func matrixRow(_ row: SkillMatrixRow) -> some View {
        HStack(spacing: 0) {
            leadingCell(row)
            ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                let home = homes[index]
                cellView(cell, home: home, skill: row.skill)
                    .frame(width: SkillMatrixLayout.homeColumnWidth, height: SkillMatrixLayout.rowHeight)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(height: DS.Stroke.hairline)
        }
    }

    private func leadingCell(_ row: SkillMatrixRow) -> some View {
        HStack(spacing: DS.Space.x100) {
            Text(row.skill.name)
                .font(DS.Typeface.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityHint(skillDescription(row.skill) ?? model.localized("此 Skill 没有描述。"))
            if row.skill.variants.count > 1 {
                Button {
                    patchPreselectedHomeIDs = Set(model.skillWriteTargets.map(\.homeID))
                    patchSkill = row.skill
                } label: {
                    DSBadge(
                        text: model.localized("冲突"),
                        color: DS.Semantic.accentSecondary
                    )
                }
                .buttonStyle(.plain)
                .help(model.localized("存在 %d 个内容不同的版本，点击选择权威版本并同步。", row.skill.variants.count))
                .accessibilityLabel(model.localized("冲突：%@ 有 %d 个内容不同的版本。点击选择权威版本。", row.skill.name, row.skill.variants.count))
            }
            Spacer(minLength: DS.Space.x100)
            Menu {
                if !model.allows(.patch) {
                    Text(model.localized("需要付费 License。"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                }
                if row.skill.variants.count > 1 {
                    Button {
                        patchPreselectedHomeIDs = Set(model.skillWriteTargets.map(\.homeID))
                        patchSkill = row.skill
                    } label: {
                        Label(model.localized("解决冲突…"), systemImage: "exclamationmark.triangle")
                    }
                    .disabled(!model.allows(.patch) || model.skillWriteTargets.isEmpty)
                    Divider()
                }
                let missing = Set(row.skill.missingHomeIDs)
                Button {
                    patchPreselectedHomeIDs = missing
                    patchSkill = row.skill
                } label: {
                    Label(
                        model.localized("同步到缺失的 Home（%d 个）", missing.count),
                        systemImage: "arrow.down.doc"
                    )
                }
                .disabled(missing.isEmpty || !model.allows(.patch))
                Button {
                    patchPreselectedHomeIDs = Set(model.skillWriteTargets.map(\.homeID))
                    patchSkill = row.skill
                } label: {
                    Label(model.localized("同步到全部 Home"), systemImage: "square.and.arrow.down.fill")
                }
                .disabled(!model.allows(.patch) || model.skillWriteTargets.isEmpty)
                Divider()
                Button(model.localized("删除整个 Skill"), role: .destructive) {
                    deletingSkill = row.skill
                }
                .disabled(!model.allows(.skillWrite))
                if !model.allows(.skillWrite) {
                    Text(model.localized("需要付费 License。"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Image(systemName: hoveredRowID == row.skill.id ? "ellipsis.circle.fill" : "ellipsis.circle")
                    .font(.system(size: DS.IconSize.navigation, weight: .medium))
                    .foregroundStyle(hoveredRowID == row.skill.id ? DS.Semantic.accentPrimary : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .accessibilityLabel(model.localized("%@ 的操作", row.skill.name))
        }
        .padding(.horizontal, DS.Space.x200)
        .frame(width: SkillMatrixLayout.leadingColumnWidth, height: SkillMatrixLayout.rowHeight, alignment: .leading)
        .onHover { hovering in
            hoveredRowID = hovering ? row.skill.id : nil
        }
    }

    /// 悬停行对应的逻辑 Skill（驱动描述预览浮层）。
    private var hoveredSkill: LogicalSkill? {
        guard let id = hoveredRowID else { return nil }
        return skillRows.first { $0.skill.id == id }?.skill
    }

    /// 首个非空描述（各 Variant 的 SKILL.md frontmatter）。
    private func skillDescription(_ skill: LogicalSkill) -> String? {
        skill.variants
            .flatMap(\.installations)
            .compactMap(\.description)
            .first(where: { !$0.isEmpty })
    }

    /// 描述预览浮层：标题 + 描述（最多 4 行，超长省略），固定在滚动视口右下角，不随内容滚动。
    private func skillPreviewCard(_ skill: LogicalSkill) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x150) {
            HStack(spacing: DS.Space.x150) {
                Image(systemName: "hammer")
                    .font(.system(size: DS.IconSize.navigation, weight: .medium))
                    .foregroundStyle(DS.Semantic.accentPrimary)
                    .accessibilityHidden(true)
                Text(skill.name)
                    .font(DS.Typeface.section)
            }
            Text(skillDescription(skill) ?? model.localized("此 Skill 没有描述。"))
                .font(DS.Typeface.body)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: 340, alignment: .leading)
        }
        .padding(DS.Space.x300)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(Color(nsColor: DS.Neutral.raised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderStandard), lineWidth: DS.Stroke.surface)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 6, y: 2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.localized("%@：%@", skill.name, skillDescription(skill) ?? model.localized("此 Skill 没有描述。")))
    }

    @ViewBuilder
    private func cellView(_ cell: SkillMatrixCell, home: AgentHome, skill: LogicalSkill) -> some View {
        let cellKey = "\(skill.id)|\(home.id.device)|\(home.id.inode)"
        Button {
            switch cell.kind {
            case .missing:
                patchPreselectedHomeIDs = [home.id]
                patchSkill = skill
            case .conflict:
                resolveSkill = skill
                resolveHome = home
            default:
                detailSkill = skill
                detailHome = home
            }
        } label: {
            cellLabel(cell.kind)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if hoveredCellKey == cellKey {
                        RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                            .strokeBorder(DS.Semantic.accentPrimary.opacity(0.5), lineWidth: DS.Stroke.surface)
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredCellKey = hovering ? cellKey : nil
        }
        .accessibilityLabel(accessibilityLabel(for: cell.kind, skill: skill, home: home))
        .help(cellHint(for: cell.kind))
    }

    /// 单元格悬停提示：说明点击后会发生什么。
    private func cellHint(for kind: SkillCellKind) -> String {
        switch kind {
        case .missing:
            return model.localized("点击同步到此处")
        case .conflict:
            return model.localized("点击解决冲突")
        default:
            return model.localized("点击查看安装详情")
        }
    }

    @ViewBuilder
    private func cellLabel(_ kind: SkillCellKind) -> some View {
        switch kind {
        case .missing:
            RoundedRectangle(cornerRadius: DS.Radius.controlCompact, style: .continuous)
                .strokeBorder(
                    DS.Semantic.accentPrimary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
                .overlay(
                    HStack(spacing: DS.Space.x100) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text(model.localized("同步"))
                            .font(DS.Typeface.micro)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(DS.Semantic.accentPrimary.opacity(0.75))
                )
                .padding(.horizontal, DS.Space.x200)
                .frame(height: 26)
        case .valid(let count):
            DSBadge(
                text: count > 1 ? model.localized("有效×%d", count) : model.localized("有效"),
                color: DS.Semantic.statusPositive,
                filled: true
            )
        case .invalid(let count):
            DSBadge(
                text: count > 1 ? model.localized("无效×%d", count) : model.localized("无效"),
                color: DS.Semantic.statusCaution,
                filled: false
            )
        case .conflict:
            DSBadge(
                text: model.localized("冲突"),
                color: DS.Semantic.accentSecondary,
                filled: false
            )
        }
    }

    private func accessibilityLabel(for kind: SkillCellKind, skill: LogicalSkill, home: AgentHome) -> String {
        let homeName = columnTitle(home)
        switch kind {
        case .missing:
            return model.localized("%@：%@ 缺失。点击同步。", skill.name, homeName)
        case .valid(let count):
            return model.localized("%@：%@ 有效，%d 个安装。", skill.name, homeName, count)
        case .invalid(let count):
            return model.localized("%@：%@ 无效，%d 个安装。点击查看原因。", skill.name, homeName, count)
        case .conflict:
            return model.localized("%@：%@ 存在内容冲突。点击查看。", skill.name, homeName)
        }
    }
}

// MARK: - 矩阵数据与布局

private struct SkillMatrixRow: Identifiable {
    let skill: LogicalSkill
    let cells: [SkillMatrixCell]
    var id: String { skill.id }
}

private struct SkillMatrixCell {
    let kind: SkillCellKind
    let installations: [SkillInstallation]
}

private enum SkillCellKind {
    case missing
    case valid(count: Int)
    case invalid(count: Int)
    case conflict
}

private enum SkillMatrixLayout {
    static let leadingColumnWidth: CGFloat = 210
    static let homeColumnWidth: CGFloat = 136
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 44
}

// MARK: - 补齐向导（目标可选 ALL 或指定 Agent/Home，强制覆盖）

struct SkillPatchSheet: View {
    @Bindable var model: AppModel
    let skill: LogicalSkill
    var initialTargetHomeIDs: Set<PhysicalResourceIdentity>

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSourcePath: String?
    @State private var selectedTargetIDs: Set<PhysicalResourceIdentity> = []

    private var sourceCandidates: [SkillInstallation] {
        skill.variants
            .flatMap(\.installations)
            .filter { $0.state == .valid && $0.isWritable }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// 是否存在内容不同的多个版本（行级冲突）。
    private var isConflict: Bool { skill.variants.count > 1 }

    /// 按内容哈希分组的候选版本（每个 Variant 一组，组内按修改时间倒序，代表为最新副本）。
    private var variantGroups: [[SkillInstallation]] {
        Dictionary(grouping: sourceCandidates, by: \.contentHash)
            .values
            .map { $0.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) } }
            .sorted { ($0.first?.modifiedAt ?? .distantPast) > ($1.first?.modifiedAt ?? .distantPast) }
    }

    private var selectedSource: SkillInstallation? {
        sourceCandidates.first { $0.path == selectedSourcePath } ?? sourceCandidates.first
    }

    /// 可写目标（不含源所在 Home）。
    private var writableTargets: [SkillWriteTarget] {
        let sourceHomeID = selectedSource?.homeID
        return model.skillWriteTargets.filter { $0.homeID != sourceHomeID }
    }

    private var targetHomes: [AgentHome] {
        let ids = Set(writableTargets.map(\.homeID))
        return model.skillCapableHomes.filter { ids.contains($0.id) }
    }

    private var coveredHomeIDs: Set<PhysicalResourceIdentity> {
        Set(skill.variants.flatMap(\.installations).map(\.homeID))
    }

    private var missingHomeIDs: Set<PhysicalResourceIdentity> {
        Set(skill.missingHomeIDs)
    }

    private var willOverwriteCount: Int {
        selectedTargetIDs.intersection(coveredHomeIDs).count
    }

    var body: some View {
        NavigationStack {
            Form {
                if isConflict {
                    Section {
                        if sourceCandidates.isEmpty {
                            Text(model.localized("没有可用的有效来源 Variant。"))
                                .font(DS.Typeface.caption)
                                .foregroundStyle(DS.Semantic.statusCaution)
                        } else {
                            ForEach(variantGroups, id: \.first?.contentHash) { group in
                                conflictSourceRow(group)
                            }
                        }
                    } header: {
                        Text(model.localized("选择权威版本（%d 个版本内容不同）", variantGroups.count))
                    } footer: {
                        Text(model.localized("不同版本来自不同 Home 且内容不一致；选择权威版本后，其余 Home 的旧版本将被替换并移入系统废纸篓。"))
                    }
                } else {
                    Section(model.localized("来源 Variant")) {
                        if sourceCandidates.isEmpty {
                            Text(model.localized("没有可用的有效来源 Variant。"))
                                .font(DS.Typeface.caption)
                                .foregroundStyle(DS.Semantic.statusCaution)
                        } else {
                            Picker(model.localized("源"), selection: $selectedSourcePath) {
                                ForEach(sourceCandidates) { installation in
                                    Text(sourceLabel(installation)).tag(Optional(installation.path))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }

                Section {
                    HStack {
                        Button(model.localized("仅缺失")) {
                            selectedTargetIDs = missingHomeIDs.intersection(Set(targetHomes.map(\.id)))
                        }
                        .buttonStyle(.dsAction(size: .compact))
                        Button(model.localized("全部")) {
                            selectedTargetIDs = Set(targetHomes.map(\.id))
                        }
                        .buttonStyle(.dsAction(size: .compact))
                        Spacer()
                        if selectedSource != nil {
                            Text(model.localized("已选择 %d 个 Home", selectedTargetIDs.count))
                                .font(DS.Typeface.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if targetHomes.isEmpty {
                        Text(model.localized("没有可写入的目标 Home。"))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(targetHomes) { home in
                            Toggle(isOn: targetBinding(for: home)) {
                                VStack(alignment: .leading, spacing: DS.Space.x050) {
                                    Text(targetHomeTitle(home))
                                        .font(DS.Typeface.body)
                                    Text(targetHomeSubtitle(home))
                                        .font(DS.Typeface.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                } header: {
                    Text(model.localized("选择目标（Agent / Home）"))
                } footer: {
                    if let source = selectedSource {
                        Text(model.localized(
                            "源与目标在同一 Home 会被排除；已有同名 Skill 的目标将被替换，旧版本移入系统废纸篓。将写入 %d 个文件 · %@。",
                            source.fileCount,
                            model.formatBytes(source.totalBytes)
                        ))
                    }
                }

                if !selectedTargetIDs.isEmpty, let source = selectedSource {
                    Section {
                        LabeledContent(model.localized("来源")) {
                            Text(sourceLabel(source))
                                .lineLimit(1)
                        }
                        LabeledContent(model.localized("目标")) {
                            Text(model.localized("%d 个 Home", selectedTargetIDs.count))
                                .monospacedDigit()
                        }
                        LabeledContent(model.localized("将写入")) {
                            Text(model.localized("%d 个文件 · %@", source.fileCount, model.formatBytes(source.totalBytes)))
                                .monospacedDigit()
                        }
                        if willOverwriteCount > 0 {
                            LabeledContent(model.localized("覆盖")) {
                                Text(model.localized("%d 个已有同名安装", willOverwriteCount))
                                    .foregroundStyle(DS.Semantic.statusCaution)
                            }
                        }
                    } header: {
                        Text(model.localized("预览"))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.localized(isConflict ? "解决冲突 · %@" : "同步 %@", skill.name))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.localized("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.localized(
                        isConflict ? "以所选版本同步到 %d 个 Home" : "同步到 %d 个 Home",
                        selectedTargetIDs.count
                    )) {
                        guard let source = selectedSource else { return }
                        model.patchSkill(skill, source: source, targetHomeIDs: selectedTargetIDs)
                        dismiss()
                    }
                    .disabled(sourceCandidates.isEmpty || selectedTargetIDs.isEmpty || !model.allows(.patch))
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .onAppear {
            if selectedSourcePath == nil {
                selectedSourcePath = sourceCandidates.first?.path
            }
            if selectedTargetIDs.isEmpty {
                let writableIDs = Set(targetHomes.map(\.id))
                if !initialTargetHomeIDs.isEmpty {
                    selectedTargetIDs = initialTargetHomeIDs.intersection(writableIDs)
                }
                if selectedTargetIDs.isEmpty {
                    selectedTargetIDs = missingHomeIDs.intersection(writableIDs)
                }
            }
        }
    }

    private func targetBinding(for home: AgentHome) -> Binding<Bool> {
        Binding(
            get: { selectedTargetIDs.contains(home.id) },
            set: { selected in
                if selected { selectedTargetIDs.insert(home.id) }
                else { selectedTargetIDs.remove(home.id) }
            }
        )
    }

    private func sourceLabel(_ installation: SkillInstallation) -> String {
        let home = model.skillCapableHomes.first { $0.id == installation.homeID }
        let homeName = model.homeDisplayTitle(
            productID: home?.productID ?? "",
            homeIdentity: installation.homeID,
            homePath: home?.path ?? installation.path
        )
        let modified = installation.modifiedAt?.formatted(.dateTime.month().day().hour().minute().locale(model.appLocale))
            ?? model.localized("时间不可用")
        return model.localized("%@ · %@", homeName, modified)
    }

    /// 冲突版本选择行：来源 Home + 副本数 + 文件信息 + 内容哈希，供用户对比判断。
    private func conflictSourceRow(_ group: [SkillInstallation]) -> some View {
        let representative = group[0]
        let selected = selectedSourcePath == representative.path
        return Button {
            selectedSourcePath = representative.path
        } label: {
            HStack(alignment: .top, spacing: DS.Space.x200) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? DS.Semantic.accentPrimary : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: DS.Space.x050) {
                    Text(sourceLabel(representative))
                        .font(DS.Typeface.body)
                    if group.count > 1 {
                        Text(model.localized("此版本在 %d 个 Home 有副本", group.count))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(model.localized(
                        "%d 个文件 · %@ · 最后修改：%@",
                        representative.fileCount,
                        model.formatBytes(representative.totalBytes),
                        representative.modifiedAt?.formatted(.dateTime.month().day().hour().minute().locale(model.appLocale))
                            ?? model.localized("时间不可用")
                    ))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    Text(model.displayPath(representative.path))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .privacySensitive()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: DS.Space.x100) {
                    skillStateBadge(representative, model: model)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(representative.contentHash, forType: .string)
                    } label: {
                        Text(model.localized("复制内容哈希"))
                            .font(DS.Typeface.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Semantic.accentPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func targetHomeTitle(_ home: AgentHome) -> String {
        let productName = model.snapshot?.products.first { $0.id == home.productID }?.displayName ?? home.productID
        if model.hideSensitivePaths,
           let product = model.snapshot?.products.first(where: { $0.id == home.productID }),
           let index = product.homes
               .sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
               .firstIndex(where: { $0.id == home.id }) {
            return model.localized("%@ · Home %d", productName, index + 1)
        }
        return model.localized("%@ · %@", productName, model.displayPath(home.path))
    }

    private func targetHomeSubtitle(_ home: AgentHome) -> String {
        let hasSameName = coveredHomeIDs.contains(home.id)
        if hasSameName {
            return model.localized("已有同名 Skill，将被替换并移入废纸篓")
        }
        if missingHomeIDs.contains(home.id) {
            return model.localized("缺失此 Skill")
        }
        return model.localized("已有此 Skill（内容可能不同）")
    }
}

// MARK: - 冲突解决（同 Home 多个同名版本，选择保留一个并移除其它）

struct SkillConflictResolutionSheet: View {
    @Bindable var model: AppModel
    let skill: LogicalSkill
    let home: AgentHome

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?

    private var versions: [SkillInstallation] {
        skill.variants
            .flatMap(\.installations)
            .filter { $0.homeID == home.id }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    private var selected: SkillInstallation? {
        versions.first { $0.path == selectedPath } ?? versions.first
    }

    private var others: [SkillInstallation] {
        versions.filter { $0.path != selected?.path }
    }

    private var removableOthers: [SkillInstallation] {
        others.filter { $0.isWritable }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.localized("此 Home 有 %d 个同名版本，内容不同。", versions.count))
                        .font(DS.Typeface.body)
                    Text(model.localized("未选择的 %d 个版本将移入系统废纸篓，可恢复。", others.count))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }

                Section(model.localized("选择要保留的版本")) {
                    ForEach(versions) { version in
                        Button {
                            selectedPath = version.path
                        } label: {
                            HStack(alignment: .top, spacing: DS.Space.x200) {
                                Image(systemName: selectedPath == version.path ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(selectedPath == version.path ? DS.Semantic.accentPrimary : Color.secondary)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: DS.Space.x050) {
                                    Text(version.name)
                                        .font(DS.Typeface.body)
                                    Text(model.displayPath(version.path))
                                        .font(DS.Typeface.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .privacySensitive()
                                    Text(model.localized(
                                        "%d 个文件 · %@ · 最后修改：%@",
                                        version.fileCount,
                                        model.formatBytes(version.totalBytes),
                                        version.modifiedAt?.formatted(.dateTime.month().day().hour().minute().locale(model.appLocale))
                                            ?? model.localized("时间不可用")
                                    ))
                                    .font(DS.Typeface.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: DS.Space.x100) {
                                    skillStateBadge(version, model: model)
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(version.contentHash, forType: .string)
                                    } label: {
                                        Text(model.localized("复制内容哈希"))
                                            .font(DS.Typeface.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(DS.Semantic.accentPrimary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!version.isWritable)
                        .opacity(version.isWritable ? 1 : DS.Opacity.unavailable)
                        .help(version.isWritable ? "" : model.localized("远程只读来源不可移除。"))
                    }
                }

                if !removableOthers.isEmpty, let selected {
                    Section(model.localized("将移除")) {
                        ForEach(removableOthers) { version in
                            HStack(spacing: DS.Space.x200) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(model.displayPath(version.path))
                                    .font(DS.Typeface.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .privacySensitive()
                                Spacer()
                                Text(model.localized("移到废纸篓"))
                                    .font(DS.Typeface.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(model.localized("将保留：%@（%d 个文件 · %@）", selected.name, selected.fileCount, model.formatBytes(selected.totalBytes)))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(DS.Semantic.statusPositive)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.localized("解决冲突 · %@", skill.name))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.localized("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.localized("保留所选，移除其它"), role: .destructive) {
                        guard let selected else { return }
                        model.deleteSkillInstallations(versions.filter { $0.path != selected.path })
                        dismiss()
                    }
                    .disabled(removableOthers.isEmpty || !model.allows(.skillWrite))
                }
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .onAppear {
            if selectedPath == nil {
                selectedPath = versions.first?.path
            }
        }
    }
}

// MARK: - 安装详情（单 Home 的所有安装副本 + 诊断 + 编辑/重命名/删除）

struct SkillInstallationDetailSheet: View {
    @Bindable var model: AppModel
    let skill: LogicalSkill
    let home: AgentHome

    @Environment(\.dismiss) private var dismiss
    @State private var editing: SkillInstallation?
    @State private var editorText = ""
    @State private var renaming: SkillInstallation?
    @State private var renameText = ""
    @State private var deleting: SkillInstallation?
    @State private var editError: String?

    private var installations: [SkillInstallation] {
        skill.variants
            .flatMap(\.installations)
            .filter { $0.homeID == home.id }
            .sorted { $0.path < $1.path }
    }

    private var homeTitle: String {
        let productName = model.snapshot?.products.first { $0.id == home.productID }?.displayName ?? home.productID
        return model.localized("%@ · %@", productName, model.displayPath(home.path))
    }

    var body: some View {
        NavigationStack {
            List(installations) { installation in
                VStack(alignment: .leading, spacing: DS.Space.x100) {
                    HStack(spacing: DS.Space.x150) {
                        Text(installation.name)
                            .font(DS.Typeface.section)
                        stateBadge(installation)
                        Spacer()
                        Text(model.localized("%d 个文件 · %@", installation.fileCount, model.formatBytes(installation.totalBytes)))
                            .font(DS.Typeface.micro)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(model.displayPath(installation.path))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .privacySensitive()
                    if !installation.diagnostics.isEmpty {
                        Text(model.localized("此安装当前无效：%@", installation.diagnostics.joined(separator: " · ")))
                            .font(DS.Typeface.caption)
                            .foregroundStyle(DS.Semantic.statusCaution)
                    }
                    if let modified = installation.modifiedAt {
                        Text(model.localized("最后修改：%@", modified.formatted(.dateTime.year().month().day().hour().minute().locale(model.appLocale))))
                            .font(DS.Typeface.micro)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: DS.Space.x200) {
                        Button(model.localized("编辑")) { beginEdit(installation) }
                            .buttonStyle(.dsAction(size: .compact))
                            .disabled(!model.allows(.skillWrite) || !installation.isWritable)
                            .help(buttonDisabledReason(installation))
                        Button(model.localized("重命名目录")) { beginRename(installation) }
                            .buttonStyle(.dsAction(size: .compact))
                            .disabled(!model.allows(.skillWrite) || !installation.isWritable)
                            .help(buttonDisabledReason(installation))
                        Button(model.localized("移到废纸篓"), role: .destructive) { deleting = installation }
                            .buttonStyle(.dsAction(.destructive, size: .compact))
                            .disabled(!model.allows(.skillWrite) || !installation.isWritable)
                            .help(buttonDisabledReason(installation))
                    }
                }
                .padding(.vertical, DS.Space.x150)
            }
            .dsInstrumentList()
            .navigationTitle(model.localized("%@ 的安装", skill.name))
            .navigationSubtitle(homeTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.localized("关闭")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .sheet(item: $editing) { installation in
            NavigationStack {
                TextEditor(text: $editorText)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .navigationTitle(model.localized("编辑 %@", installation.name))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(model.localized("取消")) { editing = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(model.localized("原子保存")) {
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
                    Text(model.localized("只重命名此安装目录；Skill 清单中的逻辑名称不会被暗改。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(model.localized("新目录名"), text: $renameText)
                }
                .formStyle(.grouped)
                .navigationTitle(model.localized("重命名安装目录"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.localized("取消")) { renaming = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.localized("重命名")) {
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
            model.localized("将 Skill 安装移到废纸篓？"),
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { installation in
            Button(model.localized("移到废纸篓"), role: .destructive) {
                model.deleteSkillInstallation(installation)
                deleting = nil
            }
            Button(model.localized("取消"), role: .cancel) { deleting = nil }
        } message: { installation in
            VStack(alignment: .leading, spacing: DS.Space.x100) {
                Text(model.displayPath(installation.path)).privacySensitive()
                if installation.state != .valid, !installation.diagnostics.isEmpty {
                    Text(model.localized("此安装当前无效：%@", installation.diagnostics.joined(separator: " · ")))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(DS.Semantic.statusCaution)
                }
            }
        }
        .alert(model.localized("无法读取 SKILL.md"), isPresented: Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        )) {
            Button(model.localized("关闭"), role: .cancel) { editError = nil }
        } message: {
            Text(editError ?? "")
        }
    }

    @ViewBuilder
    private func stateBadge(_ installation: SkillInstallation) -> some View {
        skillStateBadge(installation, model: model)
    }

    private func beginEdit(_ installation: SkillInstallation) {
        do {
            editorText = try model.loadSkillMainDocument(installation)
            editing = installation
        } catch {
            editError = model.localized("无法读取 SKILL.md：%@", String(describing: error))
        }
    }

    /// 写操作按钮禁用时的原因提示。
    private func buttonDisabledReason(_ installation: SkillInstallation) -> String {
        if !model.allows(.skillWrite) { return model.localized("需要付费 License。") }
        if !installation.isWritable { return model.localized("远程只读来源不可修改。") }
        return ""
    }

    private func beginRename(_ installation: SkillInstallation) {
        renameText = URL(fileURLWithPath: installation.path).lastPathComponent
        renaming = installation
    }
}

/// 安装状态徽标（有效/无效/不可读/重复/冲突），Skill 相关页面共用。
@MainActor
@ViewBuilder
private func skillStateBadge(_ installation: SkillInstallation, model: AppModel) -> some View {
    switch installation.state {
    case .valid:
        DSBadge(text: model.localized("有效"), color: DS.Semantic.statusPositive, filled: true)
    case .invalid:
        DSBadge(text: model.localized("无效"), color: DS.Semantic.statusCaution)
    case .unreadable:
        DSBadge(text: model.localized("不可读"), color: DS.Semantic.statusCaution)
    case .duplicate:
        DSBadge(text: model.localized("重复"), color: DS.Semantic.accentSecondary)
    case .conflict:
        DSBadge(text: model.localized("冲突"), color: DS.Semantic.accentSecondary)
    }
}
