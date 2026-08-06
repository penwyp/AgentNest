import AgentNestCore
import AppKit
import Foundation
import Network
import Observation
import ServiceManagement

struct SkillWriteTarget: Identifiable, Hashable {
    let homeID: PhysicalResourceIdentity
    let homePath: String
    let relativePath: String
    let rootPath: String
    let format: String

    var id: String { rootPath }
}

struct CleanupResultRow: Identifiable {
    let id: String
    let name: String
    let productID: String
    let homeIdentity: PhysicalResourceIdentity?
    let homePath: String
    let status: CleanupResultStatus
    let code: String
}

@MainActor
@Observable
final class AppModel {
    enum Destination: String, CaseIterable, Identifiable {
        case home = "首页"
        case agents = "Agent"
        case skills = "Skill"
        case storage = "空间"
        case activity = "活动"
        case history = "历史"
        case settings = "设置"

        var id: String { rawValue }

        /// 侧栏导航项（按视觉分组顺序）。
        static let navigationItems: [Destination] = [.home, .agents, .skills, .storage, .activity, .history, .settings]

        var systemImage: String {
            switch self {
            case .home: "house"
            case .agents: "cpu"
            case .skills: "hammer"
            case .storage: "internaldrive"
            case .activity: "waveform.path.ecg"
            case .history: "clock.arrow.circlepath"
            case .settings: "gearshape"
            }
        }
    }

    var selection: Destination? = .home
    private(set) var isScanning = false
    private(set) var isStoppingScan = false
    private(set) var progress: ScanProgress?
    private(set) var snapshot: DeviceSnapshot?
    private(set) var errorMessage: String?
    private(set) var licenseState: LicenseState = .missing
    private(set) var licenseConfigurationAvailable = false
    private(set) var activitySnapshot: ActivitySnapshot?
    private(set) var historyPoints: [HistoryPoint] = []
    private(set) var skillIndex: SkillIndex?
    private(set) var cleanupUnits: [CleanupUnit] = []
    private(set) var skillOperationMessage: String?
    private(set) var cleanupOperationMessage: String?
    private(set) var cleanupResults: [CleanupResultRow] = []
    private(set) var isMutatingEnvironment = false
    private(set) var isCleaning = false
    private(set) var customScanPaths: [String] = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
    private(set) var ignoredScanPaths: [String] = UserDefaults.standard.stringArray(forKey: "ignoredScanPaths") ?? []
    private(set) var userConfirmedHomes: [String: String] = UserDefaults.standard.dictionary(forKey: "userConfirmedHomes") as? [String: String] ?? [:]
    private(set) var uninstallReport: String?
    var historyEnabled = UserDefaults.standard.bool(forKey: "historyEnabled")
    var historyRetentionDays: Int
    var hideSensitivePaths = UserDefaults.standard.bool(forKey: "hideSensitivePaths")
    var licenseKey = ""
    var selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "system"

    private var scanTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var licenseTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupInventoryTask: Task<Void, Never>?
    private var licenseRefreshSchedule = LicenseRefreshSchedule()
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.agentnest.network-monitor")
    private var networkAvailable = false
    private var lastHistoryPersistedAt: Date?
    private var lastProgressPublishedAt = Date.distantPast
    private let catalog: AgentDefinitionCatalog?
    private let coordinator: ScanCoordinator?
    private let activitySampler = SystemActivitySampler()
    private let snapshotStore = SnapshotStore()
    private let updateController = UpdateController()
    private let historyStore: HistoryStore
    private var licenseManager: LicenseManager?

