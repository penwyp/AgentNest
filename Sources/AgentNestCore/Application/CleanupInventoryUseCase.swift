import Foundation

public struct CleanupInventoryUseCase: Sendable {
    private let catalog: AgentDefinitionCatalog

    public init(catalog: AgentDefinitionCatalog) {
        self.catalog = catalog
    }

    public func execute(snapshot: DeviceSnapshot, activity: ActivitySnapshot?) -> [CleanupUnit] {
        let artifacts = snapshot.storageLedger.artifacts
        return snapshot.homes.flatMap { home -> [CleanupUnit] in
            guard home.confidence == .confirmed,
                  let definition = catalog.definitions.first(where: { $0.id == home.productID }),
                  definition.capabilities.cleanup else { return [] }
            return definition.artifacts.compactMap { rule in
                guard let cleanup = rule.cleanup else { return nil }
                let targetPath = URL(fileURLWithPath: home.path).appending(path: rule.relativePath).standardizedFileURL.path
                guard let root = artifacts.first(where: { $0.path == targetPath && $0.id.kind == .directory }),
                      root.homeIDs.contains(home.id) else { return nil }
                let members = artifacts.filter { artifact in
                    CanonicalPath.isEqualOrDescendant(artifact.path, of: targetPath) && artifact.homeIDs.contains(home.id)
                }
                let storage = StorageMeasurement(
                    logicalBytes: members.reduce(0) { $0 &+ $1.storage.logicalBytes },
                    physicalBytes: members.reduce(0) { $0 &+ $1.storage.physicalBytes },
                    itemCount: members.count
                )
                let latestModification = members.compactMap(\.modifiedAt).max()
                return CleanupUnit(
                    generation: snapshot.generation,
                    path: targetPath,
                    homePath: home.path,
                    identity: root.id,
                    homeIdentity: home.id,
                    name: URL(fileURLWithPath: targetPath).lastPathComponent,
                    category: rule.category,
                    storage: storage,
                    risk: cleanup.risk,
                    activity: activityProtection(homeID: home.id, activity: activity),
                    lastActivity: LastActivityEvidence(
                        date: latestModification,
                        kind: latestModification == nil ? .unknown : .contentMaximumModification
                    ),
                    method: cleanup.method
                )
            }
        }.sorted { $0.storage.physicalBytes > $1.storage.physicalBytes }
    }

    private func activityProtection(homeID: PhysicalResourceIdentity, activity: ActivitySnapshot?) -> ActivityProtection {
        guard let activity, activity.droppedEvidenceCount == 0 else { return .unknown }
        return activity.processes.contains { $0.homeID == homeID } ? .writerPresent : .inactive
    }
}
