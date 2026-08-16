import Foundation

/// 安装失败原因（结构化、语言中立；文案由表现层翻译）。
public enum InstallAgentFailure: Equatable, Sendable {
    case brewNotFound
    case homebrewInstallFailed
    case nodeInstallFailed
    case scriptDownloadFailed
    case authorizationRequired
    case permissionDenied
    case websiteInstallerClosed
    case websiteInstallerTimedOut
    case exited(code: Int)
}

/// 安装阶段（真实状态：检测环境 → 准备依赖 → 运行安装器 → 验证）。
public enum InstallAgentPhase: Equatable, Sendable {
    case locatingBrew
    case preparingDependencies
    case running
    case completed
    case cancelled
    case failed(InstallAgentFailure)
}

/// 横向步骤进度条使用的步骤。
public enum InstallAgentStep: String, CaseIterable, Codable, Sendable {
    case detectingEnvironment
    case preparingDependencies
    case runningInstaller
    case verifyingInstallation
}

/// 安装进度事件：流式发布给 UI（输出尾部节流 ~0.25 s，保留最近若干行）。
public struct InstallAgentEvent: Equatable, Sendable {
    public let productID: String
    public let phase: InstallAgentPhase
    public let step: InstallAgentStep
    public let outputTail: [String]

    public init(
        productID: String,
        phase: InstallAgentPhase,
        step: InstallAgentStep = .detectingEnvironment,
        outputTail: [String]
    ) {
        self.productID = productID
        self.phase = phase
        self.step = step
        self.outputTail = outputTail
    }
}

public enum InstallAgentError: Error, Equatable, Sendable {
    case brewNotFound
    case cancelled
    case homebrewInstallFailed
    case nodeInstallFailed
    case scriptDownloadFailed
    case authorizationRequired
    case websiteInstallerClosed
    case websiteInstallerTimedOut
    case exited(code: Int)
}

/// Agent 安装执行器：面向小白用户的分布安装。
///
/// 流程：
/// 1. 检测 Homebrew / Node / npm 环境，并按需配置中国大陆镜像；
/// 2. Definition 提供官方脚本时优先执行脚本（脚本自身处理环境）；
/// 3. 脚本缺失或失败时回退到 Homebrew；Homebrew 缺失时先安装 Homebrew，
///    需要管理员权限时通过 macOS 授权弹窗请求用户授权；
/// 4. 依赖 Node 的脚本安装会先补装 node/npm；
/// 5. 最后做安装验证。
///
private final class InstallProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ line: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        return lines
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// 注意：本方法为同步阻塞式（安装可能持续数分钟），必须在后台线程调用。
public final class InstallAgentRunner: @unchecked Sendable {
    private struct EnvironmentInfo {
        var brewURL: URL?
        var nodeURL: URL?
        var npmURL: URL?
        var usesChinaMirrors: Bool
    }

    private let lock = NSLock()
    private var processes: [String: Process] = [:]
    private var cancelledProducts: Set<String> = []

    public init() {}

    public func cancel(productID: String) {
        lock.lock()
        cancelledProducts.insert(productID)
        let process = processes[productID]
        lock.unlock()
        process?.terminate()
    }