    init() {
        let configuredRetention = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        let effectiveRetention = [7, 30, 90, 365].contains(configuredRetention) ? configuredRetention : 365
        historyRetentionDays = effectiveRetention
        historyStore = HistoryStore(
            fileURL: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/AgentNest/History/history.sqlite"),
            retentionDays: effectiveRetention
        )
        let loadedCatalog = try? AgentDefinitionCatalog.bundled()
        catalog = loadedCatalog
        coordinator = loadedCatalog.map { ScanCoordinator(useCase: ScanUseCase(catalog: $0)) }
        snapshot = try? snapshotStore.load()
        refreshCleanupInventory()
        var urlString = Bundle.main.object(forInfoDictionaryKey: "AgentNestLicenseServerURL") as? String
        var encodedKey = Bundle.main.object(forInfoDictionaryKey: "AgentNestLicensePublicKey") as? String
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if urlString?.isEmpty != false { urlString = environment["AGENTNEST_LICENSE_SERVER_URL"] }
        if encodedKey?.isEmpty != false { encodedKey = environment["AGENTNEST_LICENSE_PUBLIC_KEY"] }
        #endif
        if let urlString,
           !urlString.isEmpty,
           let url = URL(string: urlString),
           let encodedKey,
           !encodedKey.isEmpty,
           let publicKey = Self.decodeBase64URL(encodedKey),
           let verifier = try? ReceiptVerifier(publicKeyData: publicKey),
           let machineIDHash = try? MachineIdentityProvider().machineIDHash() {
            licenseManager = LicenseManager(
                verifier: verifier,
                service: LicenseServiceClient(baseURL: url),
                machineIDHash: machineIDHash
            )
            licenseConfigurationAvailable = true
            Task { await loadLicense() }
        }
        startNetworkMonitoring()
    }

    var menuStatus: String {
        guard hasCoreAccess else { return localized("需要试用或激活") }
        if isScanning { return localized("正在扫描") }
        if let snapshot {
            return localized("已发现 %d 个 Agent Home", snapshot.homes.filter { $0.confidence == .confirmed }.count)
        }
        return localized("等待扫描")
    }

    private var localization: AppLocalization { AppLocalization(selection: selectedLanguage) }

    var appLocale: Locale { localization.locale }

    func setLanguage(_ language: String) {
        guard AppLocalization.supportedSelections.contains(language) else { return }
        selectedLanguage = language
        UserDefaults.standard.set(language, forKey: "selectedLanguage")
    }

    func localized(_ key: String) -> String {
        localization.string(key)
    }

