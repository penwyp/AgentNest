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
        case market = "市场"
        case skills = "Skill"
        case storage = "空间"
        case activity = "活动"
        case history = "历史"
        case settings = "设置"

        var id: String { rawValue }

        /// 侧栏导航项（按视觉分组顺序）。
        static let navigationItems: [Destination] = [.home, .agents, .market, .skills, .storage, .activity, .history, .settings]

        var systemImage: String {
            switch self {
            case .home: "house"
            case .agents: "cpu"
            case .market: "storefront"
            case .skills: "hammer"
            case .storage: "internaldrive"
            case .activity: "waveform.path.ecg"
            case .history: "clock.arrow.circlepath"
            case .settings: "gearshape"
            }
        }
    }

    /// 激活门户的本地交互阶段：立即置位保证首帧反馈，网络结果返回后复位。
    enum ActivationPhase: Equatable {
        case idle
        case trialInFlight
        case activateInFlight
    }

    var selection: Destination? = .home
    private(set) var isScanning = false
    private(set) var isStoppingScan = false
    private(set) var progress: ScanProgress?
    private(set) var snapshot: DeviceSnapshot?
    private(set) var errorMessage: String?
    private(set) var licenseState: LicenseState = .missing
    private(set) var licenseActionError: String?
    private(set) var activationPhase: ActivationPhase = .idle
    private(set) var licenseConfigurationAvailable = false
    private(set) var activitySnapshot: ActivitySnapshot?
    private(set) var activityWorkspace: ActivityWorkspaceSnapshot?
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
    /// Agent 详情页当前选中的 Agent 产品（nil = 列表页）。
    var selectedAgentID: String?
    /// Agent 产品详情内当前选中的 Home 配置（nil = 产品概览/Home 列表）。
    var selectedAgentHomeID: PhysicalResourceIdentity?
    /// 本机按 PATH / .app 主可执行文件解析出的「生效安装」（产品 ID → 可执行文件证据）。
    /// 完整扫描会把同一结果写入快照的 `AgentProduct.installations`；此属性同时覆盖旧快照恢复与后台刷新。
    private(set) var effectiveInstallations: [String: AgentInstallation] = [:]
    /// 市场：Agent 安装状态（真实流式状态，随事件更新）。
    private(set) var marketInstallations: [String: MarketInstallState] = [:]
    /// 已通过市场成功安装的产品 ID（持久化：重启后仍显示「已安装」，覆盖无扫描规则的市场条目）。
    private(set) var installedMarketProductIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "installedMarketProductIDs") ?? []
    )
    /// 后台轻量版本扫描得到的已安装版本（产品 ID → 版本）。完整扫描写入 Home 后，
    /// 市场卡优先使用 Home 证据；此字典作为无扫描规则市场条目与 Homebrew 探测的补充。
    private(set) var installedAgentVersions: [String: String] = [:]
    /// 市场最新版本状态（产品 ID → 最新版本/阶段）。只在进入市场、缓存过期、网络恢复等
    /// 明确触发点刷新，单飞 + 节流，不使用定时器循环。
    private(set) var marketVersionStates: [String: MarketAgentVersionState] = [:]
    private(set) var isRefreshingMarketVersions = false
    var historyEnabled = UserDefaults.standard.bool(forKey: "historyEnabled")
    var historyRetentionDays: Int
    var hideSensitivePaths = UserDefaults.standard.bool(forKey: "hideSensitivePaths")
    var licenseKey = ""
    var selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "system"

    private var scanTask: Task<Void, Never>?
    private var installTasks: [String: Task<Void, Never>] = [:]
    private let installRunner = InstallAgentRunner()
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
    private var didAutoStartInitialScan = false
    private var installedVersionScanTask: Task<Void, Never>?
    private var lastInstalledVersionScanAt: Date?
    private var marketVersionTask: Task<Void, Never>?
    private var marketVersionRequested = false
    private var lastMarketVersionAttemptAt: Date?
    private var marketVersionCache: [String: MarketVersionCacheEntry] = [:]
    private let marketVersionRefreshPolicy = MarketVersionRefreshPolicy()
    private let scanUseCase: ScanUseCase?
    private let catalog: AgentDefinitionCatalog?
    private let marketplaceCatalog: MarketplaceCatalog?
    private let coordinator: ScanCoordinator?
    private let activitySampler = SystemActivitySampler()
    private var activityAccumulator = ActivityWorkspaceAccumulator()
    private var cleanupActivitySignature = CleanupActivitySignature(activity: nil)
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
        marketplaceCatalog = try? MarketplaceCatalog.bundled()
        let useCase = loadedCatalog.map { catalog in
            ScanUseCase(catalog: catalog) { definitions in
                Array(AgentInstallationProbe().effectiveInstallations(for: definitions).values)
            }
        }
        scanUseCase = useCase
        coordinator = useCase.map { ScanCoordinator(useCase: $0) }
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
        hydrateMarketVersionCache()
    }

    var menuStatus: String {
        guard hasCoreAccess else { return localized("需要试用或激活") }
        if isScanning { return localized("正在扫描") }
        if snapshot != nil, effectiveAgentCount > 0 {
            return localized("已发现 %d 个生效 Agent", effectiveAgentCount)
        }
        if snapshot != nil {
            return localized("已发现 Agent Home，未检测到生效可执行文件")
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
                        // 渐进发现：每确认一个 Home 立即发布（界面逐个展示）；
                        // 高频位置刻度仍按 0.25 s 节流。
                        let homesChanged = value.confirmedHomes.count != self.progress?.confirmedHomes.count
                        let now = Date()
                        guard homesChanged || phaseChanged || now.timeIntervalSince(self.lastProgressPublishedAt) >= 0.25 else { return }
                        self.progress = value
                        self.lastProgressPublishedAt = now
                    }
                }
                snapshot = result
                try? snapshotStore.save(result)
                for productID in marketInstallations.keys {
                    marketInstallations[productID]?.needsRescanNotice = false
                }
                clearSelectedAgentIfMissing()
                refreshCleanupInventory()
                await refreshSkillIndex()
                // 完整扫描已把 Home 版本写入快照；这里仅补拉 Homebrew 等安装证据，不阻塞收尾。
                startBackgroundInstalledVersionScanIfNeeded(force: true)
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

    /// 首次进入首页且尚无快照时自动开始首次扫描（发现设备上的 Agent 环境）。
    /// 仅尝试一次：用户主动停止后不再自动重启；已有快照时也不触发。
    func autoStartInitialScanIfNeeded() {
        guard !didAutoStartInitialScan, snapshot == nil, !isScanning else { return }
        didAutoStartInitialScan = true
        startScan()
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

    /// 全部具备 Skill 能力且已确认的 Home（矩阵列；不限于可写位置）。
    var skillCapableHomes: [AgentHome] {
        guard let snapshot, let catalog else { return [] }
        let capable = Set(catalog.definitions.filter { $0.capabilities.skills }.map(\.id))
        return snapshot.homes
            .filter { $0.confidence == .confirmed && capable.contains($0.productID) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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

    // MARK: Agent 详情导航

    /// Agent 列表使用的产品集合：快照产品 + 后台刚解析到、但旧快照尚未写入的生效安装。
    /// 这样旧快照恢复后也能立即显示只凭可执行文件存在、没有 Home 的 Agent。
    var agentProducts: [AgentProduct] {
        guard let snapshot else { return [] }
        var products = snapshot.products
        let existingIDs = Set(products.map(\.id))
        if let catalog {
            for (productID, installation) in effectiveInstallations.sorted(by: { $0.key < $1.key }) {
                guard existingIDs.contains(productID) == false,
                      let definition = catalog.definitions.first(where: { $0.id == productID }) else { continue }
                products.append(AgentProduct(
                    id: definition.id,
                    displayName: definition.displayName,
                    definitionVersion: definition.schemaVersion,
                    supportState: definition.capabilities.space ? .supported : .detectable,
                    capabilities: definition.capabilities,
                    installations: [installation],
                    homes: [],
                    profiles: []
                ))
            }
        }
        return products.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func agentProduct(withID id: String) -> AgentProduct? {
        agentProducts.first { $0.id == id }
    }

    func agentHome(withID id: PhysicalResourceIdentity) -> AgentHome? {
        snapshot?.homes.first { $0.id == id }
    }

    func agentHomes(for productID: String) -> [AgentHome] {
        agentProduct(withID: productID)?.homes
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } ?? []
    }

    /// 当前真正生效的安装：后台解析结果优先；完整扫描结果作为快照内证据回退。
    func effectiveInstallation(for productID: String) -> AgentInstallation? {
        if let live = effectiveInstallations[productID] { return live }
        return agentProduct(withID: productID)?.installations.first
    }

    var effectiveAgentCount: Int {
        agentProducts.filter { product in
            effectiveInstallation(for: product.id) != nil
        }.count
    }

    private func clearSelectedAgentIfMissing() {
        if let selectedAgentID,
           agentProducts.contains(where: { $0.id == selectedAgentID }) != true {
            self.selectedAgentID = nil
            self.selectedAgentHomeID = nil
        }
        if let selectedAgentHomeID,
           snapshot?.homes.contains(where: { $0.id == selectedAgentHomeID }) != true {
            self.selectedAgentHomeID = nil
        }
    }

    // MARK: Agent 市场

    /// 市场安装状态（随事件流更新；失败以结构化原因表达，文案由 installFailureTitle 翻译）。
    struct MarketInstallState: Equatable {
        var phase: InstallAgentPhase = .locatingBrew
        var step: InstallAgentStep = .detectingEnvironment
        var outputTail: [String] = []
        var needsRescanNotice = false
    }

    /// 市场面板列出的目录产品（按名称排序，含未参与扫描的产品）。
    var marketDefinitions: [AgentDefinition] {
        (catalog?.definitions ?? []).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Skills 市场目录（按发布者/名称排序）。
    var marketplaceSkillItems: [SkillMarketplaceItem] {
        (marketplaceCatalog?.skills ?? []).sorted {
            ($0.publisher, $0.name) < ($1.publisher, $1.name)
        }
    }

    /// MCP 市场目录（按发布者/名称排序）。
    var marketplaceMCPServers: [MCPServerMarketplaceItem] {
        (marketplaceCatalog?.mcpServers ?? []).sorted {
            ($0.publisher, $0.name) < ($1.publisher, $1.name)
        }
    }

    /// 是否有安装任务进行中（brew 全局互斥，其余安装按钮据此禁用）。
    var isAnyMarketInstallRunning: Bool {
        marketInstallations.values.contains {
            $0.phase == .locatingBrew || $0.phase == .preparingDependencies || $0.phase == .running
        }
    }

    /// 升级/安装入口：无安装权限时在卡片内直接显示原因，不进入安装状态，也不因 disabled 压暗按钮。
    func requestMarketInstall(_ productID: String) {
        guard allows(.install) else {
            marketInstallations[productID] = MarketInstallState(
                phase: .failed(.permissionDenied),
                step: .detectingEnvironment,
                outputTail: []
            )
            return
        }
        startMarketInstall(productID)
    }

    func startMarketInstall(_ productID: String) {
        guard let catalog,
              let definition = catalog.definitions.first(where: { $0.id == productID }),
              let method = definition.marketplace?.install,
              !isAnyMarketInstallRunning else { return }
        marketInstallations[productID] = MarketInstallState(
            phase: .locatingBrew,
            step: .detectingEnvironment,
            outputTail: []
        )
        let task = Task { [weak self] in
            guard let self else { return }
            // 安装为同步阻塞式（brew 可能持续数分钟），隔离到 utility 线程。
            _ = await Task.detached(priority: .utility) {
                try? self.installRunner.install(productID: productID, method: method) { event in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.marketInstallations[productID] = MarketInstallState(
                            phase: event.phase,
                            step: event.step,
                            outputTail: event.outputTail
                        )
                        // 安装成功即持久化：市场条目（含无扫描规则的）重启后仍显示「已安装」。
                        if event.phase == .completed {
                            self.marketInstallations[productID]?.needsRescanNotice = true
                            self.installedMarketProductIDs.insert(productID)
                            UserDefaults.standard.set(
                                Array(self.installedMarketProductIDs),
                                forKey: "installedMarketProductIDs"
                            )
                            // 安装完成后立刻补一次后台版本扫描，供市场卡比较最新版本。
                            self.startBackgroundInstalledVersionScanIfNeeded(force: true)
                        }
                    }
                }
            }.value
            installTasks[productID] = nil
        }
        installTasks[productID] = task
    }

    func cancelMarketInstall(_ productID: String) {
        installRunner.cancel(productID: productID)
    }

    func installFailureTitle(_ failure: InstallAgentFailure) -> String {
        switch failure {
        case .brewNotFound: return localized("未找到 Homebrew，无法安装。")
        case .homebrewInstallFailed: return localized("Homebrew 安装失败，请重试或手动安装 Homebrew。")
        case .nodeInstallFailed: return localized("Node.js/npm 安装失败，请检查网络后重试。")
        case .scriptDownloadFailed: return localized("官方安装脚本下载失败，请检查网络后重试。")
        case .authorizationRequired: return localized("安装需要管理员授权，请在系统弹窗中允许后重试。")
        case .permissionDenied: return localized("当前授权不包含安装能力，可浏览目录。")
        case .websiteInstallerClosed: return localized("安装镜像已关闭，未完成安装。请重新点击安装。")
        case .websiteInstallerTimedOut: return localized("等待安装完成超时，请确认应用已安装后重试。")
        case let .exited(code): return localized("安装退出码 %d", code)
        }
    }

    // MARK: 版本检测与市场最新版本

    /// 聚合「已安装版本」。优先级：
    /// 1. 后台探测的生效可执行文件版本（CLI PATH / Desktop .app 主程序）；
    /// 2. Homebrew / Home 指纹证据（仅作为生效可执行文件不可用时的补充）。
    func installedVersion(for productID: String) -> String? {
        if let authoritative = installedAgentVersions[productID] {
            let normalized = AgentVersion.normalizedVersion(authoritative)
            if !normalized.isEmpty { return normalized }
        }
        let homeVersions = snapshot?.homes
            .filter { $0.productID == productID && $0.confidence == .confirmed }
            .compactMap(\.version) ?? []
        return Self.newestVersion(in: homeVersions)
    }

    func latestMarketVersion(for productID: String) -> String? {
        marketVersionStates[productID]?.latestVersion
    }

    func isFetchingMarketVersion(for productID: String) -> Bool {
        marketVersionStates[productID]?.phase == .loading
    }

    func hasMarketVersionUpdate(for productID: String) -> Bool {
        guard let installed = installedVersion(for: productID),
              let latest = latestMarketVersion(for: productID) else { return false }
        return AgentVersion.isUpdate(latest: latest, installed: installed)
    }

    /// 侧边栏市场角标数量：只统计「已安装版本」与「已成功获取的最新版本」都比较完成的 Agent。
    var marketUpdateCount: Int {
        marketDefinitions.reduce(0) { count, definition in
            count + (hasMarketVersionUpdate(for: definition.id) ? 1 : 0)
        }
    }

    /// App 启动后的后台轻量版本扫描：只验证候选 Home 与版本指纹，不递归索引。
    /// 单飞 + 5 分钟节流；已加载快照时不会阻塞任何界面操作。
    func startBackgroundInstalledVersionScanIfNeeded(force: Bool = false) {
        guard hasCoreAccess, let catalog, let scanUseCase else { return }
        if installedVersionScanTask != nil {
            guard force else { return }
            installedVersionScanTask?.cancel()
        }
        let now = Date()
        if !force, let last = lastInstalledVersionScanAt, now.timeIntervalSince(last) < Self.installedVersionScanThrottle {
            return
        }
        lastInstalledVersionScanAt = now

        let root = FileManager.default.homeDirectoryForCurrentUser
        let customLocations = customScanPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let ignoredLocations = ignoredScanPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let confirmed = userConfirmedHomes
        let environment = ProcessInfo.processInfo.environment
        let definitions = catalog.definitions

        installedVersionScanTask = Task { [weak self] in
            let request = ScanRequest(
                homeDirectory: root,
                customLocations: customLocations,
                ignoredLocations: ignoredLocations,
                userConfirmedHomes: confirmed,
                environment: environment
            )
            var fileVersions: [String: String] = [:]
            let discovered = await scanUseCase.discoverInstalledVersions(request: request)
            for record in discovered {
                fileVersions[record.productID] = Self.preferredVersion(
                    existing: fileVersions[record.productID],
                    candidate: record.version
                )
            }
            guard let self, !Task.isCancelled else { return }
            let effectiveInstallations = await Task.detached(priority: .utility) {
                AgentInstallationProbe().effectiveInstallations(for: definitions)
            }.value
            // Homebrew、桌面 App bundle 与可执行文件版本并行探测。
            // 生效安装以可执行文件为准：CLI 的 PATH 可执行文件与 Desktop 的 .app 主程序优先；
            // Homebrew 与 Home 缓存只作为没有生效可执行文件时的补充。
            async let brewVersions = HomebrewAgentVersionProbe().installedVersions(for: definitions)
            async let appBundleVersions = InstalledAppBundleVersionProbe().installedVersions(for: definitions)
            async let executableVersions = ExecutableAgentVersionProbe().installedVersions(for: definitions)
            let (brew, appBundle, executable) = await (brewVersions, appBundleVersions, executableVersions)
            var merged = executable
            for (productID, version) in appBundle where merged[productID] == nil {
                merged[productID] = version
            }
            for (productID, version) in brew where merged[productID] == nil {
                merged[productID] = version
            }
            for (productID, version) in fileVersions where merged[productID] == nil {
                merged[productID] = version
            }
            guard !Task.isCancelled else { return }
            self.installedAgentVersions = merged
            self.effectiveInstallations = effectiveInstallations
            self.installedVersionScanTask = nil
            // 已安装版本就绪后，再刷新一次过期的最新版本缓存，供侧边栏红点角标准确更新。
            self.refreshMarketVersionsIfNeeded()
        }
    }

    /// 市场最新版本触发规则：
    /// - 进入市场且缓存不存在或超过 TTL 时拉取；
    /// - 同一时刻只允许一个在飞任务，失败 2 分钟内不重试；
    /// - 网络恢复且用户曾进入市场时，自动补一次；
    /// - 成功结果缓存 30 分钟，视图反复 onAppear 不会反复请求。
    func marketDidAppear() {
        marketVersionRequested = true
        refreshMarketVersionsIfNeeded()
    }

    func refreshMarketVersionsIfNeeded(force: Bool = false) {
        guard hasCoreAccess, let catalog else { return }
        // 触发时机：用户进过市场，或本地已有成功缓存。避免 App 启动即无条件联网。
        guard marketVersionRequested || !marketVersionCache.isEmpty else { return }
        guard marketVersionTask == nil else { return }

        let definitions = catalog.definitions.filter {
            $0.marketplace?.install != nil
                || $0.marketplace?.appStoreID != nil
                || $0.marketplace?.websiteUpdateURL != nil
        }
        guard !definitions.isEmpty else { return }
        let now = Date()
        let fetchedAtByProduct = marketVersionCache.mapValues(\.fetchedAt)
        let staleDefinitions = marketVersionRefreshPolicy
            .staleProductIDs(
                allProductIDs: definitions.map(\.id),
                fetchedAtByProduct: fetchedAtByProduct,
                now: now
            )
            .compactMap { productID in definitions.first { $0.id == productID } }
        let targets = force ? definitions : staleDefinitions
        guard marketVersionRefreshPolicy.shouldRefresh(
            force: force,
            staleProductIDs: staleDefinitions.map(\.id),
            lastAttemptAt: lastMarketVersionAttemptAt,
            now: now
        ) else { return }

        lastMarketVersionAttemptAt = now
        isRefreshingMarketVersions = true
        for definition in targets {
            marketVersionStates[definition.id, default: MarketAgentVersionState()].phase = .loading
        }

        let service = MarketplaceVersionService()
        marketVersionTask = Task { [weak self] in
            guard let self else { return }
            let successfulIDs = await self.fetchMarketVersions(definitions: targets, service: service)
            guard !Task.isCancelled else { return }
            let completedAt = Date()
            for definition in targets {
                guard var state = self.marketVersionStates[definition.id] else { continue }
                if successfulIDs.contains(definition.id) {
                    state.phase = .loaded
                    state.fetchedAt = completedAt
                } else {
                    state.phase = .unavailable
                }
                self.marketVersionStates[definition.id] = state
            }
            self.persistMarketVersionCache()
            self.isRefreshingMarketVersions = false
            self.marketVersionTask = nil
        }
    }

    /// 网络恢复时只对曾进入过市场的用户补拉一次；失败退避仍生效。
    private func refreshMarketVersionsAfterNetworkRestore() {
        guard marketVersionRequested, marketVersionTask == nil else { return }
        lastMarketVersionAttemptAt = nil
        refreshMarketVersionsIfNeeded(force: false)
    }

    private func fetchMarketVersions(
        definitions: [AgentDefinition],
        service: MarketplaceVersionService
    ) async -> Set<String> {
        await withTaskGroup(of: (String, String?).self) { group in
            for definition in definitions {
                if let websiteUpdateURL = definition.marketplace?.websiteUpdateURL {
                    group.addTask {
                        let version = try? await service.latestVersion(websiteUpdateURL: websiteUpdateURL)
                        return (definition.id, version)
                    }
                } else if let appStoreID = definition.marketplace?.appStoreID {
                    group.addTask {
                        let version = try? await service.latestVersion(appStoreID: appStoreID)
                        return (definition.id, version)
                    }
                } else if let method = definition.marketplace?.install {
                    group.addTask {
                        let version = try? await service.latestVersion(for: method)
                        return (definition.id, version)
                    }
                }
            }
            var successfulIDs: Set<String> = []
            for await (productID, version) in group {
                guard !Task.isCancelled else { continue }
                guard let version else { continue }
                successfulIDs.insert(productID)
                self.marketVersionStates[productID, default: MarketAgentVersionState()].latestVersion = version
                self.marketVersionCache[productID] = MarketVersionCacheEntry(
                    latestVersion: version,
                    fetchedAt: Date()
                )
            }
            return successfulIDs
        }
    }

    // MARK: 版本缓存

    private func hydrateMarketVersionCache() {
        // v1 缓存混用了 Homebrew formula 与官网脚本两个版本来源，不再复用到 v2。
        UserDefaults.standard.removeObject(forKey: "marketVersionCache.v1")
        guard let data = UserDefaults.standard.data(forKey: Self.marketVersionCacheDefaultsKey),
              let entries = try? JSONDecoder().decode([String: MarketVersionCacheEntry].self, from: data) else {
            return
        }
        marketVersionCache = entries
        for (productID, entry) in entries {
            marketVersionStates[productID] = MarketAgentVersionState(
                phase: .loaded,
                latestVersion: entry.latestVersion,
                fetchedAt: entry.fetchedAt
            )
        }
    }

    private func persistMarketVersionCache() {
        guard let data = try? JSONEncoder().encode(marketVersionCache) else { return }
        UserDefaults.standard.set(data, forKey: Self.marketVersionCacheDefaultsKey)
    }

    private static func newestVersion(in versions: [String]) -> String? {
        var newest: String?
        for version in versions {
            guard let current = newest else {
                newest = version
                continue
            }
            if AgentVersion.compare(version, to: current) == .newer {
                newest = version
            }
        }
        return newest
    }

    private static func preferredVersion(existing: String?, candidate: String) -> String {
        guard let existing else { return candidate }
        return AgentVersion.compare(candidate, to: existing) == .newer ? candidate : existing
    }

    private static let installedVersionScanThrottle: TimeInterval = 5 * 60
    private static let marketVersionCacheDefaultsKey = "marketVersionCache.v2"

    private func refreshCleanupInventory() {
        cleanupInventoryTask?.cancel()
        cleanupActivitySignature = CleanupActivitySignature(activity: activitySnapshot)
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
            clearSelectedAgentIfMissing()
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

    /// 补齐（强制覆盖）：把 source 复制到 targetHomeIDs 指定的全部可写位置。
    /// 目标已有同名 Skill 时走 planPatch(.replace)——旧目录移入系统废纸篓（失败自动回滚）。
    func patchSkill(
        _ skill: LogicalSkill,
        source: SkillInstallation,
        targetHomeIDs: Set<PhysicalResourceIdentity>
    ) {
        guard allows(.patch), let generation = snapshot?.generation else {
            skillOperationMessage = localized("当前 License 不包含同步。")
            return
        }
        guard source.state == .valid, source.isWritable else {
            skillOperationMessage = localized("没有可用的有效来源 Variant。")
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
        let targets = skillWriteTargets.filter {
            targetHomeIDs.contains($0.homeID) && $0.homeID != source.homeID
        }
        guard !targets.isEmpty else { return }
        let sourcePath = URL(fileURLWithPath: source.path)
        let destinationName = sourcePath.lastPathComponent
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
                        destinationName: destinationName,
                        sourceSkill: sourcePath,
                        conflictResolution: .replace
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

    /// 删除整个逻辑 Skill：把每个可写安装目录移入废纸篓（含无效/不可读残留，仅排除远程只读来源）。
    func deleteLogicalSkill(_ skill: LogicalSkill) {
        guard allows(.skillWrite), let generation = snapshot?.generation else {
            skillOperationMessage = localized("当前 License 不包含 Skill 写入。")
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
        let installations = skill.variants.flatMap(\.installations)
        guard !installations.isEmpty else {
            skillOperationMessage = localized("此 Skill 没有可删除的安装副本。")
            return
        }
        runDeletePlans(installations)
    }

    /// 删除指定安装副本集合（冲突解决时移除未保留版本）。
    func deleteSkillInstallations(_ installations: [SkillInstallation]) {
        guard allows(.skillWrite), let generation = snapshot?.generation else {
            skillOperationMessage = localized("当前 License 不包含 Skill 写入。")
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
        guard !installations.isEmpty else { return }
        runDeletePlans(installations)
    }

    /// 公共删除执行器：逐目录 planDelete 串行移入废纸篓，结果汇总到横幅并重建 Skill 索引。
    private func runDeletePlans(_ installations: [SkillInstallation]) {
        let writable = installations.filter { $0.isWritable }
        guard !writable.isEmpty else {
            skillOperationMessage = localized("所选版本均不可移除。")
            return
        }
        guard let generation = snapshot?.generation else { return }
        Task {
            isMutatingEnvironment = true
            defer { isMutatingEnvironment = false }
            let writer = SkillWriteUseCase()
            do {
                var plans: [SkillWritePlan] = []
                for installation in writable {
                    let skillURL = URL(fileURLWithPath: installation.path)
                    plans.append(try await writer.planDelete(
                        generation: generation,
                        skillRoot: skillURL.deletingLastPathComponent(),
                        skillName: skillURL.lastPathComponent,
                        expectedIdentity: installation.id
                    ))
                }
                let results = await writer.executeSerial(plans, currentGeneration: generation)
                let succeeded = results.filter { $0.status == .succeeded }.count
                let failed = results.filter { $0.status == .failed }.count
                skillOperationMessage = localized("已删除 %d 个安装，失败 %d。", succeeded, failed)
                await refreshSkillIndex()
            } catch {
                skillOperationMessage = localized("Skill 删除失败：%@", String(describing: error))
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
        guard let licenseManager, activationPhase == .idle else { return }
        activationPhase = .trialInFlight
        licenseActionError = nil
        Task {
            updateLicenseState(await licenseManager.startTrial())
            activationPhase = .idle
            reconcileLicensedTasks()
        }
    }

    func activate() {
        guard let licenseManager, activationPhase == .idle,
              !licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = licenseKey
        activationPhase = .activateInFlight
        licenseActionError = nil
        Task {
            let state = await licenseManager.activate(licenseKey: key)
            if hasCoreAccess, case .rejected(let code) = state {
                // 已有有效授权（如试用）时激活失败：保留现有状态并就地提示，不把用户踢回门户。
                licenseActionError = localized("授权被服务端拒绝：%@", code)
            } else if hasCoreAccess, case .invalid(let error) = state {
                licenseActionError = localized("本地授权无效：%@", error.rawValue)
            } else if hasCoreAccess, case .expired = state {
                licenseActionError = localized("试用或授权已到期")
            } else {
                updateLicenseState(state)
                if hasCoreAccess {
                    licenseKey = ""
                }
            }
            activationPhase = .idle
            reconcileLicensedTasks()
        }
    }

    private func loadLicense() async {
        guard let licenseManager else { return }
        let state = await licenseManager.loadLocalState()
        updateLicenseState(state)
        if hasCoreAccess {
            await refreshSkillIndex()
            // 启动时强制刷新一次授权：服务端特性表（如 install）更新后无需等待 refreshAfter 周期。
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
        licenseActionError = nil
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
                    refreshMarketVersionsAfterNetworkRestore()
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func reconcileLicensedTasks() {
        if hasCoreAccess {
            startActivitySamplingIfNeeded()
            startBackgroundInstalledVersionScanIfNeeded()
        } else {
            activityTask?.cancel()
            activityTask = nil
            resetActivityState()
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
                    activityWorkspace = activityAccumulator.record(sample)
                    if CleanupActivitySignature(activity: sample) != cleanupActivitySignature {
                        refreshCleanupInventory()
                    }
                    if historyEnabled, allows(.history),
                       lastHistoryPersistedAt.map({ sample.capturedAt.timeIntervalSince($0) >= 60 }) ?? true {
                        try? await historyStore.setEnabled(true)
                        try? await historyStore.append(sample)
                        lastHistoryPersistedAt = sample.capturedAt
                    }
                }
                let configuredInterval = UserDefaults.standard.double(forKey: "sampleInterval")
                let interval = configuredInterval == 0
                    ? ActivitySamplingPolicy.defaultInterval
                    : min(max(configuredInterval, ActivitySamplingPolicy.minimumInterval), ActivitySamplingPolicy.maximumInterval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func resetActivityState() {
        activitySnapshot = nil
        activityWorkspace = nil
        activityAccumulator.reset()
        cleanupActivitySignature = CleanupActivitySignature(activity: nil)
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
        installedVersionScanTask?.cancel()
        installedVersionScanTask = nil
        installedAgentVersions = [:]
        marketVersionTask?.cancel()
        marketVersionTask = nil
        isRefreshingMarketVersions = false
        marketVersionStates = [:]
        marketVersionCache = [:]
        marketVersionRequested = false
        lastMarketVersionAttemptAt = nil
        UserDefaults.standard.removeObject(forKey: Self.marketVersionCacheDefaultsKey)
        snapshot = nil
        skillIndex = nil
        cleanupUnits = []
        cleanupResults = []
        resetActivityState()
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
        installedVersionScanTask?.cancel()
        installedVersionScanTask = nil
        installedAgentVersions = [:]
        marketVersionTask?.cancel()
        marketVersionTask = nil
        isRefreshingMarketVersions = false
        marketVersionStates = [:]
        marketVersionCache = [:]
        marketVersionRequested = false
        lastMarketVersionAttemptAt = nil
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
            resetActivityState()
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
