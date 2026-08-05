import Foundation

public struct CleanupPolicy: Sendable {
    public init() {}

    public func filter(units: [CleanupUnit], query: CleanupQuery) -> [CleanupUnit] {
        units.filter { unit in
            if let minimum = query.minimumPhysicalBytes, unit.storage.physicalBytes < minimum { return false }
            if !query.risks.isEmpty, !query.risks.contains(unit.risk) { return false }
            if !query.categories.isEmpty, !query.categories.contains(unit.category) { return false }
            if let cutoff = query.inactiveBefore {
                guard unit.lastActivity.isReliableForAutomaticCleanup,
                      let date = unit.lastActivity.date,
                      date < cutoff else { return false }
            }
            if let range = query.activityRange {
                guard unit.lastActivity.isReliableForAutomaticCleanup,
                      let date = unit.lastActivity.date,
                      range.contains(date) else { return false }
            }
            return true
        }.sorted {
            if $0.storage.physicalBytes != $1.storage.physicalBytes { return $0.storage.physicalBytes > $1.storage.physicalBytes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func plan(generation: UUID, selected units: [CleanupUnit]) -> CleanupPlan {
        let eligible = units.filter {
            $0.generation == generation &&
            $0.risk != .protected &&
            $0.activity == .inactive
        }
        return CleanupPlan(generation: generation, units: eligible)
    }
}

public actor CleanupExecutor {
    private let adapters: CleanupAdapterRegistry

    public init(adapters: CleanupAdapterRegistry = .live()) {
        self.adapters = adapters
    }

    public func execute(
        _ plan: CleanupPlan,
        currentGeneration: UUID,
        currentActivity: ActivitySnapshot? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) async -> [CleanupResult] {
        guard plan.generation == currentGeneration else {
            return plan.units.map { CleanupResult(unitID: $0.id, status: .skipped, code: "cleanup.generationChanged") }
        }
        var results: [CleanupResult] = []
        for unit in plan.units {
            if isCancelled() {
                results.append(CleanupResult(unitID: unit.id, status: .cancelled, code: "cleanup.cancelled"))
                continue
            }
            guard unit.activity == .inactive, unit.risk != .protected else {
                results.append(CleanupResult(unitID: unit.id, status: .skipped, code: "cleanup.protected"))
                continue
            }
            let target = URL(fileURLWithPath: unit.path).standardizedFileURL
            do {
                let home = URL(fileURLWithPath: unit.homePath).resolvingSymlinksInPath().standardizedFileURL
                let homeMetadata = try FileMetadata.read(home).node
                guard homeMetadata.identity == unit.homeIdentity,
                      CanonicalPath.isDescendant(target.path, of: home.path) else {
                    results.append(CleanupResult(unitID: unit.id, status: .skipped, code: "cleanup.boundaryChanged"))
                    continue
                }
                let metadata = try FileMetadata.read(target).node
                guard metadata.identity == unit.identity, !metadata.isSymbolicLink else {
                    results.append(CleanupResult(unitID: unit.id, status: .skipped, code: "cleanup.targetChanged"))
                    continue
                }
                guard unit.members.allSatisfy({ member in
                    let url = URL(fileURLWithPath: member.path).standardizedFileURL
                    guard CanonicalPath.isEqualOrDescendant(url.path, of: home.path),
                          let current = try? FileMetadata.read(url).node else { return false }
                    return current.identity == member.identity && !current.isSymbolicLink
                }) else {
                    results.append(CleanupResult(unitID: unit.id, status: .skipped, code: "cleanup.familyChanged"))
                    continue
                }
                let currentProtection = CleanupActivityEvaluator.protection(
                    homeID: unit.homeIdentity,
                    memberPaths: unit.adapterID == nil ? [unit.path] : unit.members.map(\.path),
                    activity: currentActivity
                )
                guard currentProtection == .inactive else {
                    results.append(CleanupResult(unitID: unit.id, status: .skipped, code: "cleanup.activityChanged"))
                    continue
                }
                switch unit.method {
                case .trash:
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: target, resultingItemURL: &resultingURL)
                    results.append(CleanupResult(unitID: unit.id, status: .succeeded, code: "cleanup.trashed"))
                case .officialPermanentDelete:
                    guard let adapterID = unit.adapterID,
                          let adapter = adapters.adapter(id: adapterID) else {
                        results.append(CleanupResult(unitID: unit.id, status: .failed, code: "cleanup.officialExecutorUnavailable"))
                        continue
                    }
                    results.append(await adapter.execute(unit))
                }
            } catch {
                results.append(CleanupResult(unitID: unit.id, status: .failed, code: "cleanup.ioFailure"))
            }
        }
        return results
    }
}
