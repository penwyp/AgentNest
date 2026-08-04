import Foundation

public enum SnapshotReconcileError: Error, Sendable {
    case homeMissing
}

public struct SnapshotReconciler: Sendable {
    public init() {}

    public func replacingHome(
        at homePath: String,
        in baseline: DeviceSnapshot,
        with replacement: DeviceSnapshot
    ) throws -> DeviceSnapshot {
        let affectedHomes = baseline.homes.filter { $0.path == homePath }
        guard !affectedHomes.isEmpty else { throw SnapshotReconcileError.homeMissing }
        let affectedHomeIDs = Set(affectedHomes.map(\.id))

        var productsByID: [String: AgentProduct] = [:]
        for product in baseline.products {
            let homes = product.homes.filter { !affectedHomeIDs.contains($0.id) }
            let validHomeIDs = Set(homes.map(\.id))
            productsByID[product.id] = AgentProduct(
                id: product.id,
                displayName: product.displayName,
                definitionVersion: product.definitionVersion,
                supportState: product.supportState,
                capabilities: product.capabilities,
                installations: product.installations,
                homes: homes,
                profiles: product.profiles.filter { validHomeIDs.contains($0.homeID) }
            )
        }
        for product in replacement.products {
            if let existing = productsByID[product.id] {
                let homes = unique(existing.homes + product.homes, by: \.id)
                let validHomeIDs = Set(homes.map(\.id))
                productsByID[product.id] = AgentProduct(
                    id: product.id,
                    displayName: product.displayName,
                    definitionVersion: product.definitionVersion,
                    supportState: product.supportState,
                    capabilities: product.capabilities,
                    installations: unique(existing.installations + product.installations, by: \.id),
                    homes: homes,
                    profiles: unique(existing.profiles + product.profiles, by: \.id).filter { validHomeIDs.contains($0.homeID) }
                )
            } else {
                productsByID[product.id] = product
            }
        }

        var artifactsByID: [PhysicalResourceIdentity: ArtifactRecord] = [:]
        for artifact in baseline.storageLedger.artifacts {
            let remainingHomeIDs = artifact.homeIDs.filter { !affectedHomeIDs.contains($0) }
            guard !remainingHomeIDs.isEmpty else { continue }
            artifactsByID[artifact.id] = copy(artifact, homeIDs: remainingHomeIDs)
        }
        for artifact in replacement.storageLedger.artifacts {
            if let existing = artifactsByID[artifact.id] {
                let homeIDs = unique(existing.homeIDs + artifact.homeIDs)
                let profileIDs = unique(existing.profileIDs + artifact.profileIDs)
                artifactsByID[artifact.id] = ArtifactRecord(
                    id: artifact.id,
                    path: artifact.path,
                    category: artifact.category,
                    attribution: homeIDs.count > 1 ? .shared : .home,
                    homeIDs: homeIDs,
                    profileIDs: profileIDs,
                    storage: artifact.storage,
                    evidence: unique(existing.evidence + artifact.evidence),
                    modifiedAt: artifact.modifiedAt
                )
            } else {
                artifactsByID[artifact.id] = artifact
            }
        }

        let findings = baseline.findings.filter { finding in
            !finding.arguments.contains { CanonicalPath.isEqualOrDescendant($0, of: homePath) }
        } + replacement.findings
        return DeviceSnapshot(
            generation: replacement.generation,
            createdAt: replacement.createdAt,
            isPartial: baseline.isPartial || replacement.isPartial,
            products: productsByID.values.filter { !$0.homes.isEmpty }.sorted { $0.id < $1.id },
            storageLedger: StorageLedger(artifacts: artifactsByID.values.sorted { $0.path < $1.path }),
            coverage: SnapshotCoverage(
                directories: worst(baseline.coverage.directories, replacement.coverage.directories),
                agents: worst(baseline.coverage.agents, replacement.coverage.agents),
                space: worst(baseline.coverage.space, replacement.coverage.space),
                skills: worst(baseline.coverage.skills, replacement.coverage.skills),
                activity: worst(baseline.coverage.activity, replacement.coverage.activity),
                unreadableLocationCount: baseline.coverage.unreadableLocationCount + replacement.coverage.unreadableLocationCount
            ),
            findings: findings
        )
    }

    private func copy(_ artifact: ArtifactRecord, homeIDs: [PhysicalResourceIdentity]) -> ArtifactRecord {
        ArtifactRecord(
            id: artifact.id,
            path: artifact.path,
            category: artifact.category,
            attribution: homeIDs.count > 1 ? .shared : .home,
            homeIDs: homeIDs,
            profileIDs: artifact.profileIDs,
            storage: artifact.storage,
            evidence: artifact.evidence,
            modifiedAt: artifact.modifiedAt
        )
    }

    private func worst(_ lhs: CoverageState, _ rhs: CoverageState) -> CoverageState {
        let rank: [CoverageState: Int] = [.complete: 0, .partial: 1, .unavailable: 2]
        return (rank[lhs] ?? 2) >= (rank[rhs] ?? 2) ? lhs : rhs
    }

    private func unique<Value, Key: Hashable>(_ values: [Value], by keyPath: KeyPath<Value, Key>) -> [Value] {
        var seen: Set<Key> = []
        return values.filter { seen.insert($0[keyPath: keyPath]).inserted }
    }

    private func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }
}
