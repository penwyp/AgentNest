import Darwin
import Foundation
import SQLite3

public struct CodexThreadCleanupAdapter: CleanupAdapter {
    public let id = "codex.thread"
    private let executablePaths: [String]?
    private let requestTimeout: TimeInterval

    public init(executablePaths: [String]? = nil, requestTimeout: TimeInterval = 12) {
        self.executablePaths = executablePaths
        self.requestTimeout = requestTimeout
    }

    public func discoverUnits(
        rule: ArtifactRule,
        home: AgentHome,
        snapshot: DeviceSnapshot,
        activity: ActivitySnapshot?
    ) -> [CleanupUnit] {
        guard rule.cleanup?.adapterID == id,
              rule.cleanup?.method == .officialPermanentDelete else { return [] }
        let databasePath = URL(fileURLWithPath: home.path).appending(path: "state_5.sqlite").path
        guard let database = try? CodexThreadDatabase(path: databasePath),
              let graph = try? database.readGraph() else { return [] }

        let ruleRoot = URL(fileURLWithPath: home.path)
            .appending(path: rule.relativePath)
            .standardizedFileURL.path
        let artifactsByPath = Dictionary(
            uniqueKeysWithValues: snapshot.storageLedger.artifacts
                .filter { $0.homeIDs.contains(home.id) }
                .map { ($0.path, $0) }
        )
        let cleanup = rule.cleanup!
        return graph.rootFamilies.compactMap { family in
            guard CanonicalPath.isEqualOrDescendant(family.root.rolloutPath, of: ruleRoot) else { return nil }
            let records = [family.root] + family.descendants
            let memberArtifacts = records.compactMap { artifactsByPath[$0.rolloutPath] }
            guard memberArtifacts.count == records.count,
                  memberArtifacts.allSatisfy({ $0.id.kind == .file }),
                  let rootArtifact = artifactsByPath[family.root.rolloutPath] else { return nil }
            let members = memberArtifacts.map(CleanupUnitMember.init)
            let storage = members.reduce(into: StorageMeasurement()) { result, member in
                result = StorageMeasurement(
                    logicalBytes: result.logicalBytes &+ member.storage.logicalBytes,
                    physicalBytes: result.physicalBytes &+ member.storage.physicalBytes,
                    itemCount: result.itemCount + member.storage.itemCount
                )
            }
            let lastActivity = records.map(\.updatedAt).max()
            return CleanupUnit(
                id: stableID(adapterID: id, home: home, nativeID: family.root.id),
                generation: snapshot.generation,
                productID: home.productID,
                path: family.root.rolloutPath,
                homePath: home.path,
                identity: rootArtifact.id,
                homeIdentity: home.id,
                name: family.root.id,
                category: rule.category,
                storage: storage,
                risk: cleanup.risk,
                activity: CleanupActivityEvaluator.protection(
                    homeID: home.id,
                    memberPaths: members.map(\.path),
                    activity: activity
                ),
                lastActivity: LastActivityEvidence(date: lastActivity, kind: .officialMetadata),
                method: cleanup.method,
                members: members,
                adapterID: id,
                nativeID: family.root.id,
                nativeMemberIDs: records.map(\.id).sorted()
            )
        }
    }

    public func execute(_ unit: CleanupUnit) async -> CleanupResult {
        guard unit.adapterID == id,
              let threadID = unit.nativeID,
              unit.method == .officialPermanentDelete else {
            return CleanupResult(unitID: unit.id, status: .failed, code: "cleanup.officialProtocolInvalid")
        }
        let databasePath = URL(fileURLWithPath: unit.homePath).appending(path: "state_5.sqlite").path
        guard let database = try? CodexThreadDatabase(path: databasePath),
              let graph = try? database.readGraph(),
              let currentFamily = graph.rootFamilies.first(where: { $0.root.id == threadID }) else {
            return CleanupResult(unitID: unit.id, status: .skipped, code: "cleanup.officialIdentityChanged")
        }
        let currentRecords = [currentFamily.root] + currentFamily.descendants
        guard currentRecords.map(\.id).sorted() == unit.nativeMemberIDs,
              Set(currentRecords.map(\.rolloutPath)) == Set(unit.members.map(\.path)) else {
            return CleanupResult(unitID: unit.id, status: .skipped, code: "cleanup.officialIdentityChanged")
        }
        let candidates = CodexExecutableLocator.locate(overrides: executablePaths)
        guard !candidates.isEmpty else {
            return CleanupResult(unitID: unit.id, status: .failed, code: "cleanup.officialExecutorUnavailable")
        }
        for candidate in candidates where candidate.isUnchanged {
            do {
                try await CodexJSONRPC.delete(
                    executable: candidate.path,
                    expectedHome: unit.homePath,
                    threadID: threadID,
                    requestTimeout: requestTimeout
                )
                return CleanupResult(unitID: unit.id, status: .succeeded, code: "cleanup.officialDeleted")
            } catch is CancellationError {
                return CleanupResult(unitID: unit.id, status: .cancelled, code: "cleanup.cancelled")
            } catch let error as CodexCleanupError where error.isSafetyRefusal {
                return CleanupResult(unitID: unit.id, status: .skipped, code: error.code)
            } catch {
                continue
            }
        }
        return CleanupResult(unitID: unit.id, status: .failed, code: "cleanup.officialDeleteFailed")
    }
}