    func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localization.string(key), locale: localization.locale, arguments: arguments)
    }

    func setHideSensitivePaths(_ hidden: Bool) {
        hideSensitivePaths = hidden
        UserDefaults.standard.set(hidden, forKey: "hideSensitivePaths")
    }

    func displayPath(_ path: String) -> String {
        hideSensitivePaths ? localized("路径已隐藏") : path
    }

    var hasCoreAccess: Bool {
        switch licenseState {
        case .valid(let payload), .needsRefresh(let payload):
            payload.features.contains(LicenseFeature.scan.rawValue)
        case .serviceUnavailable(let payload):
            payload?.features.contains(LicenseFeature.scan.rawValue) == true
        default:
            false
        }
    }

    var licenseStatusText: String {
        switch licenseState {
        case .missing: licenseConfigurationAvailable ? localized("尚未开始试用") : localized("授权服务尚未配置")
        case .valid(let payload): payload.plan == "trial" ? localized("7 天试用中") : localized("已激活：%@", payload.plan)
        case .needsRefresh: localized("授权有效，等待后台刷新")
        case .expired: localized("试用或授权已到期")
        case .invalid(let error): localized("本地授权无效：%@", error.rawValue)
        case .rejected(let code): localized("授权被服务端拒绝：%@", code)
        case .serviceUnavailable(let payload): payload == nil ? localized("授权服务暂时不可用") : localized("离线可用，授权服务暂时不可用")
        }
    }

    var canDeactivateLicense: Bool {
        switch licenseState {
        case .valid(let payload), .needsRefresh(let payload): payload.plan != "trial"
        case .serviceUnavailable(let payload): payload?.plan != nil && payload?.plan != "trial"
        default: false
        }
    }

    func allows(_ feature: LicenseFeature) -> Bool {
        let payload: EntitlementPayload?
        switch licenseState {
        case .valid(let value), .needsRefresh(let value): payload = value
        case .serviceUnavailable(let value): payload = value
        case .rejected: payload = nil
        default: payload = nil
        }
        return payload?.features.contains(feature.rawValue) == true
    }

    func startScan() {
        guard hasCoreAccess else {
            errorMessage = localized("请先开始试用或激活 License。")
            return
        }
        guard !isScanning, let coordinator else {
            if coordinator == nil { errorMessage = localized("内置 Agent Definition 无法加载") }
            return
        }
        guard !isMutatingEnvironment else {
            errorMessage = localized("另一个扫描或写操作正在进行。")
            return
        }
        isScanning = true
        isStoppingScan = false
        errorMessage = nil
        let root = FileManager.default.homeDirectoryForCurrentUser
        scanTask = Task {
            do {
                let result = try await coordinator.scan(
                    request: ScanRequest(
                        homeDirectory: root,
                        customLocations: customScanPaths.map { URL(fileURLWithPath: $0, isDirectory: true) },
                        ignoredLocations: ignoredScanPaths.map { URL(fileURLWithPath: $0, isDirectory: true) },
                        userConfirmedHomes: userConfirmedHomes,
                        environment: ProcessInfo.processInfo.environment
                    )
                ) { [weak self] value in
                    await MainActor.run {
                        guard let self else { return }
                        let phaseChanged = self.progress?.phase != value.phase
                        let now = Date()
                        guard phaseChanged || now.timeIntervalSince(self.lastProgressPublishedAt) >= 0.25 else { return }
                        self.progress = value
                        self.lastProgressPublishedAt = now
                    }
                }
                snapshot = result
                try? snapshotStore.save(result)
                refreshCleanupInventory()
                await refreshSkillIndex()
            } catch is CancellationError {
                errorMessage = localized("扫描已停止；上一次完整快照仍保留。")
            } catch {
                errorMessage = localized("扫描失败：%@", error.localizedDescription)
            }
            isScanning = false
            isStoppingScan = false
            scanTask = nil
        }
    }

    func stopScan() {
        guard isScanning, !isStoppingScan else { return }
        isStoppingScan = true
        scanTask?.cancel()
        Task { await coordinator?.cancel() }
    }

    func addCustomScanLocations() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = localized("加入 Agent Home")
        guard panel.runModal() == .OK else { return }
        var seen = Set(customScanPaths)
        for url in panel.urls.map({ $0.resolvingSymlinksInPath().standardizedFileURL }) {
            if seen.insert(url.path).inserted { customScanPaths.append(url.path) }
        }
        customScanPaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        UserDefaults.standard.set(customScanPaths, forKey: "customScanPaths")
    }

    func removeCustomScanLocation(_ path: String) {
        customScanPaths.removeAll { $0 == path }
        UserDefaults.standard.set(customScanPaths, forKey: "customScanPaths")
    }

    func addIgnoredScanLocations() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = localized("加入忽略位置")
        guard panel.runModal() == .OK else { return }
        var seen = Set(ignoredScanPaths)
        for url in panel.urls.map({ $0.resolvingSymlinksInPath().standardizedFileURL }) {
            if seen.insert(url.path).inserted { ignoredScanPaths.append(url.path) }
        }
        ignoredScanPaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        UserDefaults.standard.set(ignoredScanPaths, forKey: "ignoredScanPaths")
    }

    func removeIgnoredScanLocation(_ path: String) {
        ignoredScanPaths.removeAll { $0 == path }
        UserDefaults.standard.set(ignoredScanPaths, forKey: "ignoredScanPaths")
    }

    func confirmCandidate(_ home: AgentHome) {
        guard home.confidence == .possible else { return }
        let path = URL(fileURLWithPath: home.path).resolvingSymlinksInPath().standardizedFileURL.path
        userConfirmedHomes[path] = home.productID
        UserDefaults.standard.set(userConfirmedHomes, forKey: "userConfirmedHomes")
        startScan()
    }

    func ignoreCandidate(_ home: AgentHome) {
        let path = URL(fileURLWithPath: home.path).resolvingSymlinksInPath().standardizedFileURL.path
        userConfirmedHomes.removeValue(forKey: path)
        UserDefaults.standard.set(userConfirmedHomes, forKey: "userConfirmedHomes")
        if !ignoredScanPaths.contains(path) {
            ignoredScanPaths.append(path)
            ignoredScanPaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            UserDefaults.standard.set(ignoredScanPaths, forKey: "ignoredScanPaths")
        }
        startScan()
    }

    func revokeCandidateConfirmation(_ home: AgentHome) {
        let path = URL(fileURLWithPath: home.path).resolvingSymlinksInPath().standardizedFileURL.path
        userConfirmedHomes.removeValue(forKey: path)
        UserDefaults.standard.set(userConfirmedHomes, forKey: "userConfirmedHomes")
        startScan()
    }

    var loginItemStatusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: localized("已启用")
        case .requiresApproval: localized("等待系统批准")
        case .notRegistered: localized("未启用")
        case .notFound: localized("当前构建不可用")
        @unknown default: localized("状态未知")
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = localized("登录项更新失败：%@", String(describing: error))
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    var skillWriteTargets: [SkillWriteTarget] {
        guard let snapshot, let catalog else { return [] }
        return snapshot.homes.flatMap { home -> [SkillWriteTarget] in
            guard home.confidence == .confirmed,
                  let definition = catalog.definitions.first(where: { $0.id == home.productID }),
                  definition.capabilities.skills else { return [] }
            return definition.skills.compactMap { location in
                guard location.writable else { return nil }
                let root = URL(fileURLWithPath: home.path).appending(path: location.relativePath).standardizedFileURL
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    return nil
                }
                return SkillWriteTarget(
                    homeID: home.id,
                    homePath: home.path,
                    relativePath: location.relativePath,
                    rootPath: root.path,
                    format: location.format
                )
            }
        }.sorted { $0.rootPath.localizedStandardCompare($1.rootPath) == .orderedAscending }
    }

    func executeCleanup(_ unit: CleanupUnit) {
        executeCleanup([unit])
    }

    func executeCleanup(_ units: [CleanupUnit]) {
        guard allows(.cleanup), let generation = snapshot?.generation else {
            cleanupOperationMessage = localized("当前 License 不包含清理。")
            return
        }
        guard !updateController.sessionInProgress else {
            cleanupOperationMessage = localized("更新进行中，暂不能修改 Agent 环境。")
            return
        }
        guard !isMutatingEnvironment else {
            cleanupOperationMessage = localized("另一个扫描或写操作正在进行。")
            return
        }
        let plan = CleanupPolicy().plan(generation: generation, selected: units)
        guard !plan.units.isEmpty else {
            cleanupOperationMessage = localized("目标受风险或活动保护，未执行。")
            return
        }
        cleanupTask?.cancel()
        cleanupTask = Task {
            isMutatingEnvironment = true
            isCleaning = true
            cleanupResults = []
            defer {
                isMutatingEnvironment = false
                isCleaning = false
                cleanupTask = nil
            }
            let results = await CleanupExecutor().execute(
                plan,
                currentGeneration: generation,
                currentActivity: activitySnapshot,
                isCancelled: { Task.isCancelled }
            )
            let succeeded = results.count { $0.status == .succeeded }
            let skipped = results.count { $0.status == .skipped }
            let failed = results.count { $0.status == .failed }
            let cancelled = results.count { $0.status == .cancelled }
            let unitsByID = Dictionary(uniqueKeysWithValues: plan.units.map { ($0.id, $0) })
            cleanupResults = results.map { result in
                let unit = unitsByID[result.unitID]
                return CleanupResultRow(
                    id: result.unitID,
                    name: unit.map(cleanupUnitTitle) ?? result.unitID,
                    productID: unit?.productID ?? "",
                    homeIdentity: unit?.homeIdentity,
                    homePath: unit?.homePath ?? "",
                    status: result.status,
                    code: result.code
                )
            }
            cleanupOperationMessage = localized(
                "清理完成：成功 %d，跳过 %d，失败 %d，取消 %d。",
                succeeded, skipped, failed, cancelled
            )
            let affectedHomes = Set(plan.units.filter { unit in
                results.contains { $0.unitID == unit.id && $0.status == .succeeded }
            }.map(\.homePath))
            if !affectedHomes.isEmpty {
                await rescanHomes(at: affectedHomes.sorted())
            }
        }
    }

    func cancelCleanup() {
        cleanupTask?.cancel()
    }

    private func refreshCleanupInventory() {
        cleanupInventoryTask?.cancel()
        guard let snapshot, let catalog else {
            cleanupUnits = []
            cleanupInventoryTask = nil
            return
        }
        let activity = activitySnapshot
        let generation = snapshot.generation
        cleanupInventoryTask = Task {
            let units = await Task.detached(priority: .utility) {
                CleanupInventoryUseCase(catalog: catalog)
                    .execute(snapshot: snapshot, activity: activity)
            }.value
            guard !Task.isCancelled, self.snapshot?.generation == generation else { return }
            cleanupUnits = units
            cleanupInventoryTask = nil
        }
    }

    private func rescanHomes(at homePaths: [String]) async {
        guard !isScanning, let coordinator, var baseline = snapshot else { return }
        isScanning = true
        isStoppingScan = false
        defer {
            isScanning = false
            isStoppingScan = false
        }
        do {
            for homePath in homePaths {
                let root = URL(fileURLWithPath: homePath, isDirectory: true)
                baseline = try await coordinator.rescanHome(
                    at: homePath,
                    baseline: baseline,
                    request: ScanRequest(
                        homeDirectory: root,
                        customLocations: [root],
                        ignoredLocations: ignoredScanPaths.map { URL(fileURLWithPath: $0, isDirectory: true) },
                        userConfirmedHomes: userConfirmedHomes,
                        environment: ProcessInfo.processInfo.environment
                    )
                )
            }
            snapshot = baseline
            try? snapshotStore.save(baseline)
            refreshCleanupInventory()
            await refreshSkillIndex()
        } catch is CancellationError {
            errorMessage = localized("扫描已停止；上一次完整快照仍保留。")
        } catch {
            errorMessage = localized("扫描失败：%@", error.localizedDescription)
        }
    }

    func loadSkillMainDocument(_ installation: SkillInstallation) throws -> String {
        let url = URL(fileURLWithPath: installation.path).appending(path: "SKILL.md")
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw SkillWriteError.invalidSkill
        }
        return text
    }

    func createSkill(target: SkillWriteTarget, name: String, description: String) {
        guard allows(.skillWrite), let generation = snapshot?.generation else {
            skillOperationMessage = localized("当前 License 不包含 Skill 写入。")
            return
        }
        runSkillOperation { writer in
            let root = try await writer.ensureSkillRoot(
                home: URL(fileURLWithPath: target.homePath),
                expectedHomeIdentity: target.homeID,
                relativePath: target.relativePath
            )
            let plan = try await writer.planCreate(
                generation: generation,
                skillRoot: root,
                name: name,
                description: description
            )
            try await writer.execute(plan, currentGeneration: generation)
        }
    }

    func editSkill(_ installation: SkillInstallation, mainDocument: String) {
        guard installation.isWritable, allows(.skillWrite), let generation = snapshot?.generation else {
            skillOperationMessage = localized("当前 License 不包含 Skill 写入。")
            return
        }
        runSkillOperation { writer in
            let skillURL = URL(fileURLWithPath: installation.path)
            let plan = try await writer.planEdit(
                generation: generation,
                skillRoot: skillURL.deletingLastPathComponent(),
                skillName: skillURL.lastPathComponent,
                expectedIdentity: installation.id,
                mainDocument: mainDocument
            )
            try await writer.execute(plan, currentGeneration: generation)
        }
    }

    func renameSkillInstallation(_ installation: SkillInstallation, destinationName: String) {
        guard installation.isWritable, allows(.skillWrite), let generation = snapshot?.generation else {
            skillOperationMessage = localized("当前 License 不包含 Skill 写入。")
            return
        }
        runSkillOperation { writer in
            let skillURL = URL(fileURLWithPath: installation.path)
            let plan = try await writer.planRename(
                generation: generation,
                skillRoot: skillURL.deletingLastPathComponent(),
                sourceName: skillURL.lastPathComponent,
                expectedIdentity: installation.id,
                destinationName: destinationName
            )
            try await writer.execute(plan, currentGeneration: generation)
        }
    }

    func deleteSkillInstallation(_ installation: SkillInstallation) {
        guard installation.isWritable, allows(.skillWrite), let generation = snapshot?.generation else {
            skillOperationMessage = localized("当前 License 不包含 Skill 写入。")
            return
        }
        runSkillOperation { writer in
            let skillURL = URL(fileURLWithPath: installation.path)
            let plan = try await writer.planDelete(
                generation: generation,
                skillRoot: skillURL.deletingLastPathComponent(),
                skillName: skillURL.lastPathComponent,
                expectedIdentity: installation.id
            )
            try await writer.execute(plan, currentGeneration: generation)
        }
    }

    func patchSkillToMissingHomes(_ skill: LogicalSkill) {
        guard allows(.patch), let generation = snapshot?.generation,
              let source = skill.variants.flatMap(\.installations).first(where: { $0.state == .valid }) else {
            skillOperationMessage = localized("当前 License 不包含补齐，或没有可用来源 Variant。")
            return
        }
        guard !updateController.sessionInProgress else {
            skillOperationMessage = localized("更新进行中，暂不能修改 Agent 环境。")
            return
        }
        guard !isMutatingEnvironment else {
            skillOperationMessage = localized("另一个扫描或写操作正在进行。")
            return
        }
        let targets = skillWriteTargets.filter { skill.missingHomeIDs.contains($0.homeID) }
        guard !targets.isEmpty else { return }
        Task {
            isMutatingEnvironment = true
            defer { isMutatingEnvironment = false }
            let writer = SkillWriteUseCase()
            do {
                var plans: [SkillWritePlan] = []
                for target in targets {
                    let root = try await writer.ensureSkillRoot(
                        home: URL(fileURLWithPath: target.homePath),
                        expectedHomeIdentity: target.homeID,
                        relativePath: target.relativePath
                    )
                    plans.append(try await writer.planPatch(
                        generation: generation,
                        skillRoot: root,
                        destinationName: URL(fileURLWithPath: source.path).lastPathComponent,
                        sourceSkill: URL(fileURLWithPath: source.path),
                        conflictResolution: .skip
                    ))
                }
                let results = await writer.executeSerial(plans, currentGeneration: generation)
                let succeeded = results.filter { $0.status == .succeeded }.count
                let failed = results.filter { $0.status == .failed }.count
                skillOperationMessage = localized("补齐完成：成功 %d，失败 %d。", succeeded, failed)
                await refreshSkillIndex()
            } catch {
                skillOperationMessage = localized("Skill 补齐预检失败：%@", String(describing: error))
            }
        }
    }

    func clearSkillOperationMessage() {
        skillOperationMessage = nil
    }

    private func runSkillOperation(
        _ operation: @escaping @Sendable (SkillWriteUseCase) async throws -> Void
    ) {
        skillOperationMessage = nil
        guard !updateController.sessionInProgress else {
            skillOperationMessage = localized("更新进行中，暂不能修改 Agent 环境。")
            return
        }
        guard !isMutatingEnvironment else {
            skillOperationMessage = localized("另一个扫描或写操作正在进行。")
            return
        }
        Task {
            isMutatingEnvironment = true
            defer { isMutatingEnvironment = false }
            do {
                try await operation(SkillWriteUseCase())
                skillOperationMessage = localized("Skill 操作成功。")
                await refreshSkillIndex()
            } catch {
                skillOperationMessage = localized("Skill 操作失败：%@", String(describing: error))
            }
        }
    }

    private func refreshSkillIndex() async {
        guard let snapshot, let catalog else { skillIndex = nil; return }
        if allows(.skillWrite), !updateController.sessionInProgress {
            let wasMutating = isMutatingEnvironment
            isMutatingEnvironment = true
            defer { isMutatingEnvironment = wasMutating }
            let writer = SkillWriteUseCase()
            var recovered = 0
            var failed = 0
            for target in skillWriteTargets {
                guard FileManager.default.fileExists(atPath: target.rootPath) else { continue }
                do {
                    let results = try await writer.recoverAbandonedStaging(in: URL(fileURLWithPath: target.rootPath))
                    recovered += results.filter { $0.status == .succeeded }.count
                    failed += results.filter { $0.status == .failed }.count
                } catch {
                    failed += 1
                }
            }
            if recovered > 0 || failed > 0 {
                skillOperationMessage = localized("Skill 暂存恢复：已移到废纸篓 %d，失败 %d。", recovered, failed)
            }
        }
        skillIndex = await SkillIndexUseCase(catalog: catalog).execute(homes: snapshot.homes)
    }

    func startTrial() {
        guard let licenseManager else { return }
        Task {
            updateLicenseState(await licenseManager.startTrial())
            reconcileLicensedTasks()
        }
    }

    func activate() {
        guard let licenseManager, !licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = licenseKey
        Task {
            updateLicenseState(await licenseManager.activate(licenseKey: key))
            if hasCoreAccess {
                licenseKey = ""
            }
            reconcileLicensedTasks()
        }
    }

    private func loadLicense() async {
        guard let licenseManager else { return }
        let state = await licenseManager.loadLocalState()
        updateLicenseState(state)
        if hasCoreAccess { await refreshSkillIndex() }
        if case .needsRefresh = state {
            await refreshLicenseNow(force: true)
        }
        reconcileLicensedTasks()
        startLicenseMonitoringIfNeeded()
    }

    private func startLicenseMonitoringIfNeeded() {
        guard licenseTask == nil, let licenseManager else { return }
        licenseTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                let state = await licenseManager.loadLocalState()
                updateLicenseState(state)
                if case .needsRefresh = state, licenseRefreshSchedule.shouldAttempt(now: Date()) {
                    await refreshLicenseNow(force: false)
                }
                reconcileLicensedTasks()
            }
        }
    }

    func retryLicense() {
        Task { await refreshLicenseNow(force: true) }
    }

    var updateAvailable: Bool { updateController.isConfigured }

    func checkForUpdates() {
        guard !isMutatingEnvironment else {
            errorMessage = localized("Agent 环境写入进行中，完成后再检查更新。")
            return
        }
        updateController.checkForUpdates()
    }

    func deactivateLicense() {
        guard let licenseManager else { return }
        Task {
            do {
                try await licenseManager.deactivate()
                licenseRefreshSchedule = LicenseRefreshSchedule()
                licenseState = .missing
                reconcileLicensedTasks()
            } catch {
                errorMessage = localized("停用设备失败：%@", String(describing: error))
            }
        }
    }

    private func refreshLicenseNow(force: Bool) async {
        guard let licenseManager else { return }
        let now = Date()
        guard force || licenseRefreshSchedule.shouldAttempt(now: now) else { return }
        let state = await licenseManager.refresh(now: now)
        updateLicenseState(state, refreshAttemptedAt: now)
        reconcileLicensedTasks()
    }

    private func updateLicenseState(_ state: LicenseState, refreshAttemptedAt: Date? = nil) {
        licenseState = state
        switch state {
        case .valid(let payload), .needsRefresh(let payload):
            licenseRefreshSchedule.recordSuccess(refreshAfter: payload.refreshAfter)
        case .serviceUnavailable:
            if let refreshAttemptedAt {
                licenseRefreshSchedule.recordFailure(now: refreshAttemptedAt, jitterUnit: Double.random(in: 0...1))
            }
        case .missing, .expired, .invalid, .rejected:
            licenseRefreshSchedule = LicenseRefreshSchedule()
        }
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let restored = isAvailable && !networkAvailable
                networkAvailable = isAvailable
                if restored {
                    licenseRefreshSchedule.networkBecameAvailable(now: Date())
                    if case .serviceUnavailable = licenseState {
                        await refreshLicenseNow(force: false)
                    }
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func reconcileLicensedTasks() {
        if hasCoreAccess {
            startActivitySamplingIfNeeded()
        } else {
            activityTask?.cancel()
            activityTask = nil
            activitySnapshot = nil
            if isScanning { stopScan() }
        }
    }

    private func startActivitySamplingIfNeeded() {
        guard hasCoreAccess, activityTask == nil else { return }
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let sample = try? await activitySampler.sample(inventory: snapshot) {
                    activitySnapshot = sample
                    refreshCleanupInventory()
                    if historyEnabled, allows(.history),
                       lastHistoryPersistedAt.map({ sample.capturedAt.timeIntervalSince($0) >= 60 }) ?? true {
                        try? await historyStore.setEnabled(true)
                        try? await historyStore.append(sample)
                        lastHistoryPersistedAt = sample.capturedAt
                    }
                }
                let configuredInterval = UserDefaults.standard.double(forKey: "sampleInterval")
                let interval = configuredInterval == 0 ? 3 : min(max(configuredInterval, 1), 60)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func setHistoryEnabled(_ value: Bool) {
        guard !value || allows(.history) else {
            errorMessage = localized("当前 License 不包含历史保存。")
            historyEnabled = false
            return
        }
        historyEnabled = value
        UserDefaults.standard.set(value, forKey: "historyEnabled")
        Task {
            try? await historyStore.setEnabled(value)
            if value { await refreshHistory() }
        }
    }

    func setHistoryRetentionDays(_ days: Int) {
        guard [7, 30, 90, 365].contains(days) else { return }
        historyRetentionDays = days
        UserDefaults.standard.set(days, forKey: "historyRetentionDays")
        Task {
            _ = try? await historyStore.setRetentionDays(days)
            if historyEnabled { await refreshHistory() }
        }
    }

    func refreshHistory() async {
        guard historyEnabled else { historyPoints = []; return }
        historyPoints = (try? await historyStore.points(
            from: Date().addingTimeInterval(-7 * 86_400),
            to: Date()
        )) ?? []
    }

    func exportHistoryCSV() {
        guard allows(.export) else {
            errorMessage = localized("当前 License 不包含导出。")
            return
        }
        Task {
            guard let data = try? await historyStore.exportCSV(
                from: Date().addingTimeInterval(-7 * 86_400),
                to: Date()
            ) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "agentnest-history.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func exportHistoryPDF() {
        guard allows(.export) else {
            errorMessage = localized("当前 License 不包含导出。")
            return
        }
        Task {
            let end = Date()
            let points = (try? await historyStore.points(from: end.addingTimeInterval(-7 * 86_400), to: end)) ?? []
            guard let data = try? HistoryPDFRenderer().render(points: points, locale: .current) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "agentnest-history.pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func deleteLocalData() {
        stopScan()
        licenseTask?.cancel()
        licenseTask = nil
        activityTask?.cancel()
        activityTask = nil
        cleanupInventoryTask?.cancel()
        cleanupInventoryTask = nil
        snapshot = nil
        skillIndex = nil
        cleanupUnits = []
        cleanupResults = []
        activitySnapshot = nil
        historyPoints = []
        historyEnabled = false
        UserDefaults.standard.removeObject(forKey: "historyEnabled")
        historyRetentionDays = 365
        UserDefaults.standard.removeObject(forKey: "historyRetentionDays")
        hideSensitivePaths = false
        UserDefaults.standard.removeObject(forKey: "hideSensitivePaths")
        customScanPaths = []
        UserDefaults.standard.removeObject(forKey: "customScanPaths")
        ignoredScanPaths = []
        UserDefaults.standard.removeObject(forKey: "ignoredScanPaths")
        userConfirmedHomes = [:]
        UserDefaults.standard.removeObject(forKey: "userConfirmedHomes")
        Task {
            try? await historyStore.stopAndDelete()
            try? snapshotStore.delete()
            try? await licenseManager?.clearLocalCredentials()
            licenseState = .missing
        }
    }

    func prepareForUninstall() {
        guard !updateController.sessionInProgress else {
            uninstallReport = localized("更新进行中，无法准备卸载。")
            return
        }
        stopScan()
        licenseTask?.cancel()
        licenseTask = nil
        activityTask?.cancel()
        activityTask = nil
        cleanupInventoryTask?.cancel()
        cleanupInventoryTask = nil
        pathMonitor.cancel()
        Task {
            var failures: [String] = []
            do { try await historyStore.stopAndDelete() } catch { failures.append("history") }
            do { try snapshotStore.delete() } catch { failures.append("snapshot") }
            do { try await licenseManager?.clearLocalCredentials() } catch { failures.append("license/keychain") }
            do {
                if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
            } catch { failures.append("login-item") }
            let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/AgentNest")
            do {
                if FileManager.default.fileExists(atPath: applicationSupport.path) {
                    try FileManager.default.removeItem(at: applicationSupport)
                }
            } catch { failures.append("application-support") }
            if let identifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: identifier)
            }
            snapshot = nil
            skillIndex = nil
            cleanupUnits = []
            cleanupResults = []
            activitySnapshot = nil
            historyPoints = []
            historyEnabled = false
            historyRetentionDays = 365
            hideSensitivePaths = false
            customScanPaths = []
            ignoredScanPaths = []
            userConfirmedHomes = [:]
            licenseState = .missing
            uninstallReport = failures.isEmpty
                ? localized("本地数据、登录项与凭据已清除；现在可退出并将 AgentNest.app 移到废纸篓。")
                : localized("准备卸载完成，但以下项目需人工检查：%@", failures.joined(separator: ", "))
        }
    }

    private static func decodeBase64URL(_ input: String) -> Data? {
        var value = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: value)
    }

}