    public func install(
        productID: String,
        method: AgentInstallMethod,
        outputTailLimit: Int = 6,
        eventInterval: TimeInterval = 0.25,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        guard !isCancelled(productID) else {
            onEvent(InstallAgentEvent(productID: productID, phase: .cancelled, outputTail: []))
            throw InstallAgentError.cancelled
        }

        var environment = detectEnvironment()
        onEvent(InstallAgentEvent(
            productID: productID,
            phase: .locatingBrew,
            step: .detectingEnvironment,
            outputTail: environmentSummary(environment)
        ))
        try Task.checkCancellation()

        let childEnvironment = mirroredEnvironment(base: environment)
        onEvent(InstallAgentEvent(
            productID: productID,
            phase: .preparingDependencies,
            step: .preparingDependencies,
            outputTail: []
        ))

        do {
            var installedViaBrew = false
            if let scriptURL = method.scriptURL {
                onEvent(InstallAgentEvent(
                    productID: productID,
                    phase: .preparingDependencies,
                    step: .preparingDependencies,
                    outputTail: ["Preferring official install script: \(scriptURL)"]
                ))
                if method.requiresNode == true {
                    try ensureNode(
                        productID: productID,
                        environment: &environment,
                        childEnvironment: childEnvironment,
                        outputTailLimit: outputTailLimit,
                        eventInterval: eventInterval,
                        onEvent: onEvent
                    )
                }
                do {
                    try runOfficialScript(
                        productID: productID,
                        scriptURL: scriptURL,
                        childEnvironment: childEnvironment,
                        outputTailLimit: outputTailLimit,
                        eventInterval: eventInterval,
                        onEvent: onEvent
                    )
                } catch InstallAgentError.cancelled {
                    throw InstallAgentError.cancelled
                } catch {
                    guard method.kind == .brew || method.kind == .cask else { throw error }
                    onEvent(InstallAgentEvent(
                        productID: productID,
                        phase: .preparingDependencies,
                        step: .preparingDependencies,
                        outputTail: ["Script installer failed; falling back to Homebrew."]
                    ))
                    try ensureHomebrew(
                        productID: productID,
                        environment: &environment,
                        childEnvironment: childEnvironment,
                        outputTailLimit: outputTailLimit,
                        eventInterval: eventInterval,
                        onEvent: onEvent
                    )
                    try runBrew(
                        productID: productID,
                        method: method,
                        environment: &environment,
                        childEnvironment: childEnvironment,
                        outputTailLimit: outputTailLimit,
                        eventInterval: eventInterval,
                        onEvent: onEvent
                    )
                    installedViaBrew = true
                }
            } else if method.kind == .npm {
                try ensureNode(
                    productID: productID,
                    environment: &environment,
                    childEnvironment: childEnvironment,
                    outputTailLimit: outputTailLimit,
                    eventInterval: eventInterval,
                    onEvent: onEvent
                )
                try runNpm(
                    productID: productID,
                    method: method,
                    environment: &environment,
                    childEnvironment: childEnvironment,
                    outputTailLimit: outputTailLimit,
                    eventInterval: eventInterval,
                    onEvent: onEvent
                )
            } else if method.kind == .website {
                try runWebsiteInstaller(
                    productID: productID,
                    method: method,
                    childEnvironment: childEnvironment,
                    outputTailLimit: outputTailLimit,
                    eventInterval: eventInterval,
                    onEvent: onEvent
                )
            } else {
                try ensureHomebrew(
                    productID: productID,
                    environment: &environment,
                    childEnvironment: childEnvironment,
                    outputTailLimit: outputTailLimit,
                    eventInterval: eventInterval,
                    onEvent: onEvent
                )
                try runBrew(
                    productID: productID,
                    method: method,
                    environment: &environment,
                    childEnvironment: childEnvironment,
                    outputTailLimit: outputTailLimit,
                    eventInterval: eventInterval,
                    onEvent: onEvent
                )
                installedViaBrew = true
            }

            guard !isCancelled(productID) else {
                onEvent(InstallAgentEvent(productID: productID, phase: .cancelled, outputTail: []))
                throw InstallAgentError.cancelled
            }
            onEvent(InstallAgentEvent(
                productID: productID,
                phase: .running,
                step: .verifyingInstallation,
                outputTail: []
            ))
            try verifyInstallation(
                productID: productID,
                method: method,
                environment: environment,
                childEnvironment: childEnvironment,
                verifyWithBrew: installedViaBrew,
                outputTailLimit: outputTailLimit,
                eventInterval: eventInterval,
                onEvent: onEvent
            )
            onEvent(InstallAgentEvent(
                productID: productID,
                phase: .completed,
                step: .verifyingInstallation,
                outputTail: []
            ))
        } catch let error as InstallAgentError {
            throw error
        } catch {
            throw InstallAgentError.exited(code: -1)
        }
    }

    // MARK: - 环境检测