private final class CodexThreadDatabase {
    struct Record {
        let id: String
        let rolloutPath: String
        let updatedAt: Date
    }

    struct Family {
        let root: Record
        let descendants: [Record]
    }

    struct Graph {
        let rootFamilies: [Family]
    }

    private var database: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              database != nil else {
            if let database { sqlite3_close(database) }
            throw CodexCleanupError.metadataUnavailable
        }
        guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database); self.database = nil }
            throw CodexCleanupError.metadataUnavailable
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func readGraph() throws -> Graph {
        let threadColumns = try columns(table: "threads")
        let edgeColumns = try columns(table: "thread_spawn_edges")
        guard Set(["id", "rollout_path", "updated_at", "updated_at_ms"]).isSubset(of: threadColumns),
              Set(["parent_thread_id", "child_thread_id"]).isSubset(of: edgeColumns) else {
            throw CodexCleanupError.metadataUnavailable
        }

        var records: [String: Record] = [:]
        try query("SELECT id, rollout_path, updated_at, updated_at_ms FROM threads") { statement in
            guard let rawID = Self.text(statement, 0),
                  let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
                  let rawPath = Self.text(statement, 1),
                  !rawPath.isEmpty,
                  records[id] == nil else { throw CodexCleanupError.metadataUnavailable }
            let milliseconds = sqlite3_column_int64(statement, 3)
            let seconds = milliseconds > 0
                ? TimeInterval(milliseconds) / 1_000
                : TimeInterval(sqlite3_column_int64(statement, 2))
            guard seconds > 0, seconds.isFinite else { throw CodexCleanupError.metadataUnavailable }
            records[id] = Record(
                id: id,
                rolloutPath: URL(fileURLWithPath: rawPath).standardizedFileURL.path,
                updatedAt: Date(timeIntervalSince1970: seconds)
            )
        }

        var parentByChild: [String: String] = [:]
        try query("SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges") { statement in
            guard let rawParent = Self.text(statement, 0),
                  let rawChild = Self.text(statement, 1),
                  let parent = UUID(uuidString: rawParent)?.uuidString.lowercased(),
                  let child = UUID(uuidString: rawChild)?.uuidString.lowercased(),
                  parent != child,
                  records[parent] != nil,
                  records[child] != nil,
                  parentByChild[child] == nil else { throw CodexCleanupError.metadataUnavailable }
            parentByChild[child] = parent
        }

        var membersByRoot: [String: [Record]] = [:]
        for record in records.values {
            var rootID = record.id
            var visited = Set<String>()
            while let parent = parentByChild[rootID] {
                guard visited.insert(rootID).inserted else { throw CodexCleanupError.metadataUnavailable }
                rootID = parent
            }
            membersByRoot[rootID, default: []].append(record)
        }
        let families = try membersByRoot.map { rootID, members -> Family in
            guard let root = records[rootID] else { throw CodexCleanupError.metadataUnavailable }
            return Family(
                root: root,
                descendants: members.filter { $0.id != rootID }.sorted { $0.id < $1.id }
            )
        }.sorted { $0.root.updatedAt > $1.root.updatedAt }
        return Graph(rootFamilies: families)
    }

    private func columns(table: String) throws -> Set<String> {
        var result = Set<String>()
        try query("PRAGMA table_info(\(table))") { statement in
            if let name = Self.text(statement, 1) { result.insert(name) }
        }
        return result
    }

    private func query(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CodexCleanupError.metadataUnavailable }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw CodexCleanupError.metadataUnavailable
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

private struct CodexExecutable {
    let path: String
    let device: UInt64
    let inode: UInt64

    var isUnchanged: Bool {
        var value = stat()
        return FileManager.default.isExecutableFile(atPath: path)
            && stat(path, &value) == 0
            && UInt64(value.st_dev) == device
            && UInt64(value.st_ino) == inode
    }
}

private enum CodexExecutableLocator {
    static func locate(overrides: [String]?) -> [CodexExecutable] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = overrides ?? ((environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex").path } + [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                home.appending(path: ".local/bin/codex").path,
                home.appending(path: ".npm/bin/codex").path,
                home.appending(path: ".local/share/mise/shims/codex").path,
            ])
        var identities = Set<String>()
        return paths.compactMap { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            var value = stat()
            guard FileManager.default.isExecutableFile(atPath: path), stat(path, &value) == 0 else { return nil }
            let identity = "\(value.st_dev):\(value.st_ino)"
            guard identities.insert(identity).inserted else { return nil }
            return CodexExecutable(path: path, device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
        }
    }
}

