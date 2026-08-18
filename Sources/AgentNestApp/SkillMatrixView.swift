import AgentNestCore
import SwiftUI

/// Skill 覆盖矩阵主视图：行 = 逻辑 Skill，列 = 具备 Skill 能力的已确认 Home。
/// 横向滚动 + 最小列宽；单元格状态徽标可点击进入安装详情或补齐向导；行尾菜单承载补齐与整体删除。
struct SkillView: View {
    @Bindable var model: AppModel

    @State private var detailSkill: LogicalSkill?
    @State private var detailHome: AgentHome?
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
        .sheet(item: $detailSkill) { skill in
            if let home = detailHome {
                SkillInstallationDetailSheet(model: model, skill: skill, home: home)
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
                    model.skillDialog = .sync(skill: row.skill, initialTargetHomeIDs: [])
                } label: {
                    DSBadge(
                        text: model.localized("冲突"),
                        color: DS.Semantic.accentSecondary
                    )
                }
                .buttonStyle(.plain)
                .help(model.localized("存在 %d 个内容不同的版本，点击解决冲突。", row.skill.variants.count))
                .accessibilityLabel(model.localized("冲突：%@ 有 %d 个内容不同的版本。点击解决冲突。", row.skill.name, row.skill.variants.count))
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
                        model.skillDialog = .sync(skill: row.skill, initialTargetHomeIDs: [])
                    } label: {
                        Label(model.localized("解决冲突…"), systemImage: "exclamationmark.triangle")
                    }
                    .disabled(!model.allows(.patch) || model.skillWriteTargets.isEmpty)
                    Divider()
                }
                let missing = Set(row.skill.missingHomeIDs)
                Button {
                    model.skillDialog = .sync(skill: row.skill, initialTargetHomeIDs: missing)
                } label: {
                    Label(
                        model.localized("同步到缺失的 Home（%d 个）", missing.count),
                        systemImage: "arrow.down.doc"
                    )
                }
                .disabled(missing.isEmpty || !model.allows(.patch))
                Button {
                    model.skillDialog = .sync(skill: row.skill, initialTargetHomeIDs: Set(model.skillWriteTargets.map(\.homeID)))
                } label: {
                    Label(model.localized("同步到全部 Home"), systemImage: "square.and.arrow.down.fill")
                }
                .disabled(!model.allows(.patch) || model.skillWriteTargets.isEmpty)
                Divider()
                Button(role: .destructive) {
                    deletingSkill = row.skill
                } label: {
                    Label(model.localized("删除整个 Skill"), systemImage: "trash")
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
    /// 归一化：去除首尾空白；丢弃仅剩 YAML 指示符之类的占位值（如旧索引残留的 ">-"）。
    private func skillDescription(_ skill: LogicalSkill) -> String? {
        skill.variants
            .flatMap(\.installations)
            .compactMap(\.description)
            .map(Self.normalizeSkillDescription)
            .first { $0 != nil } ?? nil
    }

    /// 展示前归一化 Skill 描述：去除首尾空白；过滤纯指示符/占位内容。
    fileprivate static func normalizeSkillDescription(_ description: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.allSatisfy({ ">|-+ ".contains($0) }) else { return nil }
        return trimmed
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
                model.skillDialog = .sync(skill: skill, initialTargetHomeIDs: [home.id])
            case .conflict:
                model.skillDialog = .homeConflict(skill: skill, home: home)
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

// MARK: - 同步 / 解决冲突 Dialog（统一一个视图，按进入场景切换模式）

/// 统一 Dialog 内容：无冲突 = 同步模式（选源 + 目标）；有冲突 = 冲突解决模式（版本对比 + 影响范围）。
/// 由 SkillDialogOverlay 容器承载（完整 Dialog，点遮罩 / Esc / × / 取消关闭）。
struct SkillPatchSheet: View {
    @Bindable var model: AppModel
    let skill: LogicalSkill
    var initialTargetHomeIDs: Set<PhysicalResourceIdentity>
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSourcePath: String?
    @State private var selectedTargetIDs: Set<PhysicalResourceIdentity> = []
    /// 正在展开差异对比的版本路径（与所选版本对比 SKILL.md，仅冲突模式）。
    @State private var comparingPath: String?

    /// 有效来源候选：只要求内容有效（可读）。源目录是否可写不影响「复制」，只读来源同样可作为源。
    private var sourceCandidates: [SkillInstallation] {
        skill.variants
            .flatMap(\.installations)
            .filter { $0.state == .valid }
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

    /// 与所选版本内容不同的 Home（冲突模式下需要被替换才能一致）。
    private var conflictingHomeIDs: Set<PhysicalResourceIdentity> {
        guard let source = selectedSource else { return [] }
        return Set(skill.variants.flatMap(\.installations).filter { $0.contentHash != source.contentHash }.map(\.homeID))
    }

    /// 该 Skill 涉及的全部 Home 数（冲突概况用）。
    private var involvedHomeCount: Int {
        Set(skill.variants.flatMap(\.installations).map(\.homeID)).count
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isConflict {
                    Section {
                        Text(model.localized(
                            "「%@」共有 %d 个内容不同的版本，分布于 %d 个 Home。",
                            skill.name, variantGroups.count, involvedHomeCount
                        ))
                        .font(DS.Typeface.body)
                    }
                }

                if isConflict {
                    Section {
                        if sourceCandidates.isEmpty {
                            Text(model.localized("没有可用的有效来源 Variant。"))
                                .font(DS.Typeface.caption)
                                .foregroundStyle(DS.Semantic.statusCaution)
                        } else {
                            ForEach(variantGroups, id: \.first?.contentHash) { group in
                                let representative = group[0]
                                VStack(alignment: .leading, spacing: DS.Space.x150) {
                                    SkillVersionCard(
                                        title: sourceHomeTitle(for: representative),
                                        subtitle: group.count > 1 ? model.localized("此版本在 %d 个 Home 有副本", group.count) : nil,
                                        installation: representative,
                                        showBadge: false,
                                        isSelected: selectedSourcePath == representative.path,
                                        model: model,
                                        onSelect: { selectedSourcePath = representative.path }
                                    ) {
                                        if selectedSourcePath != representative.path, selectedSource != nil {
                                            Button {
                                                withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Motion.state)) {
                                                    comparingPath = (comparingPath == representative.path) ? nil : representative.path
                                                }
                                            } label: {
                                                Text(model.localized("查看内容差异"))
                                                    .font(DS.Typeface.caption)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(DS.Semantic.accentPrimary)
                                        }
                                    }
                                    if comparingPath == representative.path, let selected = selectedSource, selected.path != representative.path {
                                        SkillDiffPanel(model: model, selected: selected, other: representative)
                                    }
                                }
                                .padding(.vertical, DS.Space.x100)
                            }
                        }
                    } header: {
                        Text(model.localized("选择权威版本（%d 个版本内容不同）", variantGroups.count))
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
                        Button(model.localized(isConflict ? "仅冲突" : "仅缺失")) {
                            if isConflict {
                                selectedTargetIDs = conflictingHomeIDs.intersection(Set(targetHomes.map(\.id)))
                            } else {
                                selectedTargetIDs = missingHomeIDs.intersection(Set(targetHomes.map(\.id)))
                            }
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
                    Text(model.localized(isConflict ? "影响范围" : "选择目标"))
                } footer: {
                    if isConflict {
                        if !selectedTargetIDs.isEmpty {
                            Text(model.localized("将替换 %d 个 Home 的旧版本，并移入系统废纸篓（可恢复）。", selectedTargetIDs.count))
                        }
                    } else if selectedSource != nil {
                        Text(model.localized("源与目标在同一 Home 会被排除；目标已有同名 Skill 时将被替换，旧版本移入废纸篓。"))
                    }
                }

                if !selectedTargetIDs.isEmpty, let source = selectedSource {
                    Section {
                        if isConflict {
                            LabeledContent(model.localized("保留")) {
                                Text(sourceHomeTitle(for: source))
                                    .lineLimit(1)
                            }
                            LabeledContent(model.localized("将替换")) {
                                Text(model.localized("%d 个 Home", selectedTargetIDs.count))
                                    .monospacedDigit()
                            }
                        } else {
                            LabeledContent(model.localized("来源")) {
                                Text(sourceLabel(source))
                                    .lineLimit(1)
                            }
                            LabeledContent(model.localized("目标")) {
                                Text(model.localized("%d 个 Home", selectedTargetIDs.count))
                                    .monospacedDigit()
                            }
                        }
                        LabeledContent(model.localized("将写入")) {
                            Text(model.localized("%d 个文件 · %@", source.fileCount, model.formatBytes(source.totalBytes)))
                                .monospacedDigit()
                        }
                        if !isConflict, willOverwriteCount > 0 {
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
            .dsInstrumentList()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
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
                    if isConflict {
                        selectedTargetIDs = conflictingHomeIDs.intersection(writableIDs)
                    } else {
                        selectedTargetIDs = missingHomeIDs.intersection(writableIDs)
                    }
                }
            }
        }
        .onChange(of: selectedSourcePath) { _, _ in
            comparingPath = nil
        }
    }

    /// 底部操作条：取消 / 确认（文案随模式切换）。
    private var footer: some View {
        HStack(spacing: DS.Space.x200) {
            Spacer(minLength: DS.Space.x200)
            Button(model.localized("取消")) { onClose() }
                .buttonStyle(.dsAction(size: .regular))
            Button {
                guard let source = selectedSource else { return }
                model.patchSkill(skill, source: source, targetHomeIDs: selectedTargetIDs)
                onClose()
            } label: {
                Text(isConflict
                    ? model.localized("以所选版本解决冲突")
                    : model.localized("同步到 %d 个 Home", selectedTargetIDs.count))
            }
            .buttonStyle(.dsAction(.accent, size: .regular))
            .disabled(sourceCandidates.isEmpty || selectedTargetIDs.isEmpty || !model.allows(.patch))
        }
        .padding(.horizontal, DS.Space.x400)
        .padding(.vertical, DS.Space.x300)
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

    /// 来源安装所在 Home 的展示名（隐藏敏感路径时按序编号）。
    private func sourceHomeTitle(for installation: SkillInstallation) -> String {
        let home = model.skillCapableHomes.first { $0.id == installation.homeID }
        return model.homeDisplayTitle(
            productID: home?.productID ?? "",
            homeIdentity: installation.homeID,
            homePath: home?.path ?? installation.path
        )
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
        if isConflict {
            if conflictingHomeIDs.contains(home.id) {
                return model.localized("将替换旧版本")
            }
            if missingHomeIDs.contains(home.id) {
                return model.localized("缺失此 Skill")
            }
            return model.localized("内容一致")
        }
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

// MARK: - 全窗口 Dialog 容器（同步 / 冲突解决共用）

/// 自定义全窗口 Dialog：半透明遮罩 + 居中完整卡片（680×600）。
/// 点击遮罩、Esc、右上角 ×、取消按钮均可关闭；视觉语言与 sheet 一致（raised 底 + 细描边 + 顶部高光 + 单层阴影）。
struct SkillDialogOverlay: View {
    @Bindable var model: AppModel
    let dialog: SkillDialog

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture { model.skillDialog = nil }
            dialogCard
                .frame(width: 680, height: 600)
        }
        .onExitCommand { model.skillDialog = nil }
    }

    private var dialogCard: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(Color(nsColor: DS.Neutral.raised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.Opacity.borderStandard), lineWidth: DS.Stroke.surface)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
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
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 4)
    }

    private var header: some View {
        HStack(spacing: DS.Space.x200) {
            Image(systemName: glyph)
                .font(.system(size: DS.IconSize.page, weight: .medium))
                .foregroundStyle(DS.Semantic.accentPrimary)
                .accessibilityHidden(true)
            Text(title)
                .font(DS.Typeface.title)
            Spacer(minLength: DS.Space.x200)
            Button {
                model.skillDialog = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .help(model.localized("关闭"))
            .accessibilityLabel(model.localized("关闭"))
        }
        .padding(.horizontal, DS.Space.x400)
        .padding(.vertical, DS.Space.x300)
    }

    @ViewBuilder
    private var content: some View {
        switch dialog {
        case .sync(let skill, let initialTargetHomeIDs):
            SkillPatchSheet(
                model: model,
                skill: skill,
                initialTargetHomeIDs: initialTargetHomeIDs,
                onClose: { model.skillDialog = nil }
            )
        case .homeConflict(let skill, let home):
            SkillHomeConflictResolver(
                model: model,
                skill: skill,
                home: home,
                onClose: { model.skillDialog = nil }
            )
        }
    }

    private var title: String {
        switch dialog {
        case .sync(let skill, _):
            return model.localized(skill.variants.count > 1 ? "解决冲突 · %@" : "同步 %@", skill.name)
        case .homeConflict(let skill, _):
            return model.localized("解决冲突 · %@", skill.name)
        }
    }

    private var glyph: String {
        switch dialog {
        case .sync(let skill, _):
            return skill.variants.count > 1 ? "exclamationmark.triangle" : "square.and.arrow.down"
        case .homeConflict:
            return "exclamationmark.triangle"
        }
    }
}

// MARK: - 版本选择卡（冲突解决共用）

/// 冲突版本选择卡：radio 选中 + 名称/来源 + 描述预览 + 元数据 + 状态 + 哈希复制 + 扩展尾部。
/// 卡片整体可点（选中该版本）；尾部小按钮（复制哈希 / 查看差异）优先于外层命中。
private struct SkillVersionCard<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var pathLine: String? = nil
    let installation: SkillInstallation
    /// 是否显示状态徽标（候选已保证有效时可关闭，避免无信息量的重复装饰）。
    var showBadge: Bool = true
    var isEnabled: Bool = true
    var help: String = ""
    let isSelected: Bool
    let model: AppModel
    var onSelect: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: DS.Space.x200) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? DS.Semantic.accentPrimary : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: DS.Space.x050) {
                    Text(title)
                        .font(DS.Typeface.body)
                        .foregroundStyle(isSelected ? DS.Semantic.accentPrimary : Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .privacySensitive()
                    }
                    if let description = SkillView.normalizeSkillDescription(installation.description ?? "") {
                        Text(description)
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(model.localized(
                        "%d 个文件 · %@ · 最后修改：%@",
                        installation.fileCount,
                        model.formatBytes(installation.totalBytes),
                        installation.modifiedAt?.formatted(.dateTime.month().day().hour().minute().locale(model.appLocale))
                            ?? model.localized("时间不可用")
                    ))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    if let pathLine {
                        Text(pathLine)
                            .font(DS.Typeface.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .privacySensitive()
                    }
                }
                Spacer(minLength: DS.Space.x200)
                VStack(alignment: .trailing, spacing: DS.Space.x100) {
                    if showBadge {
                        skillStateBadge(installation, model: model)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installation.contentHash, forType: .string)
                    } label: {
                        Text(model.localized("复制内容哈希"))
                            .font(DS.Typeface.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Semantic.accentPrimary)
                    trailing()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : DS.Opacity.unavailable)
        .help(help)
    }
}

// MARK: - 版本内容差异（SKILL.md 行级对比）

private enum SkillDiffLineKind: Sendable {
    case context
    case added
    case removed
}

private struct SkillDiffLine: Identifiable, Sendable {
    let id: Int
    let kind: SkillDiffLineKind
    let text: String
}

private enum SkillDiffLoadState: Sendable {
    case loading
    case ready([SkillDiffLine])
    case tooLarge
    case unreadable
}

/// 后台读取两个安装的 SKILL.md 并做行级 LCS 差异；文件过大或不可读时返回对应状态。
/// 纯函数、Sendable，可在 utility 线程执行（交互回调不承载文件 I/O）。
@Sendable
private func loadSkillDiff(_ aPath: String, _ bPath: String) -> SkillDiffLoadState {
    func readMain(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).appending(path: "SKILL.md")
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
    guard let aText = readMain(aPath), let bText = readMain(bPath) else { return .unreadable }
    let aLines = aText.components(separatedBy: .newlines)
    let bLines = bText.components(separatedBy: .newlines)
    guard aLines.count * bLines.count <= 2_000_000 else { return .tooLarge }
    return .ready(computeLineDiff(aLines, bLines))
}

@Sendable
private func computeLineDiff(_ a: [String], _ b: [String]) -> [SkillDiffLine] {
    let n = a.count
    let m = b.count
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        let ai = a[i]
        var row = dp[i]
        let next = dp[i + 1]
        for j in stride(from: m - 1, through: 0, by: -1) {
            row[j] = ai == b[j] ? next[j + 1] + 1 : max(next[j], row[j + 1])
        }
        dp[i] = row
    }
    var lines: [SkillDiffLine] = []
    var id = 0
    var i = 0
    var j = 0
    while i < n && j < m {
        if a[i] == b[j] {
            lines.append(SkillDiffLine(id: id, kind: .context, text: a[i])); id += 1
            i += 1; j += 1
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            lines.append(SkillDiffLine(id: id, kind: .removed, text: a[i])); id += 1
            i += 1
        } else {
            lines.append(SkillDiffLine(id: id, kind: .added, text: b[j])); id += 1
            j += 1
        }
    }
    while i < n { lines.append(SkillDiffLine(id: id, kind: .removed, text: a[i])); id += 1; i += 1 }
    while j < m { lines.append(SkillDiffLine(id: id, kind: .added, text: b[j])); id += 1; j += 1 }
    return lines
}

/// 差异面板：对比「所选版本」与「另一个版本」的 SKILL.md，沉入表面展示（最多 120 行）。
private struct SkillDiffPanel: View {
    let model: AppModel
    let selected: SkillInstallation
    let other: SkillInstallation

    @State private var state: SkillDiffLoadState = .loading

    var body: some View {
        DSRecessed {
            switch state {
            case .loading:
                HStack(spacing: DS.Space.x200) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.localized("正在读取内容…"))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.Space.x100)
            case .tooLarge:
                Text(model.localized("内容过大，无法对比。"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DS.Space.x100)
            case .unreadable:
                Text(model.localized("无法读取内容。"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DS.Space.x100)
            case .ready(let lines):
                diffContent(lines)
            }
        }
        .task(id: "\(selected.path)|\(other.path)") {
            state = .loading
            let result = await Task.detached(priority: .utility) {
                loadSkillDiff(selected.path, other.path)
            }.value
            state = result
        }
    }

    private var diffLineLimit: Int { 120 }

    @ViewBuilder
    private func diffContent(_ lines: [SkillDiffLine]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x100) {
            if lines.allSatisfy({ $0.kind == .context }) {
                Text(model.localized("与所选版本内容一致。"))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.prefix(diffLineLimit)) { line in
                            HStack(alignment: .top, spacing: DS.Space.x150) {
                                Text(sign(for: line.kind))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(for: line.kind))
                                    .frame(width: 12, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.kind == .context ? Color.secondary : color(for: line.kind))
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(DS.Space.x200)
                }
                .frame(maxHeight: 220)
                if lines.count > diffLineLimit {
                    Text(model.localized("差异较多，仅显示前 %d 行，共 %d 行差异。", diffLineLimit, lines.count))
                        .font(DS.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sign(for kind: SkillDiffLineKind) -> String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func color(for kind: SkillDiffLineKind) -> Color {
        switch kind {
        case .context: return .secondary
        case .added: return DS.Semantic.statusPositive
        case .removed: return DS.Semantic.statusCritical
        }
    }
}

// MARK: - 单元格冲突解决（同 Home 多个同名版本，选择保留一个并移除其它）

/// 同 Home 冲突解决内容：选择保留的版本，未选择的可写版本移入废纸篓。
/// 由 SkillDialogOverlay 容器承载（完整 Dialog，点遮罩 / Esc / × / 取消关闭）。
struct SkillHomeConflictResolver: View {
    @Bindable var model: AppModel
    let skill: LogicalSkill
    let home: AgentHome
    var onClose: () -> Void

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
        VStack(spacing: 0) {
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
                        SkillVersionCard(
                            title: version.name,
                            subtitle: model.displayPath(version.path),
                            installation: version,
                            isEnabled: version.isWritable,
                            help: version.isWritable ? "" : model.localized("远程只读来源不可移除。"),
                            isSelected: selectedPath == version.path,
                            model: model,
                            onSelect: { selectedPath = version.path }
                        ) {
                            EmptyView()
                        }
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
            .dsInstrumentList()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .onAppear {
            if selectedPath == nil {
                selectedPath = versions.first?.path
            }
        }
    }

    /// 底部操作条：取消 / 保留所选并移除其它（destructive）。
    private var footer: some View {
        HStack(spacing: DS.Space.x200) {
            Spacer(minLength: DS.Space.x200)
            Button(model.localized("取消")) { onClose() }
                .buttonStyle(.dsAction(size: .regular))
            Button(model.localized("保留所选，移除其它"), role: .destructive) {
                guard let selected else { return }
                model.deleteSkillInstallations(versions.filter { $0.path != selected.path })
                onClose()
            }
            .buttonStyle(.dsAction(.destructive, size: .regular))
            .disabled(removableOthers.isEmpty || !model.allows(.skillWrite))
        }
        .padding(.horizontal, DS.Space.x400)
        .padding(.vertical, DS.Space.x300)
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
