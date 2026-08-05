import AgentNestCore
import CryptoKit
import CoreGraphics
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
            try await testCleanupInventory()
            try await testActivityRates()
            try testDiskUtilityParsing()
            try await testHistoryStore()
            try testHistoryPDF()
            try await testReceipts()
            try testLicenseRefreshSchedule()
            print("AgentNestCore tests passed (82 checks)")
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
        "homeDiscovery":{"defaultPaths":[],"environmentVariables":[]},
        "fingerprints":{"required":[],"optional":[],"negative":[]},"skills":[],"artifacts":[],
        "capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8)
        try expectThrows("unknown definition field") { _ = try AgentDefinitionCatalog.load(data: unknown) }

        let unsafe = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test",
        "homeDiscovery":{"defaultPaths":["~/.test"],"environmentVariables":[]},
        "fingerprints":{"required":[{"kind":"file","relativePath":"../outside"}],"optional":[],"negative":[]},
        "skills":[],"artifacts":[],"capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8)
        try expectThrows("unsafe definition path") { _ = try AgentDefinitionCatalog.load(data: unsafe) }
        try expect(
            CanonicalPath.isEqualOrDescendant("/tmp/fixture", of: "/") &&
                CanonicalPath.isDescendant("/foo/child", of: "/foo") &&
                !CanonicalPath.isEqualOrDescendant("/foobar", of: "/foo"),
            "canonical path containment handles filesystem root and component boundaries"
        )
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
            homeDirectory: root,
            customLocations: [alias],
            environment: ["CODEX_HOME": deepHome.path]
        ))
        let confirmed = snapshot.homes.filter { $0.confidence == .confirmed }
        let possible = snapshot.homes.filter { $0.confidence == .possible }
        try expect(confirmed.count == 2 && Set(confirmed.map(\.id)).count == 2, "multi-home discovery and physical alias deduplication")
        try expect(possible.isEmpty, "undeclared nested directories are not searched")
        try expect(
            !snapshot.storageLedger.artifacts.contains(where: { $0.path == possibleHome.path || $0.path.hasPrefix(possibleHome.path + "/") }),
            "undeclared directories never enter physical accounting"
        )
        let userConfirmedSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(
            homeDirectory: root,
            userConfirmedHomes: [possibleHome.path: "openai.codex"]
        ))
        try expect(
            userConfirmedSnapshot.homes.first(where: { $0.path == possibleHome.path })?.confidence == .confirmed &&
                userConfirmedSnapshot.homes.first(where: { $0.path == possibleHome.path })?.source == .userConfirmed,
            "an explicit local candidate decision confirms only the selected product and records its source"
        )
        try expect(snapshot.products.count == 1 && snapshot.products.first?.id == "openai.codex", "homes are grouped beneath their product")
        try expect(snapshot.products.first?.installations.isEmpty == true && snapshot.products.first?.profiles.isEmpty == true, "installation and profile are not fabricated without evidence")
        let defaultResult = try unwrap(confirmed.first { $0.path == defaultHome.path }, "default home")
        try expect(defaultResult.storage.itemCount == 3, "hard links count once in physical ledger; got \(defaultResult.storage.itemCount)")
        try expect(Set(snapshot.storageLedger.artifacts.map(\.id)).count == snapshot.storageLedger.artifacts.count, "storage ledger contains each physical resource once")
        try expect(
            snapshot.totalStorage.physicalBytes == snapshot.storageLedger.artifacts.reduce(0) { $0 &+ $1.storage.physicalBytes },
            "snapshot total conserves artifact physical bytes"
        )
        try expect(snapshot.storageLedger.artifacts.allSatisfy { $0.category == .unattributed }, "undefined artifact rules do not guess categories")

        let incrementalFile = defaultHome.appending(path: "incremental.fixture")
        try Data("incremental".utf8).write(to: incrementalFile)
        let homeReplacement = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(
            homeDirectory: defaultHome,
            customLocations: [defaultHome]
        ))
        let reconciled = try SnapshotReconciler().replacingHome(at: defaultHome.path, in: snapshot, with: homeReplacement)
        try expect(
            reconciled.homes.contains(where: { $0.path == deepHome.path }) &&
                reconciled.storageLedger.artifacts.contains(where: { $0.path == incrementalFile.path }) &&
                reconciled.totalStorage.physicalBytes == reconciled.storageLedger.artifacts.reduce(0) { $0 &+ $1.storage.physicalBytes },
            "single-Home reconciliation preserves unaffected Homes and rebuilds a conservative physical ledger"
        )

        let ignoredSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(
            homeDirectory: root,
            ignoredLocations: [deepHome],
            environment: ["CODEX_HOME": deepHome.path]
        ))
        try expect(
            !ignoredSnapshot.homes.contains(where: { $0.path == deepHome.path }) &&
                !ignoredSnapshot.storageLedger.artifacts.contains(where: { $0.path == deepHome.path || $0.path.hasPrefix(deepHome.path + "/") }),
            "ignored locations are excluded before discovery and physical accounting"
        )

        let unstableRoot = root.appending(path: "unstable-fixture")
        let unstableHome = unstableRoot.appending(path: ".codex")
        let unstableFingerprint = unstableHome.appending(path: "version.json")
        try FileManager.default.createDirectory(at: unstableHome, withIntermediateDirectories: true)
        try Data("{\"version\":\"before\"}".utf8).write(to: unstableFingerprint)
        let unstableSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(
            request: ScanRequest(homeDirectory: unstableRoot),
            progress: { progress in
                if progress.phase == .measuringSpace {
                    try? Data("{\"version\":\"changed-during-scan\"}".utf8).write(to: unstableFingerprint)
                }
            }
        )
        try expect(
            unstableSnapshot.isPartial && unstableSnapshot.homes.first?.confidence == .possible,
            "a required fingerprint changed during scanning downgrades the exact Home conclusion"
        )
        try expect(
            !unstableSnapshot.storageLedger.artifacts.contains(where: { $0.path == unstableFingerprint.path }) &&
                unstableSnapshot.findings.contains(where: { $0.code == "finding.scan.unstable" }),
            "unstable resources are suppressed from exact physical accounting and reported"
        )

        let snapshotStore = SnapshotStore(fileURL: root.appending(path: "app-data/latest-snapshot.json"))
        try snapshotStore.save(snapshot)
        try expect(try snapshotStore.load() == snapshot, "latest immutable snapshot survives an atomic persistence round trip")
        let snapshotMode = try FileManager.default.attributesOfItem(atPath: snapshotStore.fileURL.path)[.posixPermissions] as? NSNumber
        try expect(snapshotMode?.intValue == 0o600, "persisted snapshot is owner-only")

        try Data("not-json".utf8).write(to: defaultHome.appending(path: "version.json"))
        let malformedSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(homeDirectory: root))
        try expect(malformedSnapshot.homes.first { $0.path == defaultHome.path }?.confidence == .possible, "malformed JSON fails closed")

        let cancelledTask = Task {
            try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(homeDirectory: root))
        }
        cancelledTask.cancel()
        try await expectThrows("cancelled scan does not publish a partial generation") {
            _ = try await cancelledTask.value
        }

        let cancellationProbe = ScanCancellationProbe()
        let coordinator = ScanCoordinator(useCase: ScanUseCase(catalog: try AgentDefinitionCatalog.bundled()))
        let coordinatedTask = Task {
            try await coordinator.scan(request: ScanRequest(homeDirectory: root)) { progress in
                if progress.phase == .discoveringAgents {
                    await cancellationProbe.waitForCancellation()
                }
            }
        }
        await cancellationProbe.waitUntilStarted()
        await coordinator.cancel()
        try await expectThrows("coordinator cancellation terminates the active scan") {
            _ = try await coordinatedTask.value
        }
        let stoppedSnapshot = await coordinator.snapshot()
        try expect(stoppedSnapshot == nil, "a stopped generation is never published")

        let missingRoot = root.appending(path: "missing-scan-root")
        let unavailable = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(homeDirectory: missingRoot))
        try expect(
            !unavailable.isPartial && unavailable.homes.isEmpty,
            "a missing default candidate is treated as an absent Agent Home"
        )

        let permissionRoot = root.appending(path: "permission-fixture")
        let permissionHome = permissionRoot.appending(path: ".codex")
        let blockedDirectory = permissionHome.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        try Data("{\"version\":\"fixture\"}".utf8).write(to: permissionHome.appending(path: "version.json"))
        try Data("private".utf8).write(to: blockedDirectory.appending(path: "secret"))
        guard chmod(blockedDirectory.path, 0) == 0 else { throw POSIXError(.EACCES) }
        defer { _ = chmod(blockedDirectory.path, S_IRWXU) }
        let permissionSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(homeDirectory: permissionRoot))
        try expect(
            permissionSnapshot.isPartial && permissionSnapshot.coverage.unreadableLocationCount >= 1,
            "an unreadable subtree preserves the scan while making affected coverage partial"
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
        let older = makePayload(machineHash: machineHash, issuedAt: now.addingTimeInterval(-120), offlineUntil: now.addingTimeInterval(7200))
        try expectThrows("replayed older receipt") {
            _ = try verifier.verify(try sign(older, with: privateKey), machineIDHash: machineHash, now: now, replacing: payload)
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

    private static func testLicenseRefreshSchedule() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var schedule = LicenseRefreshSchedule()
        schedule.recordFailure(now: now, jitterUnit: 0)
        try expect(schedule.failureCount == 1 && schedule.nextAttemptAt == now.addingTimeInterval(45), "license retry starts with bounded negative jitter")
        schedule.recordFailure(now: now, jitterUnit: 1)
        try expect(schedule.failureCount == 2 && schedule.nextAttemptAt == now.addingTimeInterval(150), "license retry uses jittered exponential backoff")
        schedule.networkBecameAvailable(now: now.addingTimeInterval(10))
        try expect(schedule.shouldAttempt(now: now.addingTimeInterval(10)), "network restoration releases a failed refresh immediately")
        let refreshAfter = now.addingTimeInterval(86_400)
        schedule.recordSuccess(refreshAfter: refreshAfter)
        try expect(schedule.failureCount == 0 && schedule.nextAttemptAt == refreshAfter, "successful refresh returns to receipt schedule")
    }

    private static func testActivityRates() async throws {
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

        let reusedPID = Int32(42)
        let sampler = SystemActivitySampler(
            provider: SequencedCounterProvider(),
            evidenceProvider: SequencedEvidenceProvider(pid: reusedPID)
        )
        _ = try await sampler.sample()
        let evidenceSnapshot = try await sampler.sample()
        try expect(
            evidenceSnapshot.processes.first?.id.startSeconds == 2 && evidenceSnapshot.processes.first?.cpuFraction.value == nil,
            "PID reuse creates a new process baseline instead of joining sessions"
        )
        try expect(evidenceSnapshot.physicalDevices.first?.readBytesPerSecond.value != nil, "physical device rates use stable registry identity")

        let openFile = FileManager.default.temporaryDirectory.appending(path: "AgentNestOpenFile-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: openFile)
        defer { try? FileManager.default.removeItem(at: openFile) }
        let handle = try FileHandle(forReadingFrom: openFile)
        defer { try? handle.close() }
        let fileEvidence = DarwinProcessFileEvidenceProvider().currentlyOpenFiles(pid: getpid(), maximumCount: 128)
        try expect(fileEvidence.paths.contains { URL(fileURLWithPath: $0).lastPathComponent == openFile.lastPathComponent }, "currently-open evidence comes from bounded vnode descriptors")
        let bounded = DarwinProcessFileEvidenceProvider().currentlyOpenFiles(pid: getpid(), maximumCount: 0)
        try expect(bounded.paths.isEmpty && bounded.droppedCount > 0, "open-file evidence reports budget drops instead of growing unbounded")

        let ownProcess = DarwinSystemActivityEvidenceProvider().readEvidence().processes.first { $0.identity.pid == getpid() }
        try expect(ownProcess?.workingDirectoryPath != nil, "process evidence captures the current working directory when libproc permits it")

        let attributionRoot = FileManager.default.temporaryDirectory.appending(path: "AgentNestActivity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: attributionRoot) }
        let attributionHome = attributionRoot.appending(path: ".codex")
        try FileManager.default.createDirectory(at: attributionHome, withIntermediateDirectories: true)
        try Data("{\"version\":\"fixture\"}".utf8).write(to: attributionHome.appending(path: "version.json"))
        let inventory = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(homeDirectory: attributionRoot))
        let attributedSampler = SystemActivitySampler(
            provider: SequencedCounterProvider(),
            evidenceProvider: WorkingDirectoryEvidenceProvider(path: attributionHome.appending(path: "workspace").path)
        )
        let attributed = try await attributedSampler.sample(inventory: inventory)
        try expect(
            attributed.processes.first?.attribution == .agent &&
                attributed.processes.first?.evidence.first?.hasPrefix("working-directory:") == true,
            "working-directory evidence attributes a process to the containing Home without using its name"
        )

        let stormSampler = SystemActivitySampler(
            provider: SequencedCounterProvider(),
            evidenceProvider: StormEvidenceProvider(count: 5_000)
        )
        let storm = try await stormSampler.sample()
        try expect(
            storm.processes.count == 4_096 && storm.droppedEvidenceCount == 904,
            "process evidence storms are capped and excess observations become explicit drops"
        )
    }

    private static func testDiskUtilityParsing() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "SMARTStatus": "Verified",
            "ParentWholeDisk": "disk12",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
        ], format: .binary, options: 0)
        let info = try unwrap(DiskUtilityProbe.parseInfo(data: data), "diskutil plist")
        try expect(info.health == .verified, "diskutil SMART status is parsed structurally")
        try expect(info.wholeDiskNames == ["disk0", "disk12"], "APFS stores map to whole-disk names without guessing paths")
        let unsupportedData = try PropertyListSerialization.data(fromPropertyList: ["DeviceIdentifier": "disk9s1"], format: .xml, options: 0)
        try expect(DiskUtilityProbe.parseInfo(data: unsupportedData)?.health == .unsupported, "missing SMART field remains unsupported")
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

        let rollupClock = TestClock(now: Date(timeIntervalSince1970: 2_000_000))
        let rollupStore = HistoryStore(
            fileURL: directory.appending(path: "rollup.sqlite"),
            clock: { rollupClock.value() }
        )
        try await rollupStore.setEnabled(true)
        for (offset, cpu) in [0.1, 0.2, 0.3, 0.4].enumerated() {
            try await rollupStore.append(activityFixture(
                at: rollupClock.value().addingTimeInterval(TimeInterval(offset * 60)),
                cpu: cpu
            ))
        }
        let future = rollupClock.value().addingTimeInterval(2 * 86_400)
        rollupClock.set(future)
        try await rollupStore.append(activityFixture(at: future, cpu: 0.5))
        let rolled = try await rollupStore.points(
            from: Date(timeIntervalSince1970: 1_999_000),
            to: future.addingTimeInterval(1)
        )
        try expect(rolled.count == 2, "history older than 24 hours is compacted into a 15-minute rollup; got \(rolled)")
        try expect(abs((rolled.first?.cpuFraction ?? -1) - 0.25) < 0.0001, "history rollup averages available values without filling gaps with zero")

        let retentionClock = TestClock(now: Date(timeIntervalSince1970: 4_000_000))
        let retentionStore = HistoryStore(
            fileURL: directory.appending(path: "retention.sqlite"),
            retentionDays: 365,
            clock: { retentionClock.value() }
        )
        try await retentionStore.setEnabled(true)
        let retainedDate = retentionClock.value().addingTimeInterval(-20 * 86_400)
        try await retentionStore.append(activityFixture(at: retainedDate, cpu: 0.2))
        _ = try await retentionStore.setRetentionDays(7)
        let pruned = try await retentionStore.points(from: retainedDate.addingTimeInterval(-1), to: retentionClock.value())
        try expect(pruned.isEmpty, "shortening history retention immediately prunes older rollups")
    }

    private static func testHistoryPDF() throws {
        let points = (0..<40).map { index in
            HistoryPoint(
                capturedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index * 60)),
                cpuFraction: index.isMultiple(of: 3) ? nil : Double(index) / 100,
                diskReadBytesPerSecond: 1_000,
                diskWriteBytesPerSecond: nil,
                networkReceiveBytesPerSecond: 2_000,
                networkSendBytesPerSecond: 500,
                coverage: 0.8
            )
        }
        let data = try HistoryPDFRenderer().render(points: points, generatedAt: Date(timeIntervalSince1970: 4_000), locale: Locale(identifier: "en_US"))
        try expect(data.starts(with: Data("%PDF".utf8)), "history report is a local PDF artifact")
        let provider = try unwrap(CGDataProvider(data: data as CFData), "PDF data provider")
        let document = try unwrap(CGPDFDocument(provider), "PDF document")
        try expect(document.numberOfPages == 2, "history PDF paginates deterministic row budgets")
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

    private static func testCleanupInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AgentNestCleanupInventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: ".codex")
        let cache = home.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{\"version\":\"fixture\"}".utf8).write(to: home.appending(path: "version.json"))
        try Data(repeating: 1, count: 4_096).write(to: cache.appending(path: "item.bin"))
        let definition = try AgentDefinitionCatalog.load(data: Data("""
        {"schemaVersion":1,"id":"openai.codex","displayName":"Codex",
        "homeDiscovery":{"defaultPaths":["~/.codex"],"environmentVariables":[]},
        "fingerprints":{"required":[{"kind":"jsonFile","relativePath":"version.json"}],"optional":[],"negative":[]},
        "skills":[],"artifacts":[{"relativePath":"cache","category":"cache","cleanup":{"risk":"rebuildable","method":"trash"}}],
        "capabilities":{"space":true,"skills":false,"activity":false,"cleanup":true}}
        """.utf8))
        let catalog = try AgentDefinitionCatalog(definitions: [definition])
        let snapshot = try await ScanUseCase(catalog: catalog).execute(request: ScanRequest(homeDirectory: root))
        let useCase = CleanupInventoryUseCase(catalog: catalog)
        let unknown = useCase.execute(snapshot: snapshot, activity: nil)
        try expect(unknown.count == 1 && unknown.first?.risk == .rebuildable && unknown.first?.path == cache.path, "cleanup inventory only emits explicitly declared complete artifact roots")
        try expect(unknown.first?.activity == .unknown && CleanupPolicy().plan(generation: snapshot.generation, selected: unknown).units.isEmpty, "missing activity evidence blocks cleanup execution")
        let inactive = useCase.execute(snapshot: snapshot, activity: activityFixture(at: Date(), cpu: 0.1))
        try expect(inactive.first?.activity == .inactive && CleanupPolicy().plan(generation: snapshot.generation, selected: inactive).units.count == 1, "verified inactive targets can enter a cleanup preview")
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
        try Data("fixture asset".utf8).write(to: firstSkill.appending(path: "asset.txt"))
        try Data("---\nname: release\ndescription: second\n---\n\n# Release B\n".utf8).write(to: secondSkill.appending(path: "SKILL.md"))

        let snapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(request: ScanRequest(
            homeDirectory: root,
            customLocations: Array(homes.dropFirst())
        ))
        try expect(snapshot.homes.filter { $0.confidence == .confirmed }.count == 3, "skill fixture homes")
        let definitionData = Data("""
        {"schemaVersion":1,"id":"openai.codex","displayName":"Codex",
        "homeDiscovery":{"defaultPaths":["~/.codex"],"environmentVariables":[]},
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

        let thirdRelease = thirdSkillRoot.appending(path: "release")
        let editPlan = try await writer.planEdit(
            generation: generation,
            skillRoot: thirdSkillRoot,
            skillName: "release",
            expectedIdentity: physicalIdentity(thirdRelease),
            mainDocument: "---\nname: release\ndescription: edited\n---\n\n# Edited\n"
        )
        try await writer.execute(editPlan, currentGeneration: generation)
        try expect(
            String(decoding: try Data(contentsOf: thirdRelease.appending(path: "SKILL.md")), as: UTF8.self).contains("# Edited") &&
                FileManager.default.fileExists(atPath: thirdRelease.appending(path: "asset.txt").path),
            "edit atomically replaces the main document and preserves package files"
        )

        let identityBeforeRename = try physicalIdentity(thirdRelease)
        let renamePlan = try await writer.planRename(
            generation: generation,
            skillRoot: thirdSkillRoot,
            sourceName: "release",
            expectedIdentity: identityBeforeRename,
            destinationName: "release-renamed"
        )
        try await writer.execute(renamePlan, currentGeneration: generation)
        let renamed = thirdSkillRoot.appending(path: "release-renamed")
        try expect(
            !FileManager.default.fileExists(atPath: thirdRelease.path) && physicalIdentity(renamed) == identityBeforeRename,
            "rename is exclusive and preserves physical identity"
        )

        let keepBothPlan = try await writer.planPatch(
            generation: generation,
            skillRoot: thirdSkillRoot,
            destinationName: "release-renamed",
            sourceSkill: firstSkill,
            conflictResolution: .keepBoth
        )
        try await writer.execute(keepBothPlan, currentGeneration: generation)
        try expect(FileManager.default.fileExists(atPath: thirdSkillRoot.appending(path: "release-renamed-2").path), "keep-both conflict resolution chooses a distinct target")

        let batchPlans = try await ["batch-a", "batch-b"].asyncMap { name in
            try await writer.planCreate(generation: generation, skillRoot: thirdSkillRoot, name: name, description: "fixture")
        }
        let cancelledBatch = await writer.executeSerial(batchPlans, currentGeneration: generation, shouldCancel: { true })
        try expect(cancelledBatch.allSatisfy { $0.status == .skipped && $0.code == "skill.cancelled" }, "serial batch reports cancellation per target")
        try expect(batchPlans.allSatisfy { !FileManager.default.fileExists(atPath: $0.destination) }, "cancelled serial batch performs no writes")

        let deletePlan = try await writer.planDelete(
            generation: generation,
            skillRoot: thirdSkillRoot,
            skillName: "release-renamed-2",
            expectedIdentity: physicalIdentity(thirdSkillRoot.appending(path: "release-renamed-2"))
        )
        try expect(deletePlan.operation == .delete && deletePlan.files.isEmpty, "delete requires a preview bound to the installation identity")

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

        let recoveryNow = Date()
        let staleStaging = thirdSkillRoot.appending(path: ".agentnest-staging-\(UUID().uuidString)")
        let freshStaging = thirdSkillRoot.appending(path: ".agentnest-staging-\(UUID().uuidString)")
        let lookalikeStaging = thirdSkillRoot.appending(path: ".agentnest-staging-not-a-uuid")
        let symlinkStaging = thirdSkillRoot.appending(path: ".agentnest-staging-\(UUID().uuidString)")
        for directory in [staleStaging, freshStaging, lookalikeStaging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try FileManager.default.createSymbolicLink(at: symlinkStaging, withDestinationURL: firstSkill)
        try FileManager.default.setAttributes([.modificationDate: recoveryNow.addingTimeInterval(-7_200)], ofItemAtPath: staleStaging.path)
        let recovered = try await writer.recoverAbandonedStaging(in: thirdSkillRoot, now: recoveryNow)
        defer {
            for result in recovered {
                if let path = result.trashedPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        try expect(
            recovered.count == 1 &&
                recovered.first.map { URL(fileURLWithPath: $0.originalPath).lastPathComponent } == staleStaging.lastPathComponent &&
                recovered.first?.status == .succeeded,
            "crash recovery only trashes an exact, stale AgentNest staging directory"
        )
        try expect(
            !FileManager.default.fileExists(atPath: staleStaging.path) &&
                FileManager.default.fileExists(atPath: freshStaging.path) &&
                FileManager.default.fileExists(atPath: lookalikeStaging.path) &&
                FileManager.default.fileExists(atPath: symlinkStaging.path),
            "crash recovery leaves fresh, lookalike, and symlink entries untouched"
        )
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

    private static func activityFixture(at date: Date, cpu: Double?) -> ActivitySnapshot {
        let available = MetricValue(value: cpu, availability: cpu == nil ? .unavailable : .available, observedSeconds: 60, coverage: cpu == nil ? 0 : 1)
        let unavailable = MetricValue(value: nil, availability: .unavailable, observedSeconds: 60, coverage: 0)
        return ActivitySnapshot(
            capturedAt: date,
            cpuFraction: available,
            diskReadBytesPerSecond: unavailable,
            diskWriteBytesPerSecond: unavailable,
            networkReceiveBytesPerSecond: unavailable,
            networkSendBytesPerSecond: unavailable,
            didResetBaseline: false
        )
    }
}

private extension Array {
    func asyncMap<Output>(_ transform: (Element) async throws -> Output) async rethrows -> [Output] {
        var output: [Output] = []
        output.reserveCapacity(count)
        for element in self { output.append(try await transform(element)) }
        return output
    }
}

private final class SequencedCounterProvider: ActivityCounterProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func readCounters() throws -> CumulativeActivityCounters {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        let value = UInt64(index * 100)
        return CumulativeActivityCounters(
            userCPUTicks: value,
            systemCPUTicks: value,
            idleCPUTicks: value,
            diskReadBytes: value,
            diskWriteBytes: value,
            networkReceiveBytes: value,
            networkSendBytes: value
        )
    }
}

private actor ScanCancellationProbe {
    private var started = false

    func waitForCancellation() async {
        started = true
        while !Task.isCancelled { await Task.yield() }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private final class SequencedEvidenceProvider: SystemActivityEvidenceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let pid: Int32

    init(pid: Int32) { self.pid = pid }

    func readEvidence() -> SystemActivityEvidence {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        let value = UInt64(index * 1_000)
        return SystemActivityEvidence(
            processes: [CumulativeProcessObservation(
                identity: ProcessStartIdentity(pid: pid, startSeconds: UInt64(index), startMicroseconds: 0),
                name: "fixture",
                executablePath: "/fixture/process",
                workingDirectoryPath: nil,
                cpuNanoseconds: value,
                requestedReadBytes: value,
                requestedWriteBytes: value
            )],
            devices: [CumulativeDeviceObservation(id: 7, name: "fixture-device", readBytes: value, writeBytes: value)],
            volumes: [],
            droppedCount: 0
        )
    }
}

private struct WorkingDirectoryEvidenceProvider: SystemActivityEvidenceProvider, Sendable {
    let path: String

    func readEvidence() -> SystemActivityEvidence {
        SystemActivityEvidence(
            processes: [CumulativeProcessObservation(
                identity: ProcessStartIdentity(pid: 24, startSeconds: 1, startMicroseconds: 0),
                name: "unrelated-name",
                executablePath: "/usr/bin/false",
                workingDirectoryPath: path,
                cpuNanoseconds: 1,
                requestedReadBytes: 1,
                requestedWriteBytes: 1
            )],
            devices: [],
            volumes: [],
            droppedCount: 0
        )
    }
}

private struct StormEvidenceProvider: SystemActivityEvidenceProvider, Sendable {
    let count: Int

    func readEvidence() -> SystemActivityEvidence {
        SystemActivityEvidence(
            processes: (0..<count).map { index in
                CumulativeProcessObservation(
                    identity: ProcessStartIdentity(pid: Int32(index + 1), startSeconds: 1, startMicroseconds: 0),
                    name: "storm",
                    executablePath: nil,
                    cpuNanoseconds: 0,
                    requestedReadBytes: 0,
                    requestedWriteBytes: 0
                )
            },
            devices: [],
            volumes: [],
            droppedCount: 0
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(now: Date) { self.now = now }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func set(_ value: Date) {
        lock.lock()
        now = value
        lock.unlock()
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
