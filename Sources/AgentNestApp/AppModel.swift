import AgentNestCore
import AppKit
import Foundation
import Observation

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
    private(set) var progress: ScanProgress?
    private(set) var snapshot: DeviceSnapshot?
    private(set) var errorMessage: String?
    private(set) var licenseState: LicenseState = .missing
    private(set) var licenseConfigurationAvailable = false
    private(set) var activitySnapshot: ActivitySnapshot?
    private(set) var historyPoints: [HistoryPoint] = []
    private(set) var skillIndex: SkillIndex?
    var historyEnabled = UserDefaults.standard.bool(forKey: "historyEnabled")
    var licenseKey = ""

    private var scanTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var licenseTask: Task<Void, Never>?
    private var lastProgressPublishedAt = Date.distantPast
    private let coordinator: ScanCoordinator?
    private let activitySampler = SystemActivitySampler()
    private let historyStore = HistoryStore(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AgentNest/History/history.sqlite")
    )
    private var licenseManager: LicenseManager?

    init() {
        coordinator = try? ScanCoordinator(useCase: ScanUseCase(catalog: AgentDefinitionCatalog.bundled()))
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
    }

    var menuStatus: String {
        guard hasCoreAccess else { return localize("需要试用或激活") }
        if isScanning { return localize("正在扫描") }
        if let snapshot {
            return String(format: localize("已发现 %d 个 Agent Home"), snapshot.homes.filter { $0.confidence == .confirmed }.count)
        }
        return localize("等待扫描")
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
        case .missing: licenseConfigurationAvailable ? localize("尚未开始试用") : localize("授权服务尚未配置")
        case .valid(let payload): payload.plan == "trial" ? localize("7 天试用中") : String(format: localize("已激活：%@"), payload.plan)
        case .needsRefresh: localize("授权有效，等待后台刷新")
        case .expired: localize("试用或授权已到期")
        case .invalid(let error): String(format: localize("本地授权无效：%@"), error.rawValue)
        case .rejected(let code): String(format: localize("授权被服务端拒绝：%@"), code)
        case .serviceUnavailable(let payload): payload == nil ? localize("授权服务暂时不可用") : localize("离线可用，授权服务暂时不可用")
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
            errorMessage = localize("请先开始试用或激活 License。")
            return
        }
        guard !isScanning, let coordinator else {
            if coordinator == nil { errorMessage = localize("内置 Agent Definition 无法加载") }
            return
        }
        isScanning = true
        errorMessage = nil
        let root = FileManager.default.homeDirectoryForCurrentUser
        scanTask = Task {
            do {
                let result = try await coordinator.scan(
                    request: ScanRequest(root: root, environment: ProcessInfo.processInfo.environment)
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
                if let catalog = try? AgentDefinitionCatalog.bundled() {
                    skillIndex = await SkillIndexUseCase(catalog: catalog).execute(homes: result.homes)
                }
            } catch is CancellationError {
                errorMessage = localize("扫描已停止；上一次完整快照仍保留。")
            } catch {
                errorMessage = String(format: localize("扫描失败：%@"), error.localizedDescription)
            }
            isScanning = false
            scanTask = nil
        }
    }

    func stopScan() {
        Task { await coordinator?.cancel() }
    }

    func startTrial() {
        guard let licenseManager else { return }
        Task {
            licenseState = await licenseManager.startTrial()
            reconcileLicensedTasks()
        }
    }

    func activate() {
        guard let licenseManager, !licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = licenseKey
        Task {
            licenseState = await licenseManager.activate(licenseKey: key)
            if hasCoreAccess {
                licenseKey = ""
            }
            reconcileLicensedTasks()
        }
    }

    private func loadLicense() async {
        guard let licenseManager else { return }
        let state = await licenseManager.loadLocalState()
        licenseState = state
        if case .needsRefresh = state {
            licenseState = await licenseManager.refresh()
        }
        reconcileLicensedTasks()
        startLicenseMonitoringIfNeeded()
    }

    private func startLicenseMonitoringIfNeeded() {
        guard licenseTask == nil, let licenseManager else { return }
        licenseTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                var state = await licenseManager.loadLocalState()
                if case .needsRefresh = state {
                    state = await licenseManager.refresh()
                }
                licenseState = state
                reconcileLicensedTasks()
            }
        }
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
                if let sample = try? await activitySampler.sample() {
                    activitySnapshot = sample
                    if historyEnabled, allows(.history) {
                        try? await historyStore.setEnabled(true)
                        try? await historyStore.append(sample)
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func setHistoryEnabled(_ value: Bool) {
        guard !value || allows(.history) else {
            errorMessage = localize("当前 License 不包含历史保存。")
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

    func refreshHistory() async {
        guard historyEnabled else { historyPoints = []; return }
        historyPoints = (try? await historyStore.points(
            from: Date().addingTimeInterval(-7 * 86_400),
            to: Date()
        )) ?? []
    }

    func exportHistoryCSV() {
        guard allows(.export) else {
            errorMessage = localize("当前 License 不包含导出。")
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

    func deleteLocalData() {
        stopScan()
        licenseTask?.cancel()
        licenseTask = nil
        activityTask?.cancel()
        activityTask = nil
        snapshot = nil
        skillIndex = nil
        activitySnapshot = nil
        historyPoints = []
        historyEnabled = false
        UserDefaults.standard.removeObject(forKey: "historyEnabled")
        Task {
            try? await historyStore.stopAndDelete()
            try? await licenseManager?.clearLocalCredentials()
            licenseState = .missing
        }
    }

    private static func decodeBase64URL(_ input: String) -> Data? {
        var value = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: value)
    }

    private func localize(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}
