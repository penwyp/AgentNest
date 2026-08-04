import AgentNestCore
import CryptoKit
import Darwin
import Foundation

@main
struct AgentNestCoreTestRunner {
    static func main() async {
        do {
            try testDefinitionCatalog()
            try await testScan()
            try await testSkills()
            try await testCleanupPolicy()
            try testActivityRates()
            try await testHistoryStore()
            try await testReceipts()
            print("AgentNestCore tests passed (34 checks)")
        } catch {
            FileHandle.standardError.write(Data("AgentNestCore tests failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func testDefinitionCatalog() throws {
        let catalog = try AgentDefinitionCatalog.bundled()
        try expect(catalog.definitions.count == 3, "bundled definition count")
        try expect(catalog.definitions.filter(\.participatesInScanning).map(\.id) == ["openai.codex"], "only Codex scans")
        try expect(catalog.definitions.filter { !$0.participatesInScanning }.allSatisfy {
            !$0.capabilities.space && !$0.capabilities.skills && !$0.capabilities.activity && !$0.capabilities.cleanup
        }, "empty definitions expose no capabilities")

        let unknown = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test","unexpected":true,
        "homeDiscovery":{"defaultPaths":[],"environmentVariables":[],"allowDeepDiscovery":false},
        "fingerprints":{"required":[],"optional":[],"negative":[]},"skills":[],"artifacts":[],
        "capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8)
        try expectThrows("unknown definition field") { _ = try AgentDefinitionCatalog.load(data: unknown) }

        let unsafe = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test",
        "homeDiscovery":{"defaultPaths":["~/.test"],"environmentVariables":[],"allowDeepDiscovery":true},
        "fingerprints":{"required":[{"kind":"file","relativePath":"../outside"}],"optional":[],"negative":[]},
        "skills":[],"artifacts":[],"capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8)
        try expectThrows("unsafe definition path") { _ = try AgentDefinitionCatalog.load(data: unsafe) }
    }

    private static func testScan() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AgentNestTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultHome = root.appending(path: ".codex")
        let deepHome = root.appending(path: "projects/.hidden/nested/codex-home")
        let possibleHome = root.appending(path: "archive/.codex")
        let alias = root.appending(path: "default-alias")
        for directory in [defaultHome, deepHome, possibleHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("{\"version\":\"fixture\"}".utf8).write(to: defaultHome.appending(path: "version.json"))
        try Data("{\"version\":\"fixture\"}".utf8).write(to: deepHome.appending(path: "version.json"))
        let blob = defaultHome.appending(path: "blob.bin")
        try Data(repeating: 42, count: 8192).write(to: blob)
        try FileManager.default.linkItem(at: blob, to: defaultHome.appending(path: "blob-copy.bin"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: defaultHome)

        let snapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(
            root: root,
            customLocations: [alias],
            environment: ["CODEX_HOME": deepHome.path]
        ))
        let confirmed = snapshot.homes.filter { $0.confidence == .confirmed }
        let possible = snapshot.homes.filter { $0.confidence == .possible }
        try expect(confirmed.count == 2 && Set(confirmed.map(\.id)).count == 2, "multi-home discovery and physical alias deduplication")
        try expect(possible.count == 1 && possible.first?.path == possibleHome.path, "similar directory remains possible")
        let defaultResult = try unwrap(confirmed.first { $0.path == defaultHome.path }, "default home")
        try expect(defaultResult.storage.itemCount == 3, "hard links count once in physical ledger; got \(defaultResult.storage.itemCount)")

        try Data("not-json".utf8).write(to: defaultHome.appending(path: "version.json"))
        let malformedSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(root: root))
        try expect(malformedSnapshot.homes.first { $0.path == defaultHome.path }?.confidence == .possible, "malformed JSON fails closed")

        let cancelledTask = Task {
            try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(root: root))
        }
        cancelledTask.cancel()
        let partial = try await cancelledTask.value
        try expect(partial.isPartial && partial.coverage.directories == .partial, "cancelled scan publishes a partial generation")

        let missingRoot = root.appending(path: "missing-scan-root")
        let unavailable = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(root: missingRoot))
        try expect(
            unavailable.isPartial && unavailable.coverage.unreadableLocationCount == 1,
            "unavailable root is represented as partial coverage"
        )
    }

