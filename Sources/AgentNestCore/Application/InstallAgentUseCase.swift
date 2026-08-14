import Foundation

/// 安装失败原因（结构化、语言中立；文案由表现层翻译）。
public enum InstallAgentFailure: Equatable, Sendable {
    case brewNotFound
    case exited(code: Int)
}

/// 安装阶段（真实状态：定位 Homebrew → 运行 → 完成/失败/取消）。
public enum InstallAgentPhase: Equatable, Sendable {
    case locatingBrew
    case running
    case completed
    case cancelled
    case failed(InstallAgentFailure)
}

/// 安装进度事件：流式发布给 UI（输出尾部节流 ~0.25 s，保留最近若干行）。
public struct InstallAgentEvent: Equatable, Sendable {
    public let productID: String
    public let phase: InstallAgentPhase
    public let outputTail: [String]

    public init(productID: String, phase: InstallAgentPhase, outputTail: [String]) {
        self.productID = productID
        self.phase = phase
        self.outputTail = outputTail
    }
}

public enum InstallAgentError: Error, Equatable, Sendable {
    case brewNotFound
    case cancelled
    case exited(code: Int)
}

/// Agent 安装执行器：真实调用 Homebrew 安装公式（brew）或 Cask（brew install --cask）。
/// 输出逐行流式发布；支持取消（terminate 进程）；不伪造任何状态。
///
/// 注意：本方法为同步阻塞式（waitUntilExit 可能持续数分钟），必须在后台线程调用
/// （AppModel 经 Task.detached(.utility) 隔离）；事件回调从后台读取线程发出，
/// 由表现层自行转主线程。NSLock 保护进程句柄、取消集合与输出尾部。
public final class InstallAgentRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [String: Process] = [:]
    private var cancelledProducts: Set<String> = []

    public init() {}

    /// 取消指定产品的安装（幂等；未在安装时调用无效果）。
    public func cancel(productID: String) {
        lock.lock()
        cancelledProducts.insert(productID)
        let process = processes[productID]
        lock.unlock()
        process?.terminate()
    }

    /// 执行安装；完成/失败/取消以事件发布并抛出对应错误。同步阻塞，务必后台线程调用。
    public func install(
        productID: String,
        method: AgentInstallMethod,
        outputTailLimit: Int = 6,
        eventInterval: TimeInterval = 0.25,
        onEvent: @escaping @Sendable (InstallAgentEvent) -> Void
    ) throws {
        guard let brewPath = resolveBrewPath(), FileManager.default.isExecutableFile(atPath: brewPath) else {
            onEvent(InstallAgentEvent(productID: productID, phase: .failed(.brewNotFound), outputTail: []))
            throw InstallAgentError.brewNotFound
        }

        onEvent(InstallAgentEvent(productID: productID, phase: .locatingBrew, outputTail: []))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = method.kind == .cask
            ? ["install", "--cask", method.formula]
            : ["install", method.formula]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.lock()
        processes[productID] = process
        let wasAlreadyCancelled = cancelledProducts.contains(productID)
        lock.unlock()
        defer {
            lock.lock()
            processes[productID] = nil
            lock.unlock()
        }
        if wasAlreadyCancelled {
            onEvent(InstallAgentEvent(productID: productID, phase: .cancelled, outputTail: []))
            throw InstallAgentError.cancelled
        }

        // 输出读取线程：逐行累积尾部并节流发布；进程结束后管道 EOF 自然退出。
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            var tail: [String] = []
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
                    tail.append(line)
                    if tail.count > outputTailLimit {
                        tail.removeFirst(tail.count - outputTailLimit)
                    }
                }
                let now = Date()
                if now.timeIntervalSince(lastSent) >= eventInterval {
                    lastSent = now
                    onEvent(InstallAgentEvent(productID: productID, phase: .running, outputTail: tail))
                }
            }
            if !buffer.isEmpty {
                tail.append(buffer)
                if tail.count > outputTailLimit {
                    tail.removeFirst(tail.count - outputTailLimit)
                }
            }
            onEvent(InstallAgentEvent(productID: productID, phase: .running, outputTail: tail))
            readerDone.signal()
        }

        do {
            try process.run()
        } catch {
            readerDone.wait()
            onEvent(InstallAgentEvent(productID: productID, phase: .failed(.exited(code: -1)), outputTail: []))
            throw InstallAgentError.exited(code: -1)
        }
        process.waitUntilExit()
        readerDone.wait()

        lock.lock()
        let cancelled = cancelledProducts.contains(productID)
        lock.unlock()
        if cancelled {
            onEvent(InstallAgentEvent(productID: productID, phase: .cancelled, outputTail: []))
            throw InstallAgentError.cancelled
        }
        let status = Int(process.terminationStatus)
        if status != 0 {
            onEvent(InstallAgentEvent(productID: productID, phase: .failed(.exited(code: status)), outputTail: []))
            throw InstallAgentError.exited(code: status)
        }
        onEvent(InstallAgentEvent(productID: productID, phase: .completed, outputTail: []))
    }

    private func resolveBrewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