private enum CodexCleanupError: Error {
    case metadataUnavailable
    case startup
    case homeMismatch
    case timedOut
    case invalidResponse
    case officialDeleteFailed
    case threadIdentityChanged

    var isSafetyRefusal: Bool {
        self == .homeMismatch || self == .threadIdentityChanged
    }

    var code: String {
        switch self {
        case .homeMismatch: "cleanup.officialHomeChanged"
        case .threadIdentityChanged: "cleanup.officialIdentityChanged"
        case .metadataUnavailable: "cleanup.officialMetadataUnavailable"
        case .startup: "cleanup.officialStartupFailed"
        case .timedOut: "cleanup.officialTimedOut"
        case .invalidResponse: "cleanup.officialProtocolInvalid"
        case .officialDeleteFailed: "cleanup.officialDeleteFailed"
        }
    }
}

private enum CodexJSONRPC {
    static func delete(
        executable: String,
        expectedHome: String,
        threadID: String,
        requestTimeout: TimeInterval
    ) async throws {
        let operation = Task.detached(priority: .userInitiated) {
            let client: Client
            do {
                client = try Client(
                    executable: executable,
                    codexHome: expectedHome,
                    requestTimeout: requestTimeout
                )
            } catch {
                throw CodexCleanupError.startup
            }
            defer { client.stop() }
            try client.initialize(expectedHome: expectedHome)
            let before = try client.request(
                id: 2,
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": false]
            )
            if let error = before.error {
                if error.isNotFound { throw CodexCleanupError.threadIdentityChanged }
                throw CodexCleanupError.officialDeleteFailed
            }
            guard let thread = before.result?.objectValue?["thread"]?.objectValue,
                  thread["id"]?.stringValue?.lowercased() == threadID.lowercased(),
                  thread["parentThreadId"] == nil || thread["parentThreadId"] == .null else {
                throw CodexCleanupError.threadIdentityChanged
            }
            let deletion = try client.request(
                id: 3,
                method: "thread/delete",
                params: ["threadId": threadID]
            )
            guard deletion.error == nil else { throw CodexCleanupError.officialDeleteFailed }
            let after = try client.request(
                id: 4,
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": false]
            )
            guard after.error?.isNotFound == true else { throw CodexCleanupError.officialDeleteFailed }
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private final class Client: @unchecked Sendable {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let requestTimeout: TimeInterval
        private var pending = Data()

        init(executable: String, codexHome: String, requestTimeout: TimeInterval) throws {
            self.requestTimeout = requestTimeout
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server"]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func initialize(expectedHome: String) throws {
            let response = try request(
                id: 1,
                method: "initialize",
                params: [
                    "clientInfo": ["name": "agentnest", "title": "AgentNest", "version": "0.1.0"],
                    "capabilities": ["experimentalApi": false],
                ]
            )
            guard response.error == nil,
                  let returnedHome = response.result?.objectValue?["codexHome"]?.stringValue else {
                throw CodexCleanupError.invalidResponse
            }
            let expected = URL(fileURLWithPath: expectedHome).resolvingSymlinksInPath().standardizedFileURL.path
            let actual = URL(fileURLWithPath: returnedHome).resolvingSymlinksInPath().standardizedFileURL.path
            guard expected == actual else { throw CodexCleanupError.homeMismatch }
            try send(["method": "initialized"])
        }

        func request(id: Int, method: String, params: [String: Any]) throws -> RPCEnvelope {
            try send(["id": id, "method": method, "params": params])
            let deadline = Date().addingTimeInterval(requestTimeout)
            while Date() < deadline {
                let line = try readLine(deadline: deadline)
                guard let data = line.data(using: .utf8),
                      let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: data),
                      envelope.id == id else { continue }
                return envelope
            }
            throw CodexCleanupError.timedOut
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            guard process.isRunning else { return }
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        private func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        private func readLine(deadline: Date) throws -> String {
            while true {
                try Task.checkCancellation()
                guard Date() < deadline else { throw CodexCleanupError.timedOut }
                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    return String(decoding: line, as: UTF8.self)
                }
                let milliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
                var descriptor = pollfd(
                    fd: output.fileHandleForReading.fileDescriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                guard poll(&descriptor, 1, milliseconds) > 0 else { throw CodexCleanupError.timedOut }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw CodexCleanupError.invalidResponse }
                guard chunk.count <= 1_048_576,
                      pending.count <= 1_048_576 - chunk.count else {
                    throw CodexCleanupError.invalidResponse
                }
                pending.append(chunk)
            }
        }
    }
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let result: JSONValue?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let code: Int?
    let message: String?

    var isNotFound: Bool {
        message?.localizedCaseInsensitiveContains("not found") == true
    }
}

private enum JSONValue: Decodable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }
}