    private static func testReceipts() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let machineHash = MachineIdentityProvider.hash(rawMachineIdentifier: "fixture-device-a")
        let now = Date()
        let payload = makePayload(machineHash: machineHash, issuedAt: now.addingTimeInterval(-60), offlineUntil: now.addingTimeInterval(7200))
        let envelope = try sign(payload, with: privateKey)
        let verifier = try ReceiptVerifier(publicKeyData: privateKey.publicKey.rawRepresentation)
        try expect(try verifier.verify(envelope, machineIDHash: machineHash).licenseId == "lic_fixture", "valid receipt")
        try expectThrows("cross-device receipt") {
            _ = try verifier.verify(envelope, machineIDHash: MachineIdentityProvider.hash(rawMachineIdentifier: "fixture-device-b"))
        }
        try expectThrows("tampered receipt") {
            _ = try verifier.verify(SignedEntitlementReceipt(payload: envelope.payload + "A", signature: envelope.signature), machineIDHash: machineHash)
        }
        let expired = makePayload(machineHash: machineHash, issuedAt: now.addingTimeInterval(-7200), offlineUntil: now.addingTimeInterval(-1))
        try expectThrows("expired offline window") {
            _ = try verifier.verify(try sign(expired, with: privateKey), machineIDHash: machineHash, now: now)
        }

        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentNestReceiptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReceiptStore(fileURL: directory.appending(path: "License/entitlement.receipt"))
        try store.save(envelope)
        try store.save(SignedEntitlementReceipt(payload: "second", signature: "signature"))
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        try expect(mode?.intValue == 0o600, "receipt owner-only permissions")

        let manager = LicenseManager(
            verifier: verifier,
            service: LicenseServiceClient(baseURL: URL(string: "http://127.0.0.1:1")!),
            receiptStore: store,
            credentialStore: MemoryCredentialStore(),
            machineIDHash: machineHash
        )
        let localState = await manager.loadLocalState(now: now)
        if case .invalid = localState {
            // The store was intentionally overwritten above; restore a signed receipt and verify startup behavior.
            try store.save(envelope)
        }
        let restoredState = await manager.loadLocalState(now: now)
        guard case .valid(let restoredPayload) = restoredState else { throw TestFailure("license manager rejected valid local receipt") }
        try expect(restoredPayload.licenseId == "lic_fixture", "license manager starts from verified local receipt")
        try expect(!String(describing: restoredState).contains("fixture-device-a"), "receipt state does not expose raw machine identifier")

