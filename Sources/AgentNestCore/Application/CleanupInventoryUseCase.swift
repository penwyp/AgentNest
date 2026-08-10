import Foundation

public protocol CleanupAdapter: Sendable {
    var id: String { get }

    func discoverUnits(
        rule: ArtifactRule,
        home: AgentHome,
        snapshot: DeviceSnapshot,
        activity: ActivitySnapshot?
    ) -> [CleanupUnit]

    func execute(_ unit: CleanupUnit) async -> CleanupResult
}

public struct CleanupAdapterRegistry: Sendable {
    private let adapters: [String: any CleanupAdapter]

    public init(adapters: [any CleanupAdapter]) {
        self.adapters = adapters.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    public static func live() -> CleanupAdapterRegistry {
        CleanupAdapterRegistry(adapters: [CodexThreadCleanupAdapter()])
    }

    func adapter(id: String) -> (any CleanupAdapter)? {
        adapters[id]
    }
}

public struct CleanupActivitySignature: Equatable, Sendable {
    private struct ProcessEvidence: Equatable, Sendable {
        let id: ProcessStartIdentity
        let homeID: PhysicalResourceIdentity?
        let filePaths: [String]
    }

    private let evidenceIsComplete: Bool
    private let processes: [ProcessEvidence]

    public init(activity: ActivitySnapshot?) {
        guard let activity, activity.droppedEvidenceCount == 0 else {
            evidenceIsComplete = false
            processes = []
            return
        }
        evidenceIsComplete = true
        processes = activity.processes.compactMap { process in
            let filePaths = Set((process.currentlyOpenFiles + process.recentChanges).map(\.path)).sorted()
            guard process.homeID != nil || !filePaths.isEmpty else { return nil }
            return ProcessEvidence(id: process.id, homeID: process.homeID, filePaths: filePaths)
        }.sorted { lhs, rhs in
            if lhs.id.pid != rhs.id.pid { return lhs.id.pid < rhs.id.pid }
            if lhs.id.startSeconds != rhs.id.startSeconds { return lhs.id.startSeconds < rhs.id.startSeconds }
            return lhs.id.startMicroseconds < rhs.id.startMicroseconds
        }
    }
}

public struct CleanupInventoryUseCase: Sendable {
    private let catalog: AgentDefinitionCatalog
    private let adapters: CleanupAdapterRegistry

    public init(
        catalog: AgentDefinitionCatalog,
        adapters: CleanupAdapterRegistry = .live()
    ) {
        self.catalog = catalog
        self.adapters = adapters
    }

    public func execute(snapshot: DeviceSnapshot, activity: ActivitySnapshot?) -> [CleanupUnit] {
        var units: [CleanupUnit] = []
        for home in snapshot.homes where home.confidence == .confirmed {
            guard let definition = catalog.definitions.first(where: { $0.id == home.productID }),
                  definition.capabilities.cleanup else { continue }
            for rule in definition.artifacts {
                guard let cleanup = rule.cleanup else { continue }
                switch cleanup.unitBoundary {
                case .root:
                    if let unit = rootUnit(
                        rule: rule,
                        cleanup: cleanup,
                        home: home,
                        snapshot: snapshot,
                        activity: activity
                    ) {
                        units.append(unit)
                    }
                case .adapter:
                    guard let adapterID = cleanup.adapterID,
                          let adapter = adapters.adapter(id: adapterID) else { continue }
                    units.append(contentsOf: adapter.discoverUnits(
                        rule: rule,
                        home: home,
                        snapshot: snapshot,
                        activity: activity
                    ))
                }
            }
        }

        var unique: [String: CleanupUnit] = [:]
        for unit in units { unique[unit.id] = unit }
        return unique.values.sorted {
            if $0.storage.physicalBytes != $1.storage.physicalBytes {
                return $0.storage.physicalBytes > $1.storage.physicalBytes
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func rootUnit(
        rule: ArtifactRule,
        cleanup: ArtifactCleanupDefinition,
        home: AgentHome,
        snapshot: DeviceSnapshot,
        activity: ActivitySnapshot?
    ) -> CleanupUnit? {
        let targetPath = URL(fileURLWithPath: home.path)
            .appending(path: rule.relativePath)
            .standardizedFileURL.path
        let artifacts = snapshot.storageLedger.artifacts
        guard let root = artifacts.first(where: {
            $0.path == targetPath && $0.homeIDs.contains(home.id)
        }) else { return nil }
        let members = artifacts.filter {
            CanonicalPath.isEqualOrDescendant($0.path, of: targetPath) && $0.homeIDs.contains(home.id)
        }.map(CleanupUnitMember.init)
        let storage = members.reduce(into: StorageMeasurement()) { result, member in
            result = StorageMeasurement(
                logicalBytes: result.logicalBytes &+ member.storage.logicalBytes,
                physicalBytes: result.physicalBytes &+ member.storage.physicalBytes,
                itemCount: result.itemCount + member.storage.itemCount
            )
        }
        let latestModification = members.compactMap(\.modifiedAt).max()
        return CleanupUnit(
            id: stableID(adapterID: "path", home: home, nativeID: targetPath),
            generation: snapshot.generation,
            productID: home.productID,
            path: targetPath,
            homePath: home.path,
            identity: root.id,
            homeIdentity: home.id,
            name: URL(fileURLWithPath: targetPath).lastPathComponent,
            category: rule.category,
            storage: storage,
            risk: cleanup.risk,
            activity: CleanupActivityEvaluator.protection(
                homeID: home.id,
                memberPaths: [targetPath],
                activity: activity
            ),
            lastActivity: LastActivityEvidence(
                date: latestModification,
                kind: latestModification == nil ? .unknown : .contentMaximumModification
            ),
            method: cleanup.method,
            members: members
        )
    }
}

extension CleanupUnitMember {
    init(_ artifact: ArtifactRecord) {
        self.init(
            path: artifact.path,
            identity: artifact.id,
            storage: artifact.storage,
            modifiedAt: artifact.modifiedAt
        )
    }
}

enum CleanupActivityEvaluator {
    static func protection(
        homeID: PhysicalResourceIdentity,
        memberPaths: [String],
        activity: ActivitySnapshot?
    ) -> ActivityProtection {
        guard let activity, activity.droppedEvidenceCount == 0 else { return .unknown }
        let paths = Set(memberPaths)
        for process in activity.processes {
            let hasMatchingFile = (process.currentlyOpenFiles + process.recentChanges).contains { evidence in
                paths.contains(evidence.path) || memberPaths.contains { CanonicalPath.isEqualOrDescendant(evidence.path, of: $0) }
            }
            if hasMatchingFile { return .writerPresent }
        }
        if activity.processes.contains(where: { $0.homeID == homeID }) { return .recentlyOpened }
        return .inactive
    }
}

func stableID(adapterID: String, home: AgentHome, nativeID: String) -> String {
    "\(adapterID)|\(home.id.device):\(home.id.inode):\(home.id.kind.rawValue)|\(nativeID)"
}
