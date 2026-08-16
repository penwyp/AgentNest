@testable import AgentNestCore
import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import SQLite3

@main
struct AgentNestCoreTestRunner {
    static func main() async {
        do {
            try testDefinitionCatalog()
            try testMarketVersionRefreshPolicy()
            try testHomebrewVersionParsing()
            try testExecutableVersionProbeParsing()
            try await testScan()
            try await testInstalledVersionExtraction()
            try testInstalledAppBundleVersionProbe()
            try await testMarketplaceVersionService()
            try await testSkills()
            try await testCleanupPolicy()
            try testStorageOwnershipScope()
            try await testCleanupInventory()
            try testCleanupActivitySignature()
            try await testCodexCleanupFamilies()
            try await testActivityRates()
            try testActivityWorkspace()
            try testDiskUtilityParsing()
            try await testHistoryStore()
            try testHistoryPDF()
            try await testReceipts()
            try testLicenseRefreshSchedule()
            print("AgentNestCore tests passed")
        } catch {
            FileHandle.standardError.write(Data("AgentNestCore tests failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func testDefinitionCatalog() throws {
        let catalog = try AgentDefinitionCatalog.bundled()
        // 5 个完整定义 + 9 个市场条目（CLI/Desktop 变体与扩展目录）。
        try expect(catalog.definitions.count == 14, "bundled definition count")
        let codex = try unwrap(catalog.definitions.first { $0.id == "openai.codex" }, "Codex definition")
        try expect(
            codex.capabilities.cleanup &&
                codex.artifacts.filter { $0.cleanup != nil }.count == 5 &&
                codex.artifacts.filter { $0.cleanup?.unitBoundary == .adapter }.count == 2,
            "Codex declares reviewed path roots and official session cleanup adapters"
        )
        try expect(
            Set(catalog.definitions.filter(\.participatesInScanning).map(\.id)) ==
                [
                    "anthropic.claude-code", "anthropic.claude-desktop",
                    "bytedance.trae", "cursor.cursor",
                    "google.gemini-cli", "opencode.opencode", "openai.codex",
                ],
            "all supported agents participate in scanning"
        )
        try expect(catalog.definitions.filter { !$0.participatesInScanning }.allSatisfy {
            !$0.capabilities.space && !$0.capabilities.skills && !$0.capabilities.activity && !$0.capabilities.cleanup
        }, "empty definitions expose no capabilities")

        func install(for id: String) -> AgentInstallMethod? {
            catalog.definitions.first { $0.id == id }?.marketplace?.install
        }
        try expect(
            install(for: "openai.codex") == AgentInstallMethod(kind: .cask, formula: "codex") &&
                install(for: "anthropic.claude-code") == AgentInstallMethod(
                    kind: .cask,
                    formula: "claude-code",
                    scriptURL: "https://claude.ai/install.sh",
                    requiresNode: true
                ) &&
                install(for: "cursor.cursor-cli") == AgentInstallMethod(kind: .cask, formula: "cursor-cli") &&
                install(for: "aider.aider") == AgentInstallMethod(
                    kind: .brew,
                    formula: "aider",
                    scriptURL: "https://aider.chat/install.sh"
                ) &&
                install(for: "inflection.pi") == AgentInstallMethod(
                    kind: .npm,
                    formula: "@earendil-works/pi-coding-agent",
                    requiresNode: true
                ),
            "market install methods match the real Homebrew formula/cask tokens"
        )
        try expect(
            catalog.definitions.first { $0.id == "inflection.pi" }?.marketplace?.homepageURL == "https://pi.dev",
            "Pi marketplace homepage points to pi.dev"
        )
        try expect(
            catalog.definitions.first { $0.id == "workbuddy" }?.marketplace?.homepageURL == "https://www.workbuddy.ai/" &&
                install(for: "workbuddy") == AgentInstallMethod(
                    kind: .website,
                    formula: "WorkBuddy",
                    websiteUpdateURL: "https://www.workbuddy.ai/v2/update?platform={platform}",
                    installedAppName: "WorkBuddy AI"
                ),
            "WorkBuddy uses its official website for download and latest version detection"
        )

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
        let unsafeCleanup = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test",
        "homeDiscovery":{"defaultPaths":["~/.test"],"environmentVariables":[]},
        "fingerprints":{"required":[{"kind":"file","relativePath":"marker"}],"optional":[],"negative":[]},
        "skills":[],"artifacts":[{"relativePath":"sessions","category":"sessions","cleanup":
        {"risk":"userContent","method":"officialPermanentDelete","unitBoundary":"root"}}],
        "capabilities":{"space":true,"skills":false,"activity":false,"cleanup":true}}
        """.utf8)
        try expectThrows("official cleanup requires a named adapter boundary") {
            _ = try AgentDefinitionCatalog.load(data: unsafeCleanup)
        }
        let unsafePattern = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test",
        "homeDiscovery":{"defaultPaths":["~/*/.test"],"environmentVariables":[]},
        "fingerprints":{"required":[],"optional":[],"negative":[]},
        "skills":[],"artifacts":[],"capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8)
        try expectThrows("default Home glob can only match one directory level") {
            _ = try AgentDefinitionCatalog.load(data: unsafePattern)
        }
        let unsafeVersionPath = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test",
        "homeDiscovery":{"defaultPaths":["~/.test"],"environmentVariables":[]},
        "fingerprints":{"required":[{"kind":"jsonFile","relativePath":"version.json","versionKeyPath":"../bad"}],"optional":[],"negative":[]},
        "skills":[],"artifacts":[],"capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8)
        try expectThrows("unsafe version key path is rejected") {
            _ = try AgentDefinitionCatalog.load(data: unsafeVersionPath)
        }
        let wrongVersionKind = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test",
        "homeDiscovery":{"defaultPaths":["~/.test"],"environmentVariables":[]},
        "fingerprints":{"required":[{"kind":"file","relativePath":"version","versionKeyPath":"version"}],"optional":[],"negative":[]},
        "skills":[],"artifacts":[],"capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8)
        try expectThrows("version key path is only valid on jsonFile fingerprints") {
            _ = try AgentDefinitionCatalog.load(data: wrongVersionKind)
        }
        let unsafeScriptURL = Data("""
        {"schemaVersion":1,"id":"test","displayName":"Test",
        "homeDiscovery":{"defaultPaths":["~/.test"],"environmentVariables":[]},
        "fingerprints":{"required":[],"optional":[],"negative":[]},
        "skills":[],"artifacts":[],
        "capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false},
        "marketplace":{"summary":"Test","homepageURL":"https://example.com",
        "install":{"kind":"brew","formula":"test","scriptURL":"http://insecure.example/install.sh"}}}
        """.utf8)
        try expectThrows("install scripts must use HTTPS") {
            _ = try AgentDefinitionCatalog.load(data: unsafeScriptURL)
        }
        try expect(
            AgentVersion.isUpdate(latest: "2.0.0", installed: "1.9.9") &&
                !AgentVersion.isUpdate(latest: "1.0.0", installed: "1.0.0") &&
                !AgentVersion.isUpdate(latest: "latest", installed: "1.0.0") &&
                AgentVersion.isUpdate(latest: "v2.0", installed: "1.10.0") &&
                AgentVersion.isUpdate(latest: "2.0.0, 2.0.1", installed: "1.9.9") &&
                !AgentVersion.isUpdate(latest: "5.3.13.35912340", installed: "5.3.13") &&
                AgentVersion.isUpdate(latest: "5.3.14.35912340", installed: "5.3.13"),
            "agent version comparison handles semver, unknown versions, v prefixes, and comma suffixes"
        )
        try expect(
            AgentVersion.isSameRelease("5.3.13", "5.3.13.35912340") &&
                !AgentVersion.isSameRelease("5.2.6", "5.3.13.35912340"),
            "website install completion accepts app bundle short versions within the same release"
        )
        try expect(
            CanonicalPath.isEqualOrDescendant("/tmp/fixture", of: "/") &&
                CanonicalPath.isDescendant("/foo/child", of: "/foo") &&
                !CanonicalPath.isEqualOrDescendant("/foobar", of: "/foo"),
            "canonical path containment handles filesystem root and component boundaries"
        )
    }

    private static func testMarketVersionRefreshPolicy() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let policy = MarketVersionRefreshPolicy(cacheTTL: 30 * 60, retryAfter: 2 * 60)

        let stale = policy.staleProductIDs(
            allProductIDs: ["a", "b", "c"],
            fetchedAtByProduct: [
                "a": now.addingTimeInterval(-31 * 60),
                "b": now.addingTimeInterval(-5 * 60),
            ],
            now: now
        )
        try expect(stale == ["a", "c"], "only missing or TTL-expired products are refreshed")

        try expect(
            policy.shouldRefresh(force: false, staleProductIDs: stale, lastAttemptAt: now.addingTimeInterval(-60), now: now) == false,
            "failed refreshes respect the retry backoff"
        )
        try expect(
            policy.shouldRefresh(force: false, staleProductIDs: stale, lastAttemptAt: now.addingTimeInterval(-121), now: now),
            "stale products refresh after the retry backoff"
        )
        try expect(
            policy.shouldRefresh(force: false, staleProductIDs: [], lastAttemptAt: nil, now: now) == false,
            "fresh caches do not trigger requests"
        )
        try expect(
            policy.shouldRefresh(force: true, staleProductIDs: [], lastAttemptAt: now.addingTimeInterval(-1), now: now),
            "explicit force refresh bypasses cache and backoff"
        )
    }

    private static func testHomebrewVersionParsing() throws {
        let output = """
        codex 0.51.0,1
        cursor 2.1.0
        automake 1.16.5
        """
        let versions = try unwrap(
            HomebrewAgentVersionProbe.parseVersions(output, productsByFormula: [
                "codex": "openai.codex",
                "cursor": "cursor.cursor",
            ]),
            "homebrew version parser"
        )
        try expect(
            versions == [
                "openai.codex": "0.51.0",
                "cursor.cursor": "2.1.0",
            ],
            "brew list output maps formula versions to product IDs and ignores unrelated formulas"
        )
    }

    private static func testExecutableVersionProbeParsing() throws {
        try expect(
            ExecutableAgentVersionProbe.parseVersionOutput("codex-cli 0.146.0\n") == "0.146.0",
            "codex-cli version output is parsed"
        )
        try expect(
            ExecutableAgentVersionProbe.parseVersionOutput("2.1.152 (Claude Code)") == "2.1.152",
            "claude version output is parsed"
        )
        try expect(
            ExecutableAgentVersionProbe.parseVersionOutput("aider 0.86.2") == "0.86.2",
            "aider version output is parsed"
        )
        try expect(
            ExecutableAgentVersionProbe.parseVersionOutput("1.2.3, 1.2.4") == "1.2.3",
            "executable version output keeps only the first comma-separated token"
        )
        try expect(
            ExecutableAgentVersionProbe.parseVersionOutput("no version here") == nil,
            "non-version output is not fabricated"
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
        try expect(
            defaultResult.version == "fixture" &&
                defaultResult.versionEvidence?.contains("version:jsonFile:version.json") == true,
            "scan extracts the Agent version declared by the jsonFile version key path"
        )
        let discoveredVersions = await ScanUseCase(catalog: try AgentDefinitionCatalog.bundled())
            .discoverInstalledVersions(request: ScanRequest(
                homeDirectory: root,
                customLocations: [alias],
                environment: ["CODEX_HOME": deepHome.path]
            ))
        try expect(
            discoveredVersions.contains { $0.productID == "openai.codex" && $0.version == "fixture" },
            "lightweight installed-version scan reads versions without indexing storage"
        )
        try expect(Set(snapshot.storageLedger.artifacts.map(\.id)).count == snapshot.storageLedger.artifacts.count, "storage ledger contains each physical resource once")
        try expect(
            snapshot.totalStorage.physicalBytes == snapshot.storageLedger.artifacts.reduce(0) { $0 &+ $1.storage.physicalBytes },
            "snapshot total conserves artifact physical bytes"
        )
        try expect(snapshot.storageLedger.artifacts.allSatisfy { $0.category == .unattributed }, "undefined artifact rules do not guess categories")

        let supportedRoot = root.appending(path: "supported-agents")
        let supportedHomes: [(path: String, skillRoot: String)] = [
            (".codex", "skills"),
            (".codex-work", "skills"),
            (".codex.team", "skills"),
            (".claude", "skills"),
            (".cursor", "skills"),
            (".trae", "skills"),
        ]
        for (index, fixture) in supportedHomes.enumerated() {
            let home = supportedRoot.appending(path: fixture.path)
            let skill = home.appending(path: "\(fixture.skillRoot)/fixture-\(index)")
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: fixture-\(index)\ndescription: fixture\n---\n".utf8)
                .write(to: skill.appending(path: "SKILL.md"))
            if fixture.path.hasPrefix(".codex") {
                try Data("{\"version\":\"fixture\"}".utf8).write(to: home.appending(path: "version.json"))
            }
        }
        let nestedSystemSkill = supportedRoot.appending(path: ".codex/skills/.system/system-fixture")
        try FileManager.default.createDirectory(at: nestedSystemSkill, withIntermediateDirectories: true)
        try Data("---\nname: system-fixture\ndescription: nested\n---\n".utf8)
            .write(to: nestedSystemSkill.appending(path: "SKILL.md"))
        let cursorManagedSkill = supportedRoot.appending(path: ".cursor/skills-cursor/managed-fixture")
        try FileManager.default.createDirectory(at: cursorManagedSkill, withIntermediateDirectories: true)
        try Data("---\nname: managed-fixture\ndescription: managed\n---\n".utf8)
            .write(to: cursorManagedSkill.appending(path: "SKILL.md"))
        for name in [".codexpotter", ".codex-broken"] {
            try FileManager.default.createDirectory(at: supportedRoot.appending(path: name), withIntermediateDirectories: true)
        }
        try Data("{\"version\":\"not-codex\"}".utf8)
            .write(to: supportedRoot.appending(path: ".codexpotter/version.json"))

        let supportedSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(
            request: ScanRequest(homeDirectory: supportedRoot)
        )
        let supportedPaths = Set(supportedSnapshot.homes.filter { $0.confidence == .confirmed }.map {
            URL(fileURLWithPath: $0.path).lastPathComponent
        })
        try expect(
            supportedPaths == Set(supportedHomes.map(\.path)),
            "Codex glob Homes and Claude Code, Cursor, and Trae default Homes are discovered without prefix false positives"
        )
        try expect(
            supportedSnapshot.homes.first(where: { $0.path == supportedRoot.appending(path: ".codex-broken").path })?.confidence == .possible,
            "a matching Codex Home without its fingerprint remains possible"
        )
        let supportedSkillIndex = await SkillIndexUseCase(catalog: try AgentDefinitionCatalog.bundled())
            .execute(homes: supportedSnapshot.homes)
        try expect(
            supportedSkillIndex.installationCount == supportedHomes.count + 2 &&
                supportedSkillIndex.logicalSkills.contains(where: { $0.id == "system-fixture" }),
            "bundled definitions recognize top-level and nested SKILL.md packages for every supported agent"
        )
        try expect(
            supportedSkillIndex.logicalSkills.first(where: { $0.id == "managed-fixture" })?
                .variants.first?.installations.first?.isWritable == false,
            "managed Cursor skills are indexed without exposing write operations"
        )
        try expect(
            supportedSkillIndex.logicalSkills.allSatisfy { $0.missingHomeIDs.count == supportedHomes.count - 1 },
            "Skill coverage only includes confirmed skill-capable Homes"
        )
        let arbitraryCustomHome = supportedRoot.appending(path: "arbitrary-custom-home")
        try FileManager.default.createDirectory(at: arbitraryCustomHome, withIntermediateDirectories: true)
        let arbitraryCustomSnapshot = try await ScanUseCase(catalog: AgentDefinitionCatalog.bundled()).execute(
            request: ScanRequest(
                homeDirectory: supportedRoot.appending(path: "empty-user-home"),
                customLocations: [arbitraryCustomHome]
            )
        )
        try expect(
            arbitraryCustomSnapshot.homes.isEmpty,
            "fingerprintless agents do not claim arbitrary custom locations"
        )

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

    private static func testInstalledVersionExtraction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AgentNestVersionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: ".codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("""
        {"build":{"version":"1.2.3"},"channel":"stable"}
        """.utf8).write(to: home.appending(path: "version.json"))

        let definition = try AgentDefinitionCatalog.load(data: Data("""
        {"schemaVersion":1,"id":"test.versioned-agent","displayName":"Versioned Agent",
        "homeDiscovery":{"defaultPaths":["~/.codex"],"environmentVariables":[]},
        "fingerprints":{"required":[{"kind":"jsonFile","relativePath":"version.json","versionKeyPath":"build.version"}],"optional":[],"negative":[]},
        "skills":[],"artifacts":[],"capabilities":{"space":false,"skills":false,"activity":false,"cleanup":false}}
        """.utf8))
        let catalog = try AgentDefinitionCatalog(definitions: [definition])
        let snapshot = try await ScanUseCase(catalog: catalog).execute(request: ScanRequest(homeDirectory: root))
        let scannedHome = try unwrap(snapshot.homes.first, "versioned agent home")
        try expect(
            scannedHome.version == "1.2.3" &&
                scannedHome.versionEvidence?.contains("version:jsonFile:version.json") == true,
            "nested versionKeyPath values are extracted with evidence during a full scan"
        )

        try Data("{\"build\":{\"version\":999}}".utf8).write(to: home.appending(path: "version.json"))
        let numericSnapshot = try await ScanUseCase(catalog: catalog).execute(request: ScanRequest(homeDirectory: root))
        try expect(numericSnapshot.homes.first?.version == "999", "numeric JSON versions are normalized to strings")

        try Data("{\"build\":{\"version\":\"1.2.3, 1.2.4\"}}".utf8).write(to: home.appending(path: "version.json"))
        let commaSnapshot = try await ScanUseCase(catalog: catalog).execute(request: ScanRequest(homeDirectory: root))
        try expect(commaSnapshot.homes.first?.version == "1.2.3", "scanned versions keep only the part before the first comma")

        try Data("{\"build\":{\"channel\":\"stable\"}}".utf8).write(to: home.appending(path: "version.json"))
        let missingVersionSnapshot = try await ScanUseCase(catalog: catalog).execute(request: ScanRequest(homeDirectory: root))
        try expect(
            missingVersionSnapshot.homes.first?.confidence == .confirmed &&
                missingVersionSnapshot.homes.first?.version == nil,
            "a valid fingerprint without a version field still confirms the Home without fabricating a version"
        )

        let legacyHomeJSON = Data("""
        {"id":{"device":1,"inode":2,"kind":"directory"},
        "productID":"openai.codex","displayName":"Codex","path":"/tmp/.codex",
        "source":"defaultPath","confidence":"confirmed","evidence":[],
        "storage":{"logicalBytes":0,"physicalBytes":0,"itemCount":0}}
        """.utf8)
        let legacyHome = try JSONDecoder().decode(AgentHome.self, from: legacyHomeJSON)
        try expect(
            legacyHome.version == nil && legacyHome.versionEvidence == nil,
            "snapshots saved before version support still decode successfully"
        )
    }

    private static func testInstalledAppBundleVersionProbe() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AgentNestAppBundleProbe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Fixture.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.2.3</string></dict></plist>
        """
        try Data(info.utf8).write(to: contents.appending(path: "Info.plist"))
        try expect(
            InstalledAppBundleVersionProbe.installedVersion(
                appName: "Fixture",
                additionalApplicationDirectories: [root]
            ) == "1.2.3",
            "installed app bundle version is read from CFBundleShortVersionString"
        )
    }

    private static func testMarketplaceVersionService() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let service = MarketplaceVersionService(
            baseURL: URL(string: "https://unit.test/api")!,
            npmRegistryURL: URL(string: "https://unit.test")!,
            appStoreLookupURL: URL(string: "https://unit.test/lookup")!,
            session: session
        )

        URLProtocolStub.register(
            path: "/api/formula/codex.json",
            data: Data("{\"versions\":{\"stable\":\"0.51.0\"}}".utf8)
        )
        let formulaVersion = try await service.latestVersion(for: AgentInstallMethod(kind: .brew, formula: "codex"))
        try expect(formulaVersion == "0.51.0", "formula latest version is read from versions.stable")

        URLProtocolStub.register(
            path: "/api/cask/cursor.json",
            data: Data("{\"version\":\"2.1.0,250207\"}".utf8)
        )
        let caskVersion = try await service.latestVersion(for: AgentInstallMethod(kind: .cask, formula: "cursor"))
        try expect(caskVersion == "2.1.0", "cask version keeps only the part before the first comma")

        URLProtocolStub.register(
            path: "/@earendil-works/pi-coding-agent",
            data: Data("{\"dist-tags\":{\"latest\":\"0.84.2\"}}".utf8)
        )
        let npmVersion = try await service.latestVersion(
            for: AgentInstallMethod(kind: .npm, formula: "@earendil-works/pi-coding-agent")
        )
        try expect(npmVersion == "0.84.2", "npm latest version is read from dist-tags.latest")

        URLProtocolStub.register(
            path: "/v2/update",
            data: Data("{\"version\":\"5.3.13.35912340\",\"productVersion\":\"5.3.13.35912340\"}".utf8)
        )
        let websiteVersion = try await service.latestVersion(
            websiteUpdateURL: "https://www.workbuddy.ai/v2/update?platform=workbuddy-darwin-arm64"
        )
        try expect(websiteVersion == "5.3.13.35912340", "official website update JSON returns the latest version")
        let websiteMethodVersion = try await service.latestVersion(
            for: AgentInstallMethod(
                kind: .website,
                formula: "WorkBuddy",
                websiteUpdateURL: "https://unit.test/v2/update?platform={platform}"
            )
        )
        try expect(websiteMethodVersion == "5.3.13.35912340", "website install method resolves the current platform and version")

        URLProtocolStub.register(
            path: "/lookup",
            data: Data("{\"results\":[{\"version\":\"1.9.4\"}]}".utf8)
        )
        let appStoreVersion = try await service.latestVersion(appStoreID: "6761374913")
        try expect(appStoreVersion == "1.9.4", "App Store latest version is read from the lookup result")

        URLProtocolStub.register(
            path: "/api/formula/missing-version.json",
            data: Data("{\"name\":\"missing-version\"}".utf8),
            status: 200
        )
        try await expectThrows("missing version field is a structured service error") {
            _ = try await service.latestVersion(for: AgentInstallMethod(kind: .brew, formula: "missing-version"))
        }

        URLProtocolStub.register(
            path: "/api/formula/not-found.json",
            data: Data("not found".utf8),
            status: 404
        )
        try await expectThrows("non-200 responses fail closed") {
            _ = try await service.latestVersion(for: AgentInstallMethod(kind: .brew, formula: "not-found"))
        }

        URLProtocolStub.register(
            path: "/api/cask/empty-version.json",
            data: Data("{\"version\":\"   \"}".utf8)
        )
        try await expectThrows("blank versions are rejected") {
            _ = try await service.latestVersion(for: AgentInstallMethod(kind: .cask, formula: "empty-version"))
        }

        URLProtocolStub.reset()
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

    private static func testActivityWorkspace() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var accumulator = ActivityWorkspaceAccumulator(retention: 3_600)
        let baseline = accumulator.record(activityFixture(at: start, cpu: nil))
        try expect(
            baseline.trend.count == 1 &&
                baseline.trend[0].cpuFraction == nil &&
                baseline.trend[0].coveredSeconds == 0,
            "activity workspace preserves baseline gaps"
        )

        let middle = accumulator.record(activityFixture(at: start.addingTimeInterval(1_800), cpu: 0.25))
        try expect(
            middle.trend.count == 2 && middle.trend[1].coveredSeconds == 60,
            "activity workspace accumulates lightweight trend points"
        )

        let retained = accumulator.record(activityFixture(at: start.addingTimeInterval(3_601), cpu: 0.5))
        try expect(
            retained.trend.count == 2 && retained.trend.first?.capturedAt == start.addingTimeInterval(1_800),
            "activity workspace prunes points outside its retention window"
        )

        let late = accumulator.record(activityFixture(at: start.addingTimeInterval(3_000), cpu: 0.9))
        try expect(
            late.current.capturedAt == retained.current.capturedAt && late.trend == retained.trend,
            "activity workspace ignores late samples"
        )

        accumulator.reset()
        let reset = accumulator.record(activityFixture(at: start.addingTimeInterval(7_200), cpu: 0.1))
        try expect(reset.trend.count == 1, "activity workspace reset clears retained points")
    }

    private static func testCleanupActivitySignature() throws {
        let unavailable = CleanupActivitySignature(activity: nil)
        let dropped = CleanupActivitySignature(activity: activityFixture(
            at: Date(timeIntervalSince1970: 1_000),
            cpu: 0.2,
            droppedEvidenceCount: 1
        ))
        try expect(unavailable == dropped, "incomplete activity evidence has one cleanup-protection signature")

        let identity = ProcessStartIdentity(pid: 42, startSeconds: 10, startMicroseconds: 20)
        let homeID = PhysicalResourceIdentity(device: 1, inode: 2, kind: .directory)
        let first = processFixture(
            identity: identity,
            homeID: homeID,
            cpu: 0.1,
            filePath: "/tmp/agent/session.json",
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let ratesChanged = processFixture(
            identity: identity,
            homeID: homeID,
            cpu: 0.8,
            filePath: "/tmp/agent/session.json",
            observedAt: Date(timeIntervalSince1970: 1_003)
        )
        let firstSignature = CleanupActivitySignature(activity: activityFixture(
            at: Date(timeIntervalSince1970: 1_000),
            cpu: 0.1,
            processes: [first]
        ))
        let ratesChangedSignature = CleanupActivitySignature(activity: activityFixture(
            at: Date(timeIntervalSince1970: 1_003),
            cpu: 0.8,
            processes: [ratesChanged]
        ))
        try expect(firstSignature == ratesChangedSignature, "rate-only changes do not rebuild cleanup inventory")

        let evidenceChanged = processFixture(
            identity: identity,
            homeID: homeID,
            cpu: 0.8,
            filePath: "/tmp/agent/other.json",
            observedAt: Date(timeIntervalSince1970: 1_003)
        )
        let evidenceChangedSignature = CleanupActivitySignature(activity: activityFixture(
            at: Date(timeIntervalSince1970: 1_003),
            cpu: 0.8,
            processes: [evidenceChanged]
        ))
        try expect(firstSignature != evidenceChangedSignature, "cleanup-protection evidence changes rebuild inventory")
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
                id: "fixture-\(name)", generation: generation, productID: "fixture.agent", path: "/fixture/home/\(name)", homePath: "/fixture/home", identity: identity, homeIdentity: homeIdentity,
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
        try expect(policy.isSelectable(old), "inactive non-protected units are selectable")
        try expect(!policy.isSelectable(writer), "active units are not selectable")
        try expect(!policy.isSelectable(unit(name: "protected", ageDays: 120, activity: .inactive, risk: .protected)), "protected units are not selectable")
        let filtered = policy.filter(
            units: [old, writer, unreliable, recent],
            query: CleanupQuery(inactiveBefore: now.addingTimeInterval(-90 * 86_400), minimumPhysicalBytes: 1_000_000_000)
        )
        try expect(Set(filtered.map(\.name)) == Set(["old", "writer"]), "date filtering uses reliable cleanup-unit evidence")
        let selectable = policy.selectableUnits(
            units: [old, writer, unreliable, recent],
            query: CleanupQuery(inactiveBefore: now.addingTimeInterval(-90 * 86_400), minimumPhysicalBytes: 1_000_000_000)
        )
        try expect(selectable.map(\.name) == ["old"], "candidate projection contains only selectable cleanup units")
        let plan = policy.plan(generation: generation, selected: filtered)
        try expect(plan.units.map(\.name) == ["old"], "writer cannot enter cleanup plan")
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
            id: "fixture-outside", generation: generation, productID: "fixture.agent", path: outside.path, homePath: home.path,
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
        let inside = home.appending(path: "cache.bin")
        try Data("fixture".utf8).write(to: inside)
        let insideIdentity = try physicalIdentity(inside)
        let activityUnit = CleanupUnit(
            id: "fixture-activity", generation: generation, productID: "fixture.agent",
            path: inside.path, homePath: home.path, identity: insideIdentity,
            homeIdentity: try physicalIdentity(home), name: "cache.bin", category: "cache",
            storage: StorageMeasurement(), risk: .rebuildable, activity: .inactive,
            lastActivity: LastActivityEvidence(date: now.addingTimeInterval(-100 * 86_400), kind: .officialMetadata),
            method: .trash,
            members: [CleanupUnitMember(path: inside.path, identity: insideIdentity, storage: StorageMeasurement(), modifiedAt: now)]
        )
        let activityResult = await CleanupExecutor().execute(
            CleanupPlan(generation: generation, units: [activityUnit]),
            currentGeneration: generation
        )
        try expect(
            activityResult.first?.code == "cleanup.activityChanged" && FileManager.default.fileExists(atPath: inside.path),
            "execution fails closed when current activity evidence is unavailable"
        )
    }

    private static func testStorageOwnershipScope() throws {
        let generation = UUID()
        let capabilities = try unwrap(
            AgentDefinitionCatalog.bundled().definitions.first?.capabilities,
            "bundled capabilities"
        )
        let homeAID = PhysicalResourceIdentity(device: 1, inode: 10, kind: .directory)
        let homeBID = PhysicalResourceIdentity(device: 1, inode: 20, kind: .directory)
        let homeCID = PhysicalResourceIdentity(device: 1, inode: 30, kind: .directory)
        func home(id: PhysicalResourceIdentity, productID: String, path: String) -> AgentHome {
            AgentHome(
                id: id,
                productID: productID,
                displayName: productID,
                path: path,
                source: .defaultPath,
                confidence: .confirmed,
                evidence: [],
                storage: StorageMeasurement()
            )
        }
        let homeA = home(id: homeAID, productID: "agent.a", path: "/agents/a/default")
        let homeB = home(id: homeBID, productID: "agent.a", path: "/agents/a/custom")
        let homeC = home(id: homeCID, productID: "agent.b", path: "/agents/b/default")
        let products = [
            AgentProduct(
                id: "agent.a", displayName: "Agent A", definitionVersion: 1,
                supportState: .supported, capabilities: capabilities,
                installations: [], homes: [homeA, homeB], profiles: []
            ),
            AgentProduct(
                id: "agent.b", displayName: "Agent B", definitionVersion: 1,
                supportState: .supported, capabilities: capabilities,
                installations: [], homes: [homeC], profiles: []
            ),
        ]
        func artifact(inode: UInt64, path: String, homeIDs: [PhysicalResourceIdentity]) -> ArtifactRecord {
            ArtifactRecord(
                id: PhysicalResourceIdentity(device: 1, inode: inode, kind: .file),
                path: path,
                category: .sessions,
                attribution: homeIDs.count > 1 ? .shared : .home,
                homeIDs: homeIDs,
                storage: StorageMeasurement(physicalBytes: 1),
                evidence: [],
                modifiedAt: nil
            )
        }
        let artifactA = artifact(inode: 101, path: "/agents/a/default/session", homeIDs: [homeAID])
        let artifactB = artifact(inode: 102, path: "/agents/b/default/session", homeIDs: [homeCID])
        let shared = artifact(inode: 103, path: "/agents/shared", homeIDs: [homeAID, homeCID])
        let snapshot = DeviceSnapshot(
            generation: generation,
            createdAt: Date(),
            isPartial: false,
            products: products,
            storageLedger: StorageLedger(artifacts: [artifactA, artifactB, shared]),
            coverage: SnapshotCoverage(
                directories: .complete,
                agents: .complete,
                space: .complete,
                skills: .complete,
                activity: .complete,
                unreadableLocationCount: 0
            ),
            findings: []
        )
        func cleanupUnit(id: String, inode: UInt64, productID: String, home: AgentHome) -> CleanupUnit {
            CleanupUnit(
                id: id,
                generation: generation,
                productID: productID,
                path: "\(home.path)/session",
                homePath: home.path,
                identity: PhysicalResourceIdentity(device: 1, inode: inode, kind: .file),
                homeIdentity: home.id,
                name: id,
                category: "sessions",
                storage: StorageMeasurement(physicalBytes: 1),
                risk: .userContent,
                activity: .inactive,
                lastActivity: LastActivityEvidence(date: Date(), kind: .officialMetadata),
                method: .officialPermanentDelete
            )
        }
        let unitA = cleanupUnit(id: "unit-a", inode: 201, productID: "agent.a", home: homeA)
        let unitC = cleanupUnit(id: "unit-c", inode: 202, productID: "agent.b", home: homeC)
        let samePathDifferentIdentity = cleanupUnit(
            id: "unit-same-path",
            inode: 203,
            productID: "agent.a",
            home: home(id: PhysicalResourceIdentity(device: 2, inode: 10, kind: .directory), productID: "agent.a", path: homeA.path)
        )

        let all = StorageOwnershipFilter(scope: .all, snapshot: snapshot)
        try expect(all.includes(artifactA) && all.includes(artifactB) && all.includes(unitA) && all.includes(unitC), "all ownership scope includes every item")

        let productA = StorageOwnershipFilter(scope: .product("agent.a"), snapshot: snapshot)
        try expect(productA.includes(artifactA) && productA.includes(shared) && !productA.includes(artifactB), "product scope includes all of the product's Homes")
        try expect(productA.includes(unitA) && !productA.includes(unitC), "product scope filters cleanup units by product")

        let onlyHomeA = StorageOwnershipFilter(scope: .home(homeAID), snapshot: snapshot)
        try expect(onlyHomeA.includes(artifactA) && onlyHomeA.includes(shared) && !onlyHomeA.includes(artifactB), "Home scope uses stable physical ownership")
        try expect(
            onlyHomeA.includes(unitA) && !onlyHomeA.includes(unitC) && !onlyHomeA.includes(samePathDifferentIdentity),
            "Home scope filters cleanup units by stable Home identity rather than path"
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
        "skills":[],"artifacts":[{"relativePath":"cache","category":"cache","cleanup":{"risk":"rebuildable","method":"trash","unitBoundary":"root"}}],
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

    private static func testCodexCleanupFamilies() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AgentNestCodexCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: ".codex")
        let sessions = home.appending(path: "sessions/2026/01/02")
        let temporaryCache = home.appending(path: ".tmp")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryCache, withIntermediateDirectories: true)
        try Data("{\"version\":\"fixture\"}".utf8).write(to: home.appending(path: "version.json"))
        try Data(repeating: 3, count: 4_096).write(to: temporaryCache.appending(path: "cache.bin"))
        let mainID = UUID().uuidString.lowercased()
        let childID = UUID().uuidString.lowercased()
        let main = sessions.appending(path: "rollout-main-\(mainID).jsonl")
        let child = sessions.appending(path: "rollout-child-\(childID).jsonl")
        try Data(repeating: 1, count: 8_192).write(to: main)
        try Data(repeating: 2, count: 4_096).write(to: child)
        let officialActivity = Date().addingTimeInterval(-100 * 86_400)
        try createCodexStateDatabase(
            at: home.appending(path: "state_5.sqlite"),
            records: [
                (mainID, main.path, officialActivity),
                (childID, child.path, officialActivity.addingTimeInterval(60)),
            ],
            edges: [(mainID, childID)]
        )

        let catalog = try AgentDefinitionCatalog.bundled()
        let snapshot = try await ScanUseCase(catalog: catalog).execute(
            request: ScanRequest(homeDirectory: root)
        )
        let registry = CleanupAdapterRegistry(adapters: [
            CodexThreadCleanupAdapter(executablePaths: [], requestTimeout: 1),
        ])
        let inventory = CleanupInventoryUseCase(catalog: catalog, adapters: registry)
            .execute(snapshot: snapshot, activity: activityFixture(at: Date(), cpu: 0.1))
        let unit = try unwrap(inventory.first(where: { $0.nativeID == mainID }), "Codex cleanup family")
        let cacheUnit = try unwrap(inventory.first(where: { $0.path == temporaryCache.path }), "Codex temporary cache unit")
        try expect(
            cacheUnit.members.count == 2 && cacheUnit.method == .trash &&
                cacheUnit.risk == .rebuildable && cacheUnit.lastActivity.kind == .contentMaximumModification,
            "declared Codex cache roots become complete recoverable directory cleanup units"
        )
        try expect(
            unit.members.count == 2 && unit.method == .officialPermanentDelete &&
                unit.risk == .userContent && unit.lastActivity.kind == .officialMetadata,
            "Codex parent and subagent rollouts form one complete official cleanup unit"
        )
        try expect(
            unit.storage.physicalBytes == unit.members.reduce(0) { $0 &+ $1.storage.physicalBytes },
            "cleanup family preview reuses the unique physical storage ledger"
        )
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        try expect(
            CleanupPolicy().filter(units: inventory, query: CleanupQuery(inactiveBefore: cutoff)).contains { $0.id == unit.id },
            "official last-activity metadata drives inactive-before filtering"
        )
        let range = officialActivity.addingTimeInterval(-60)...officialActivity.addingTimeInterval(120)
        try expect(
            CleanupPolicy().filter(units: inventory, query: CleanupQuery(activityRange: range)).contains { $0.id == unit.id },
            "date-range filtering is applied to the complete cleanup unit"
        )

        let executable = root.appending(path: "fake-codex")
        try Data("""
        #!/usr/bin/env python3
        import json, os, sys
        deleted = False
        for line in sys.stdin:
            request = json.loads(line)
            request_id = request.get("id")
            method = request.get("method")
            if request_id is None:
                continue
            if method == "initialize":
                result = {"codexHome": os.environ["CODEX_HOME"], "userAgent": "codex-test"}
                response = {"id": request_id, "result": result}
            elif method == "thread/read":
                if deleted:
                    response = {"id": request_id, "error": {"code": -32602, "message": "thread not found"}}
                else:
                    response = {"id": request_id, "result": {"thread": {"id": "\(mainID)", "parentThreadId": None}}}
            elif method == "thread/delete":
                deleted = True
                response = {"id": request_id, "result": {}}
            else:
                response = {"id": request_id, "error": {"code": -32601, "message": "unsupported"}}
            print(json.dumps(response), flush=True)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let liveRegistry = CleanupAdapterRegistry(adapters: [
            CodexThreadCleanupAdapter(executablePaths: [executable.path], requestTimeout: 2),
        ])
        let results = await CleanupExecutor(adapters: liveRegistry).execute(
            CleanupPolicy().plan(generation: snapshot.generation, selected: [unit]),
            currentGeneration: snapshot.generation,
            currentActivity: activityFixture(at: Date(), cpu: 0.1)
        )
        try expect(
            results == [CleanupResult(unitID: unit.id, status: .succeeded, code: "cleanup.officialDeleted")],
            "official Codex cleanup validates thread identity, deletes, and confirms absence"
        )
        let lateChildID = UUID().uuidString.lowercased()
        let lateChild = sessions.appending(path: "rollout-child-\(lateChildID).jsonl")
        try Data("late child".utf8).write(to: lateChild)
        try appendCodexThread(
            at: home.appending(path: "state_5.sqlite"),
            id: lateChildID,
            path: lateChild.path,
            updatedAt: Date(),
            parent: mainID
        )
        let changedResults = await CleanupExecutor(adapters: liveRegistry).execute(
            CleanupPlan(generation: snapshot.generation, units: [unit]),
            currentGeneration: snapshot.generation,
            currentActivity: activityFixture(at: Date(), cpu: 0.1)
        )
        try expect(
            changedResults.first?.status == .skipped &&
                changedResults.first?.code == "cleanup.officialIdentityChanged",
            "a relationship added after preview blocks official family deletion"
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
        "skills":[{"relativePath":"skills","format":"directory-skill-md","writable":true}],"artifacts":[],
        "capabilities":{"space":true,"skills":true,"activity":false,"cleanup":false}}
        """.utf8)
        let skillCatalog = try AgentDefinitionCatalog(definitions: [AgentDefinitionCatalog.load(data: definitionData)])
        let indexer = SkillIndexUseCase(catalog: skillCatalog)
        let firstIndex = await indexer.execute(homes: snapshot.homes)
        let release = try unwrap(firstIndex.logicalSkills.first { $0.id == "release" }, "release logical skill")
        try expect(release.variants.count == 2, "same-name content becomes separate variants")
        try expect(release.missingHomeIDs.count == 1, "coverage reports missing home")

        let nestedSkill = homes[0].appending(path: "skills/.system/nested-fixture")
        try FileManager.default.createDirectory(at: nestedSkill, withIntermediateDirectories: true)
        try Data("---\nname: nested-fixture\ndescription: nested\n---\n".utf8)
            .write(to: nestedSkill.appending(path: "SKILL.md"))
        let nestedIndex = await indexer.execute(homes: snapshot.homes)
        try expect(
            nestedIndex.logicalSkills.contains(where: { $0.id == "nested-fixture" }) &&
                nestedIndex.logicalSkills.first(where: { $0.id == "nested-fixture" })?.variants.first?.installations.first?.isWritable == false,
            "nested directory SKILL.md packages are indexed without inheriting direct-child write access"
        )

        let writer = SkillWriteUseCase()
        let generation = snapshot.generation
        let emptyHome = root.appending(path: "empty-home")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        let provisionedRoot = try await writer.ensureSkillRoot(
            home: emptyHome,
            expectedHomeIdentity: physicalIdentity(emptyHome),
            relativePath: "skills"
        )
        try expect(
            provisionedRoot.path == emptyHome.appending(path: "skills").path &&
                FileManager.default.fileExists(atPath: provisionedRoot.path),
            "a writable Skill root can be provisioned inside an unchanged confirmed Home"
        )
        try await expectThrows("Skill root provisioning rejects a changed Home identity") {
            _ = try await writer.ensureSkillRoot(
                home: emptyHome,
                expectedHomeIdentity: physicalIdentity(homes[0]),
                relativePath: "other-skills"
            )
        }
        try await expectThrows("Skill root provisioning rejects nested paths") {
            _ = try await writer.ensureSkillRoot(
                home: emptyHome,
                expectedHomeIdentity: physicalIdentity(emptyHome),
                relativePath: "nested/skills"
            )
        }
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

    private static func createCodexStateDatabase(
        at url: URL,
        records: [(id: String, path: String, updatedAt: Date)],
        edges: [(parent: String, child: String)]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database else { throw TestFailure("could not create Codex fixture database") }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          rollout_path TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          updated_at_ms INTEGER
        );
        CREATE TABLE thread_spawn_edges (
          parent_thread_id TEXT NOT NULL,
          child_thread_id TEXT NOT NULL PRIMARY KEY
        );
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw TestFailure("could not create Codex fixture schema")
        }
        for record in records {
            let seconds = Int64(record.updatedAt.timeIntervalSince1970)
            let milliseconds = Int64(record.updatedAt.timeIntervalSince1970 * 1_000)
            let path = record.path.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO threads VALUES ('\(record.id)', '\(path)', \(seconds), \(milliseconds))"
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw TestFailure("could not insert Codex fixture thread")
            }
        }
        for edge in edges {
            let sql = "INSERT INTO thread_spawn_edges VALUES ('\(edge.parent)', '\(edge.child)')"
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw TestFailure("could not insert Codex fixture edge")
            }
        }
    }

    private static func appendCodexThread(
        at url: URL,
        id: String,
        path: String,
        updatedAt: Date,
        parent: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw TestFailure("could not open Codex fixture database") }
        defer { sqlite3_close(database) }
        let seconds = Int64(updatedAt.timeIntervalSince1970)
        let milliseconds = Int64(updatedAt.timeIntervalSince1970 * 1_000)
        let escapedPath = path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(
            database,
            "INSERT INTO threads VALUES ('\(id)', '\(escapedPath)', \(seconds), \(milliseconds))",
            nil, nil, nil
        ) == SQLITE_OK,
        sqlite3_exec(
            database,
            "INSERT INTO thread_spawn_edges VALUES ('\(parent)', '\(id)')",
            nil, nil, nil
        ) == SQLITE_OK else { throw TestFailure("could not append Codex fixture relationship") }
    }

    private static func activityFixture(
        at date: Date,
        cpu: Double?,
        processes: [VisibleProcessActivity] = [],
        droppedEvidenceCount: Int = 0
    ) -> ActivitySnapshot {
        let available = MetricValue(value: cpu, availability: cpu == nil ? .unavailable : .available, observedSeconds: 60, coverage: cpu == nil ? 0 : 1)
        let unavailable = MetricValue(value: nil, availability: .unavailable, observedSeconds: 60, coverage: 0)
        return ActivitySnapshot(
            capturedAt: date,
            cpuFraction: available,
            diskReadBytesPerSecond: unavailable,
            diskWriteBytesPerSecond: unavailable,
            networkReceiveBytesPerSecond: unavailable,
            networkSendBytesPerSecond: unavailable,
            didResetBaseline: false,
            processes: processes,
            droppedEvidenceCount: droppedEvidenceCount
        )
    }

    private static func processFixture(
        identity: ProcessStartIdentity,
        homeID: PhysicalResourceIdentity,
        cpu: Double,
        filePath: String,
        observedAt: Date
    ) -> VisibleProcessActivity {
        let metric = MetricValue(value: cpu, availability: .available, observedSeconds: 3, coverage: 1)
        return VisibleProcessActivity(
            id: identity,
            name: "fixture",
            executablePath: "/tmp/fixture",
            attribution: .agent,
            productID: "fixture",
            homeID: homeID,
            evidence: [],
            cpuFraction: metric,
            requestedReadBytesPerSecond: metric,
            requestedWriteBytesPerSecond: metric,
            currentlyOpenFiles: [ProcessFileEvidence(kind: .currentlyOpen, path: filePath, observedAt: observedAt)]
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

private final class URLProtocolStubRegistry: @unchecked Sendable {
    struct Handler {
        let data: Data
        let status: Int
    }

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func register(path: String, data: Data, status: Int) {
        lock.lock()
        handlers[path] = Handler(data: data, status: status)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }

    func handler(for path: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        if let direct = handlers[path] { return direct }
        guard let decoded = path.removingPercentEncoding else { return nil }
        return handlers[decoded]
    }
}

private final class URLProtocolStub: URLProtocol {
    private static let registry = URLProtocolStubRegistry()

    static func register(path: String, data: Data, status: Int = 200) {
        registry.register(path: path, data: data, status: status)
    }

    static func reset() {
        registry.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let handler = Self.registry.handler(for: url.path),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: handler.status,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: handler.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