        let symlinkTarget = directory.appending(path: "symlink-target")
        let symlinkReceipt = directory.appending(path: "symlink-receipt")
        try Data("{}".utf8).write(to: symlinkTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: symlinkTarget.path)
        try FileManager.default.createSymbolicLink(at: symlinkReceipt, withDestinationURL: symlinkTarget)
        try expectThrows("receipt symlink is rejected") {
            _ = try ReceiptStore(fileURL: symlinkReceipt).load()
        }
    }

    private static func testActivityRates() throws {
        var calculator = ActivityRateCalculator(maximumComparableInterval: 10)
        let date = Date()
        let first = calculator.record(TimedActivityCounters(
            monotonicTime: 100,
            wallTime: date,
            counters: CumulativeActivityCounters(
                userCPUTicks: 100, systemCPUTicks: 50, idleCPUTicks: 150,
                diskReadBytes: nil, diskWriteBytes: nil, networkReceiveBytes: 1_000, networkSendBytes: 500
            )
        ))
        try expect(first.cpuFraction.availability == .unavailable && first.didResetBaseline, "first activity sample establishes baseline")
        let second = calculator.record(TimedActivityCounters(
            monotonicTime: 102,
            wallTime: date.addingTimeInterval(2),
            counters: CumulativeActivityCounters(
                userCPUTicks: 120, systemCPUTicks: 60, idleCPUTicks: 180,
                diskReadBytes: nil, diskWriteBytes: nil, networkReceiveBytes: 1_400, networkSendBytes: 700
            )
        ))
        try expect(abs((second.cpuFraction.value ?? -1) - 0.5) < 0.0001, "CPU rate uses comparable tick deltas")
        try expect(second.networkReceiveBytesPerSecond.value == 200 && second.diskReadBytesPerSecond.availability == .unavailable, "metric availability remains independent")
        let reset = calculator.record(TimedActivityCounters(
            monotonicTime: 103,
            wallTime: date.addingTimeInterval(3),
            counters: CumulativeActivityCounters(
                userCPUTicks: 1, systemCPUTicks: 1, idleCPUTicks: 1,
                diskReadBytes: nil, diskWriteBytes: nil, networkReceiveBytes: 1, networkSendBytes: 1
            )
        ))
        try expect(reset.didResetBaseline && reset.cpuFraction.value == nil, "counter regression resets baseline without spike")
    }

    private static func testHistoryStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentNestHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "history.sqlite")
        let store = HistoryStore(fileURL: databaseURL)
        try expect(!FileManager.default.fileExists(atPath: databaseURL.path), "history disabled creates no database")
        try await store.setEnabled(true)
        let mode = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        try expect(mode?.intValue == 0o600, "history database is owner-only")
        let now = Date()
        try await store.append(ActivitySnapshot(
            capturedAt: now,
            cpuFraction: MetricValue(value: 0.25, availability: .available, observedSeconds: 3, coverage: 1),
            diskReadBytesPerSecond: MetricValue(value: nil, availability: .unavailable, observedSeconds: 3, coverage: 0),
            diskWriteBytesPerSecond: MetricValue(value: nil, availability: .unavailable, observedSeconds: 3, coverage: 0),
            networkReceiveBytesPerSecond: MetricValue(value: 100, availability: .available, observedSeconds: 3, coverage: 1),
            networkSendBytesPerSecond: MetricValue(value: 50, availability: .available, observedSeconds: 3, coverage: 1),
            didResetBaseline: false
        ))
        let points = try await store.points(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        try expect(points.count == 1 && points.first?.diskReadBytesPerSecond == nil, "history preserves unavailable as null")
        let csv = try await store.exportCSV(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        try expect(String(decoding: csv, as: UTF8.self).hasPrefix("schema_version,captured_at"), "history CSV uses stable machine schema")
        try await store.stopAndDelete()
        try expect(!FileManager.default.fileExists(atPath: databaseURL.path) && !FileManager.default.fileExists(atPath: databaseURL.path + "-wal"), "stop and delete removes database sidecars")
    }

    private static func testCleanupPolicy() async throws {
        let generation = UUID()
        let identity = PhysicalResourceIdentity(device: 1, inode: 10, kind: .directory)
        let homeIdentity = PhysicalResourceIdentity(device: 1, inode: 1, kind: .directory)
        let now = Date()
        func unit(
            name: String,
            ageDays: Double,
            activity: ActivityProtection,
            evidence: ActivityEvidenceKind = .officialMetadata,
            risk: ArtifactRisk = .rebuildable
        ) -> CleanupUnit {
            CleanupUnit(
                generation: generation, path: "/fixture/home/\(name)", homePath: "/fixture/home", identity: identity, homeIdentity: homeIdentity,
                name: name, category: "cache", storage: StorageMeasurement(logicalBytes: 2_000_000_000, physicalBytes: 2_000_000_000, itemCount: 1),
                risk: risk, activity: activity,
                lastActivity: LastActivityEvidence(date: now.addingTimeInterval(-ageDays * 86_400), kind: evidence), method: .trash
            )
        }
        let old = unit(name: "old", ageDays: 120, activity: .inactive)
        let writer = unit(name: "writer", ageDays: 120, activity: .writerPresent)
        let unreliable = unit(name: "atime", ageDays: 120, activity: .inactive, evidence: .accessTimeOnly)
        let recent = unit(name: "recent", ageDays: 10, activity: .inactive)
        let policy = CleanupPolicy()
        let filtered = policy.filter(
            units: [old, writer, unreliable, recent],
            query: CleanupQuery(inactiveBefore: now.addingTimeInterval(-90 * 86_400), minimumPhysicalBytes: 1_000_000_000)
        )
        try expect(Set(filtered.map(\.name)) == Set(["old", "writer"]), "date filtering uses reliable cleanup-unit evidence")
        let plan = policy.plan(generation: generation, selected: filtered)
        try expect(plan.units.map(\.name) == ["old"], "writer remains visible but cannot enter cleanup plan")
        try expect(plan.estimatedPhysicalBytes == old.storage.physicalBytes, "cleanup preview reports selected estimate")
        let staleResults = await CleanupExecutor().execute(plan, currentGeneration: UUID())
        try expect(staleResults.allSatisfy { $0.status == .skipped && $0.code == "cleanup.generationChanged" }, "stale generation cannot execute")

        let root = FileManager.default.temporaryDirectory.appending(path: "AgentNestCleanupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let boundaryUnit = CleanupUnit(
            generation: generation, path: outside.path, homePath: home.path,
            identity: try physicalIdentity(outside), homeIdentity: try physicalIdentity(home),
            name: "outside", category: "cache", storage: StorageMeasurement(), risk: .rebuildable,
            activity: .inactive,
            lastActivity: LastActivityEvidence(date: now.addingTimeInterval(-100 * 86_400), kind: .officialMetadata),
            method: .trash
        )
        let boundaryResult = await CleanupExecutor().execute(
            CleanupPlan(generation: generation, units: [boundaryUnit]),
            currentGeneration: generation
        )
        try expect(
            boundaryResult.first?.code == "cleanup.boundaryChanged" && FileManager.default.fileExists(atPath: outside.path),
            "cleanup cannot escape verified Home boundary"
        )
    }

    private static func testSkills() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AgentNestSkillTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let homes = [root.appending(path: ".codex"), root.appending(path: "deep/one"), root.appending(path: "deep/two")]
        for home in homes {
            try FileManager.default.createDirectory(at: home.appending(path: "skills"), withIntermediateDirectories: true)
            try Data("{\"version\":\"fixture\"}".utf8).write(to: home.appending(path: "version.json"))
        }
        let firstSkill = homes[0].appending(path: "skills/release")
        let secondSkill = homes[1].appending(path: "skills/release")
        try FileManager.default.createDirectory(at: firstSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSkill, withIntermediateDirectories: true)
        try Data("---\nname: release\ndescription: first\n---\n\n# Release A\n".utf8).write(to: firstSkill.appending(path: "SKILL.md"))
        try Data("---\nname: release\ndescription: second\n---\n\n# Release B\n".utf8).write(to: secondSkill.appending(path: "SKILL.md"))

        let snapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(root: root))
        try expect(snapshot.homes.filter { $0.confidence == .confirmed }.count == 3, "skill fixture homes")
        let definitionData = Data("""
        {"schemaVersion":1,"id":"openai.codex","displayName":"Codex",
        "homeDiscovery":{"defaultPaths":["~/.codex"],"environmentVariables":[],"allowDeepDiscovery":true},
        "fingerprints":{"required":[{"kind":"jsonFile","relativePath":"version.json"}],"optional":[],"negative":[]},
        "skills":[{"relativePath":"skills","format":"directory-skill-md"}],"artifacts":[],
        "capabilities":{"space":true,"skills":true,"activity":false,"cleanup":false}}
        """.utf8)
        let skillCatalog = try AgentDefinitionCatalog(definitions: [AgentDefinitionCatalog.load(data: definitionData)])
        let indexer = SkillIndexUseCase(catalog: skillCatalog)
        let firstIndex = await indexer.execute(homes: snapshot.homes)
        let release = try unwrap(firstIndex.logicalSkills.first { $0.id == "release" }, "release logical skill")
        try expect(release.variants.count == 2, "same-name content becomes separate variants")
        try expect(release.missingHomeIDs.count == 1, "coverage reports missing home")

        let writer = SkillWriteUseCase()
        let generation = snapshot.generation
        let thirdSkillRoot = homes[2].appending(path: "skills")
        let patchPlan = try await writer.planPatch(
            generation: generation,
            skillRoot: thirdSkillRoot,
            destinationName: "release",
            sourceSkill: firstSkill
        )
        try await writer.execute(patchPlan, currentGeneration: generation)
        let secondIndex = await indexer.execute(homes: snapshot.homes)
        let patchedRelease = try unwrap(secondIndex.logicalSkills.first { $0.id == "release" }, "patched release skill")
        try expect(patchedRelease.missingHomeIDs.isEmpty && patchedRelease.variants.count == 2, "patch updates coverage without merging variants")

        let racePlan = try await writer.planCreate(generation: generation, skillRoot: thirdSkillRoot, name: "race", description: "fixture")
        try FileManager.default.createDirectory(at: thirdSkillRoot.appending(path: "race"), withIntermediateDirectories: false)
        try await expectThrows("write target changed after preview") {
            try await writer.execute(racePlan, currentGeneration: generation)
        }

        try FileManager.default.createSymbolicLink(
            at: firstSkill.appending(path: "outside-link"),
            withDestinationURL: root.appending(path: "outside")
        )
        try await expectThrows("patch rejects symlink") {
            _ = try await writer.planPatch(
                generation: generation,
                skillRoot: thirdSkillRoot,
                destinationName: "unsafe",
                sourceSkill: firstSkill
            )
        }
    }

    private static func makePayload(machineHash: String, issuedAt: Date, offlineUntil: Date) -> EntitlementPayload {
        EntitlementPayload(
            schemaVersion: 1, provider: "agentnest-local", licenseId: "lic_fixture", machineIdHash: machineHash,
            productId: "com.agentnest.macos", plan: "developer", features: LicenseFeature.allCases.map(\.rawValue),
            issuedAt: issuedAt, refreshAfter: issuedAt.addingTimeInterval(3600), offlineUntil: offlineUntil,
            subscriptionExpiresAt: nil, minAppVersion: nil, receiptId: "receipt-fixture"
        )
    }

    private static func sign(_ payload: EntitlementPayload, with key: Curve25519.Signing.PrivateKey) throws -> SignedEntitlementReceipt {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return SignedEntitlementReceipt(payload: base64URL(data), signature: base64URL(try key.signature(for: data)))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(message) }
    }

    private static func expectThrows(_ message: String, operation: () throws -> Void) throws {
        do { try operation(); throw TestFailure("expected failure: \(message)") } catch is TestFailure { throw TestFailure("expected failure: \(message)") } catch {}
    }

    private static func expectThrows(_ message: String, operation: () async throws -> Void) async throws {
        do { try await operation(); throw TestFailure("expected failure: \(message)") } catch is TestFailure { throw TestFailure("expected failure: \(message)") } catch {}
    }

    private static func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw TestFailure("missing \(message)") }
        return value
    }

    private static func physicalIdentity(_ url: URL) throws -> PhysicalResourceIdentity {
        var value = Darwin.stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(.EIO) }
        let fileType = value.st_mode & S_IFMT
        let kind: ResourceKind = fileType == S_IFDIR ? .directory : (fileType == S_IFREG ? .file : .other)
        return PhysicalResourceIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), kind: kind)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(account: String) throws -> String? { lock.withLock { values[account] } }
    func save(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    func delete(account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}