    private func detectEnvironment() -> EnvironmentInfo {
        let base = ProcessInfo.processInfo.environment
        var env = EnvironmentInfo(
            brewURL: Self.resolveExecutable(named: "brew", environment: base)
                ?? Self.fixedBrewURLs().first,
            nodeURL: nil,
            npmURL: nil,
            usesChinaMirrors: Self.isLikelyChinaNetwork(environment: base)
        )
        env.nodeURL = Self.resolveExecutable(named: "node", environment: base)
        env.npmURL = Self.resolveExecutable(named: "npm", environment: base)
        return env
    }

    private func environmentSummary(_ environment: EnvironmentInfo) -> [String] {
        var lines: [String] = []
        lines.append(environment.brewURL == nil ? "Homebrew: missing" : "Homebrew: \(environment.brewURL!.path)")
        lines.append(environment.nodeURL == nil ? "Node.js: missing" : "Node.js: \(environment.nodeURL!.path)")
        lines.append(environment.npmURL == nil ? "npm: missing" : "npm: \(environment.npmURL!.path)")
        lines.append(environment.usesChinaMirrors ? "Region: China mirrors enabled" : "Region: default mirrors")
        return lines
    }

    private func mirroredEnvironment(base: EnvironmentInfo) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        guard base.usesChinaMirrors else { return values }
        values["HOMEBREW_API_DOMAIN"] = "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
        values["HOMEBREW_BOTTLE_DOMAIN"] = "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
        values["HOMEBREW_BREW_GIT_REMOTE"] = "https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
        values["HOMEBREW_CORE_GIT_REMOTE"] = "https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
        values["npm_config_registry"] = "https://registry.npmmirror.com"
        values["NPM_CONFIG_REGISTRY"] = "https://registry.npmmirror.com"
        return values
    }

    private static func isLikelyChinaNetwork(environment: [String: String]) -> Bool {
        if environment["AGENTNEST_CHINA_MIRRORS"] == "1" { return true }
        let region = Locale.current.region?.identifier.uppercased()
        let timezone = TimeZone.current.identifier
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        return region == "CN" || timezone == "Asia/Shanghai" || language.hasPrefix("zh-hans-cn")
    }

    // MARK: - 依赖安装

    private func ensureHomebrew(
        productID: String,
        environment: inout EnvironmentInfo,
        childEnvironment: [String: String],
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        if let brewURL = environment.brewURL,
           FileManager.default.isExecutableFile(atPath: brewURL.path) { return }
        guard let curlURL = Self.resolveExecutable(named: "curl", environment: childEnvironment) else {
            throw InstallAgentError.homebrewInstallFailed
        }
        let temporaryScript = FileManager.default.temporaryDirectory
            .appending(path: "agentnest-homebrew-install-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: temporaryScript) }
        try download(
            productID: productID,
            url: URL(string: "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")!,
            to: temporaryScript,
            curlURL: curlURL,
            childEnvironment: childEnvironment,
            step: .preparingDependencies,
            phase: .preparingDependencies,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )

        do {
            _ = try runProcess(
                productID: productID,
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [temporaryScript.path],
                environment: childEnvironment,
                step: .preparingDependencies,
                phase: .preparingDependencies,
                outputTailLimit: outputTailLimit,
                eventInterval: eventInterval,
                onEvent: onEvent
            )
        } catch InstallAgentError.cancelled {
            throw InstallAgentError.cancelled
        } catch {
            onEvent(InstallAgentEvent(
                productID: productID,
                phase: .preparingDependencies,
                step: .preparingDependencies,
                outputTail: ["Requesting administrator authorization for Homebrew."]
            ))
            let envAssignments = childEnvironment
                .filter { $0.key.uppercased().hasPrefix("HOMEBREW_") }
                .map { "\($0.key)='\($0.value)'" }
                .joined(separator: " ")
            let shellCommand = "\(envAssignments) /bin/bash '\(temporaryScript.path)'"
            let osascript = "do shell script \(Self.appleScriptString(shellCommand)) with administrator privileges"
            do {
                _ = try runProcess(
                    productID: productID,
                    executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", osascript],
                    environment: nil,
                    step: .preparingDependencies,
                    phase: .preparingDependencies,
                    outputTailLimit: outputTailLimit,
                    eventInterval: eventInterval,
                    onEvent: onEvent
                )
            } catch {
                throw InstallAgentError.authorizationRequired
            }
        }

        let base = childEnvironment
        environment.brewURL = Self.resolveExecutable(named: "brew", environment: base)
            ?? Self.fixedBrewURLs().first
        guard environment.brewURL != nil else { throw InstallAgentError.homebrewInstallFailed }
    }

    private func ensureNode(
        productID: String,
        environment: inout EnvironmentInfo,
        childEnvironment: [String: String],
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        let base = childEnvironment
        environment.nodeURL = Self.resolveExecutable(named: "node", environment: base)
        environment.npmURL = Self.resolveExecutable(named: "npm", environment: base)
        if environment.nodeURL != nil, environment.npmURL != nil { return }

        onEvent(InstallAgentEvent(
            productID: productID,
            phase: .preparingDependencies,
            step: .preparingDependencies,
            outputTail: ["Node.js/npm required; installing through Homebrew."]
        ))
        try ensureHomebrew(
            productID: productID,
            environment: &environment,
            childEnvironment: childEnvironment,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
        _ = try runProcess(
            productID: productID,
            executableURL: environment.brewURL!,
            arguments: ["install", "node"],
            environment: childEnvironment,
            step: .preparingDependencies,
            phase: .preparingDependencies,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
        environment.nodeURL = Self.resolveExecutable(named: "node", environment: childEnvironment)
        environment.npmURL = Self.resolveExecutable(named: "npm", environment: childEnvironment)
        guard environment.nodeURL != nil, environment.npmURL != nil else {
            throw InstallAgentError.nodeInstallFailed
        }
    }

    // MARK: - 安装执行

    private func runOfficialScript(
        productID: String,
        scriptURL: String,
        childEnvironment: [String: String],
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        guard let url = URL(string: scriptURL),
              let curlURL = Self.resolveExecutable(named: "curl", environment: childEnvironment) else {
            throw InstallAgentError.scriptDownloadFailed
        }
        let temporaryScript = FileManager.default.temporaryDirectory
            .appending(path: "agentnest-agent-install-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: temporaryScript) }
        try download(
            productID: productID,
            url: url,
            to: temporaryScript,
            curlURL: curlURL,
            childEnvironment: childEnvironment,
            step: .runningInstaller,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
        _ = try runProcess(
            productID: productID,
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [temporaryScript.path],
            environment: childEnvironment,
            step: .runningInstaller,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
    }

    private func runNpm(
        productID: String,
        method: AgentInstallMethod,
        environment: inout EnvironmentInfo,
        childEnvironment: [String: String],
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        guard let npmURL = environment.npmURL else { throw InstallAgentError.nodeInstallFailed }
        _ = try runProcess(
            productID: productID,
            executableURL: npmURL,
            arguments: ["install", "-g", method.formula],
            environment: childEnvironment,
            step: .runningInstaller,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
    }

    private func runWebsiteInstaller(
        productID: String,
        method: AgentInstallMethod,
        childEnvironment: [String: String],
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        guard let updateURLTemplate = method.websiteUpdateURL,
              let appName = method.installedAppName,
              let curlURL = Self.resolveExecutable(named: "curl", environment: childEnvironment) else {
            throw InstallAgentError.scriptDownloadFailed
        }

        let architecture = Self.currentArchitecture()
        let platform = "\(method.formula.lowercased())-darwin-\(architecture == "arm64" ? "arm64" : "x64")"
        let updateURL = updateURLTemplate.replacingOccurrences(of: "{platform}", with: platform)
        let updateFile = FileManager.default.temporaryDirectory
            .appending(path: "agentnest-website-update-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: updateFile) }

        onEvent(InstallAgentEvent(
            productID: productID,
            phase: .running,
            step: .runningInstaller,
            outputTail: ["Checking latest installer from \(updateURL)"]
        ))
        _ = try runProcess(
            productID: productID,
            executableURL: curlURL,
            arguments: ["-fsSL", updateURL, "-o", updateFile.path],
            environment: childEnvironment,
            step: .runningInstaller,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )

        let updateData = try Data(contentsOf: updateFile, options: [.mappedIfSafe])
        guard let updateJSON = try JSONSerialization.jsonObject(with: updateData) as? [String: Any],
              let rawURL = updateJSON["url"] as? String,
              let rawVersion = updateJSON["version"] as? String
                ?? (updateJSON["version"] as? NSNumber)?.stringValue
                ?? updateJSON["productVersion"] as? String
                ?? (updateJSON["productVersion"] as? NSNumber)?.stringValue else {
            throw InstallAgentError.scriptDownloadFailed
        }
        let expectedVersion = AgentVersion.normalizedVersion(rawVersion)
        if let installedVersion = Self.installedAppVersion(appName: appName),
           AgentVersion.isSameRelease(installedVersion, expectedVersion) {
            onEvent(InstallAgentEvent(
                productID: productID,
                phase: .running,
                step: .runningInstaller,
                outputTail: ["\(appName) \(installedVersion) is already installed."]
            ))
            return
        }
        let dmgURL = rawURL.hasSuffix(".zip")
            ? String(rawURL.dropLast(4)) + ".dmg"
            : rawURL

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let packageName = "\(appName)-\(expectedVersion).dmg"
        let destination = downloads.appending(path: packageName)

        onEvent(InstallAgentEvent(
            productID: productID,
            phase: .running,
            step: .runningInstaller,
            outputTail: ["Downloading \(dmgURL)"]
        ))
        _ = try runProcess(
            productID: productID,
            executableURL: curlURL,
            arguments: ["-fL", "--retry", "3", "-C", "-", dmgURL, "-o", destination.path],
            environment: childEnvironment,
            step: .runningInstaller,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )

        onEvent(InstallAgentEvent(
            productID: productID,
            phase: .running,
            step: .runningInstaller,
            outputTail: ["Opening installer; waiting for \(appName).app"]
        ))
        _ = try runProcess(
            productID: productID,
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [destination.path],
            environment: nil,
            step: .runningInstaller,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )

        let deadline = Date().addingTimeInterval(30 * 60)
        var didObserveInstallerVolume = false
        while Date() < deadline {
            if isCancelled(productID) { throw InstallAgentError.cancelled }
            if let installedVersion = Self.installedAppVersion(appName: appName),
               AgentVersion.isSameRelease(installedVersion, expectedVersion) { return }

            let mountedVolumeNames = Self.mountedVolumeNames()
            let installerVolumeMounted = mountedVolumeNames.contains { volumeName in
                let lhs = volumeName.lowercased()
                let rhs = appName.lowercased()
                return lhs.contains(rhs) || rhs.contains(lhs)
            }
            if installerVolumeMounted {
                didObserveInstallerVolume = true
            } else if didObserveInstallerVolume {
                onEvent(InstallAgentEvent(
                    productID: productID,
                    phase: .failed(.websiteInstallerClosed),
                    step: .runningInstaller,
                    outputTail: ["Installer volume was ejected before installation completed."]
                ))
                throw InstallAgentError.websiteInstallerClosed
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw InstallAgentError.websiteInstallerTimedOut
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
        #else
        return "arm64"
        #endif
    }

    private static func mountedVolumeNames() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        return Set(urls.map { $0.lastPathComponent.lowercased() })
    }

    private static func installedAppVersion(appName: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications").appending(path: "\(appName).app"),
            home.appending(path: "Applications/\(appName).app"),
        ]
        for candidate in candidates {
            guard let bundle = Bundle(path: candidate.path) else { continue }
            let rawVersion: String?
            if let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
                rawVersion = value
            } else if let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? NSNumber {
                rawVersion = value.stringValue
            } else {
                rawVersion = nil
            }
            guard let rawVersion else { continue }
            let version = AgentVersion.normalizedVersion(rawVersion)
            if !version.isEmpty { return version }
        }
        return nil
    }

    private func runBrew(
        productID: String,
        method: AgentInstallMethod,
        environment: inout EnvironmentInfo,
        childEnvironment: [String: String],
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        guard let brewURL = environment.brewURL else { throw InstallAgentError.brewNotFound }
        let arguments = method.kind == .cask
            ? ["install", "--cask", method.formula]
            : ["install", method.formula]
        _ = try runProcess(
            productID: productID,
            executableURL: brewURL,
            arguments: arguments,
            environment: childEnvironment,
            step: .runningInstaller,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
    }

    private func verifyInstallation(
        productID: String,
        method: AgentInstallMethod,
        environment: EnvironmentInfo,
        childEnvironment: [String: String],
        verifyWithBrew: Bool,
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        guard verifyWithBrew, let brewURL = environment.brewURL else { return }
        let arguments = method.kind == .cask
            ? ["list", "--versions", "--cask", method.formula]
            : ["list", "--versions", "--formula", method.formula]
        _ = try runProcess(
            productID: productID,
            executableURL: brewURL,
            arguments: arguments,
            environment: childEnvironment,
            step: .verifyingInstallation,
            phase: .running,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
    }

    // MARK: - Process 运行

    private func download(
        productID: String,
        url: URL,
        to destination: URL,
        curlURL: URL,
        childEnvironment: [String: String],
        step: InstallAgentStep,
        phase: InstallAgentPhase,
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        _ = try runProcess(
            productID: productID,
            executableURL: curlURL,
            arguments: ["-fsSL", url.absoluteString, "-o", destination.path],
            environment: childEnvironment,
            step: step,
            phase: phase,
            outputTailLimit: outputTailLimit,
            eventInterval: eventInterval,
            onEvent: onEvent
        )
    }

    private func runProcess(
        productID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        step: InstallAgentStep,
        phase: InstallAgentPhase,
        outputTailLimit: Int,
        eventInterval: TimeInterval,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws -> Int {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.lock()
        processes[productID] = process
        let alreadyCancelled = cancelledProducts.contains(productID)
        lock.unlock()
        defer {
            lock.lock()
            processes[productID] = nil
            lock.unlock()
        }
        if alreadyCancelled {
            onEvent(InstallAgentEvent(productID: productID, phase: .cancelled, outputTail: []))
            throw InstallAgentError.cancelled
        }

        let readerDone = DispatchSemaphore(value: 0)
        let output = InstallProcessOutput(limit: outputTailLimit)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            var buffer = ""
            var lastSent = Date.distantPast
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                buffer += chunk
                var lines = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if !buffer.hasSuffix("\n") {
                    buffer = lines.removeLast()
                } else {
                    buffer = ""
                }
                for line in lines where !line.isEmpty {
                    _ = output.append(line)
                }
                let now = Date()
                if now.timeIntervalSince(lastSent) >= eventInterval {
                    lastSent = now
                    onEvent(InstallAgentEvent(
                        productID: productID,
                        phase: phase,
                        step: step,
                        outputTail: output.snapshot()
                    ))
                }
            }
            if !buffer.isEmpty {
                _ = output.append(buffer)
            }
            onEvent(InstallAgentEvent(
                productID: productID,
                phase: phase,
                step: step,
                outputTail: output.snapshot()
            ))
            readerDone.signal()
        }

        do {
            try process.run()
        } catch {
            readerDone.wait()
            onEvent(InstallAgentEvent(
                productID: productID,
                phase: .failed(.exited(code: -1)),
                step: step,
                outputTail: output.snapshot()
            ))
            throw InstallAgentError.exited(code: -1)
        }
        process.waitUntilExit()
        readerDone.wait()

        lock.lock()
        let cancelled = cancelledProducts.contains(productID)
        lock.unlock()
        if cancelled {
            onEvent(InstallAgentEvent(productID: productID, phase: .cancelled, outputTail: output.snapshot()))
            throw InstallAgentError.cancelled
        }
        let status = Int(process.terminationStatus)
        guard status == 0 else {
            onEvent(InstallAgentEvent(
                productID: productID,
                phase: .failed(.exited(code: status)),
                step: step,
                outputTail: output.snapshot()
            ))
            throw InstallAgentError.exited(code: status)
        }
        return status
    }

    // MARK: - Helpers

    private func isCancelled(_ productID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledProducts.contains(productID)
    }

    private static func fixedBrewURLs() -> [URL] {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private static func resolveExecutable(named name: String, environment: [String: String]) -> URL? {
        let pathValue = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in pathValue.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory), isDirectory: true).appending(path: name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
