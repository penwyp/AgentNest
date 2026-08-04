import Foundation

public struct ScanUseCase: Sendable {
    private let catalog: AgentDefinitionCatalog
    private let indexer: FileIndexer

    public init(catalog: AgentDefinitionCatalog, indexer: FileIndexer = FileIndexer()) {
        self.catalog = catalog
        self.indexer = indexer
    }

    public func execute(
        request: ScanRequest,
        generation: UUID = UUID(),
        progress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }
    ) async throws -> DeviceSnapshot {
        var processedCount = 0
        var processedBytes: UInt64 = 0
        await progress(ScanProgress(generation: generation, phase: .discoveringAgents))
        let ignoredLocations = request.ignoredLocations.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        var userConfirmedHomes: [String: String] = [:]
        for (path, productID) in request.userConfirmedHomes {
            userConfirmedHomes[URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path] = productID
        }

        var indexes: [DirectoryIndex] = []
        let rootIndex = try await indexer.index(root: request.root, ignoredLocations: ignoredLocations) { path, count, bytes in
            await progress(ScanProgress(
                generation: generation,
                phase: .discoveringAgents,
                currentLocation: path,
                discoveredCount: count,
                processedCount: count,
                processedBytes: bytes
            ))
        }
        indexes.append(rootIndex)
        processedCount += rootIndex.nodes.count
        processedBytes &+= rootIndex.nodes.reduce(0) { $0 &+ $1.physicalBytes }

        let externalRoots = candidateExternalRoots(request: request, userConfirmedHomes: userConfirmedHomes)
            .filter { !isWithin($0, root: rootIndex.root) && !isIgnored($0, ignoredLocations: ignoredLocations) }
        for external in uniquePaths(externalRoots) where !rootIndex.isPartial && FileManager.default.fileExists(atPath: external.path) {
            if Task.isCancelled { break }
            let baseProcessedCount = processedCount
            let baseProcessedBytes = processedBytes
            let index = try await indexer.index(root: external, ignoredLocations: ignoredLocations) { path, count, bytes in
                await progress(ScanProgress(
                    generation: generation,
                    phase: .discoveringAgents,
                    currentLocation: path,
                    discoveredCount: baseProcessedCount + count,
                    processedCount: baseProcessedCount + count,
                    processedBytes: baseProcessedBytes &+ bytes
                ))
            }
            indexes.append(index)
            processedCount += index.nodes.count
            processedBytes &+= index.nodes.reduce(0) { $0 &+ $1.physicalBytes }
        }

        await progress(ScanProgress(
            generation: generation,
            phase: .validatingHomes,
            discoveredCount: processedCount,
            processedCount: processedCount,
            processedBytes: processedBytes
        ))

        var homes: [AgentHome] = []
        var seenHomeIdentities: Set<PhysicalResourceIdentity> = []
        var wasCancelled = indexes.contains(where: \.isPartial) || Task.isCancelled
        let scanningDefinitions = catalog.definitions.filter(\.participatesInScanning)
        validationLoop:
        for definition in scanningDefinitions {
            let candidates = candidateHomes(
                definition: definition,
                request: request,
                indexes: indexes,
                userConfirmedHomes: userConfirmedHomes,
                ignoredLocations: ignoredLocations
            )
            for candidate in candidates {
                if Task.isCancelled { wasCancelled = true; break validationLoop }
                guard let home = try validate(
                    candidate: candidate,
                    definition: definition,
                    indexes: indexes,
                    userConfirmedHomes: userConfirmedHomes
                ) else { continue }
                guard seenHomeIdentities.insert(home.id).inserted else { continue }
                homes.append(home)
            }
        }

        let unstablePaths = detectUnstablePaths(in: indexes)
        homes = reconcileHomes(homes, definitions: scanningDefinitions, indexes: indexes, unstablePaths: unstablePaths)
        homes.sort {
            if $0.confidence != $1.confidence { return $0.confidence == .confirmed }
            if $0.storage.physicalBytes != $1.storage.physicalBytes {
                return $0.storage.physicalBytes > $1.storage.physicalBytes
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        await progress(ScanProgress(generation: generation, phase: .indexingSkills, discoveredCount: homes.count))
        await progress(ScanProgress(generation: generation, phase: .measuringSpace, discoveredCount: homes.count, processedBytes: processedBytes))

        let products = buildProducts(homes: homes, definitions: scanningDefinitions)
        let storageLedger = buildStorageLedger(
            homes: homes.filter { $0.confidence == .confirmed },
            definitions: scanningDefinitions,
            indexes: indexes,
            unstablePaths: unstablePaths
        )
        var findings = homes.filter { $0.confidence == .possible }.map {
            Finding(code: "finding.agent.possible", severity: .warning, arguments: [$0.path])
        }
        let unreadableCount = indexes.reduce(0) { $0 + $1.unreadablePaths.count }
        if unreadableCount > 0 {
            findings.append(Finding(
                code: "finding.scan.unreadable",
                severity: .warning,
                arguments: [String(unreadableCount)]
            ))
        }
        if !unstablePaths.isEmpty {
            findings.append(Finding(
                code: "finding.scan.unstable",
                severity: .warning,
                arguments: [String(unstablePaths.count)]
            ))
        }
        await progress(ScanProgress(generation: generation, phase: .generatingFindings, discoveredCount: homes.count))
        await progress(ScanProgress(generation: generation, phase: .reconciling, discoveredCount: homes.count, processedBytes: storageLedger.total.physicalBytes))

        let isPartial = wasCancelled || unreadableCount > 0 || !unstablePaths.isEmpty
        let directoryCoverage: CoverageState = isPartial ? .partial : .complete
        return DeviceSnapshot(
            generation: generation,
            createdAt: Date(),
            isPartial: isPartial,
            products: products,
            storageLedger: storageLedger,
            coverage: SnapshotCoverage(
                directories: directoryCoverage,
                agents: directoryCoverage,
                space: directoryCoverage,
                skills: .unavailable,
                activity: .unavailable,
                unreadableLocationCount: unreadableCount
            ),
            findings: findings
        )
    }

    private struct Candidate {
        let url: URL
        let source: DiscoverySource
    }

    private func candidateExternalRoots(request: ScanRequest, userConfirmedHomes: [String: String]) -> [URL] {
        var roots = request.customLocations
        roots.append(contentsOf: userConfirmedHomes.keys.map { URL(fileURLWithPath: $0, isDirectory: true) })
        for definition in catalog.definitions where definition.participatesInScanning {
            for variable in definition.homeDiscovery.environmentVariables {
                if let value = request.environment[variable], !value.isEmpty {
                    roots.append(URL(fileURLWithPath: value))
                }
            }
        }
        return roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    private func candidateHomes(
        definition: AgentDefinition,
        request: ScanRequest,
        indexes: [DirectoryIndex],
        userConfirmedHomes: [String: String],
        ignoredLocations: [URL]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for rawPath in definition.homeDiscovery.defaultPaths {
            let path = rawPath == "~" ? request.root.path : rawPath.replacingOccurrences(of: "~/", with: request.root.path + "/")
            candidates.append(Candidate(url: URL(fileURLWithPath: path), source: .defaultPath))
        }
        for variable in definition.homeDiscovery.environmentVariables {
            if let value = request.environment[variable], !value.isEmpty {
                candidates.append(Candidate(url: URL(fileURLWithPath: value), source: .environment))
            }
        }
        candidates.append(contentsOf: request.customLocations.map { Candidate(url: $0, source: .custom) })
        candidates.append(contentsOf: userConfirmedHomes.compactMap { path, productID in
            productID == definition.id ? Candidate(url: URL(fileURLWithPath: path), source: .userConfirmed) : nil
        })
        if definition.homeDiscovery.allowDeepDiscovery {
            for index in indexes {
                candidates.append(contentsOf: index.jsonAnchorParents.map { Candidate(url: $0, source: .deepScan) })
                candidates.append(contentsOf: index.suspiciousDirectoryPaths.map { Candidate(url: $0, source: .deepScan) })
            }
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let resolved = candidate.url.resolvingSymlinksInPath().standardizedFileURL
            guard !isIgnored(resolved, ignoredLocations: ignoredLocations), seen.insert(resolved.path).inserted else { return nil }
            return Candidate(url: resolved, source: candidate.source)
        }
    }

    private func validate(
        candidate: Candidate,
        definition: AgentDefinition,
        indexes: [DirectoryIndex],
        userConfirmedHomes: [String: String]
    ) throws -> AgentHome? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let metadata = try FileMetadata.read(candidate.url).node
        var evidence: [String] = []
        var requiredValid = true
        for rule in definition.fingerprints.required {
            let target = candidate.url.appending(path: rule.relativePath)
            let valid = validateFingerprint(rule, at: target)
            requiredValid = requiredValid && valid
            if valid { evidence.append("required:\(rule.kind.rawValue):\(rule.relativePath)") }
        }
        let negativeHit = definition.fingerprints.negative.contains { rule in
            validateFingerprint(rule, at: candidate.url.appending(path: rule.relativePath))
        }
        let confidence: AgentHomeConfidence
        let isUserConfirmed = userConfirmedHomes[candidate.url.path] == definition.id
        if (requiredValid || isUserConfirmed) && !negativeHit {
            confidence = .confirmed
            if isUserConfirmed { evidence.append("user-confirmed:\(definition.id)") }
        } else if candidate.url.lastPathComponent.lowercased() == ".codex" && definition.id == "openai.codex" {
            confidence = .possible
            evidence.append("name:.codex")
        } else {
            return nil
        }
        return AgentHome(
            id: metadata.identity,
            productID: definition.id,
            displayName: definition.displayName,
            path: candidate.url.path,
            source: isUserConfirmed ? .userConfirmed : candidate.source,
            confidence: confidence,
            evidence: evidence,
            storage: measurement(for: candidate.url, indexes: indexes)
        )
    }

    private func validateFingerprint(_ rule: FingerprintRule, at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        switch rule.kind {
        case .file:
            return !isDirectory.boolValue
        case .directory:
            return isDirectory.boolValue
        case .jsonFile:
            guard !isDirectory.boolValue,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= 1_048_576,
                  let object = try? JSONSerialization.jsonObject(with: data) else { return false }
            return object is [String: Any]
        }
    }

    private func measurement(
        for home: URL,
        indexes: [DirectoryIndex],
        excluding excludedPaths: Set<String> = []
    ) -> StorageMeasurement {
        let prefix = home.standardizedFileURL.path + "/"
        var seen: Set<PhysicalResourceIdentity> = []
        var logical: UInt64 = 0
        var physical: UInt64 = 0
        for node in indexes.flatMap(\.nodes)
        where (node.path == home.path || node.path.hasPrefix(prefix)) && !excludedPaths.contains(node.path) {
            guard seen.insert(node.identity).inserted else { continue }
            logical &+= node.logicalBytes
            physical &+= node.physicalBytes
        }
        return StorageMeasurement(logicalBytes: logical, physicalBytes: physical, itemCount: seen.count)
    }

    private func buildProducts(homes: [AgentHome], definitions: [AgentDefinition]) -> [AgentProduct] {
        definitions.compactMap { definition in
            let productHomes = homes.filter { $0.productID == definition.id }
            guard !productHomes.isEmpty else { return nil }
            return AgentProduct(
                id: definition.id,
                displayName: definition.displayName,
                definitionVersion: definition.schemaVersion,
                supportState: definition.capabilities.space ? .supported : .detectable,
                capabilities: definition.capabilities,
                installations: [],
                homes: productHomes,
                profiles: []
            )
        }
    }

    private func buildStorageLedger(
        homes: [AgentHome],
        definitions: [AgentDefinition],
        indexes: [DirectoryIndex],
        unstablePaths: Set<String>
    ) -> StorageLedger {
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        var nodesByIdentity: [PhysicalResourceIdentity: IndexedNode] = [:]
        for node in indexes.flatMap(\.nodes) where !unstablePaths.contains(node.path) && nodesByIdentity[node.identity] == nil {
            nodesByIdentity[node.identity] = node
        }

        let artifacts = nodesByIdentity.values.compactMap { node -> ArtifactRecord? in
            let owners = homes.filter { CanonicalPath.isEqualOrDescendant(node.path, of: $0.path) }
            guard !owners.isEmpty else { return nil }
            let sortedOwners = owners.sorted { $0.path < $1.path }
            let classification = classifyArtifact(
                path: node.path,
                owners: sortedOwners,
                definitionsByID: definitionsByID
            )
            return ArtifactRecord(
                id: node.identity,
                path: node.path,
                category: classification.category,
                attribution: sortedOwners.count > 1 ? .shared : .home,
                homeIDs: sortedOwners.map(\.id),
                storage: StorageMeasurement(
                    logicalBytes: node.logicalBytes,
                    physicalBytes: node.physicalBytes,
                    itemCount: 1
                ),
                evidence: classification.evidence,
                modifiedAt: node.modifiedAt
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return StorageLedger(artifacts: artifacts)
    }

    private func classifyArtifact(
        path: String,
        owners: [AgentHome],
        definitionsByID: [String: AgentDefinition]
    ) -> (category: ArtifactCategory, evidence: [String]) {
        for owner in owners.sorted(by: { $0.path.count > $1.path.count }) {
            guard let definition = definitionsByID[owner.productID] else { continue }
            for rule in definition.artifacts {
                let target = URL(fileURLWithPath: owner.path)
                    .appending(path: rule.relativePath)
                    .standardizedFileURL.path
                if CanonicalPath.isEqualOrDescendant(path, of: target) {
                    return (
                        ArtifactCategory(definitionValue: rule.category),
                        ["definition:\(definition.id):\(rule.relativePath)"]
                    )
                }
            }
        }
        return (.unattributed, [])
    }

    private func detectUnstablePaths(in indexes: [DirectoryIndex]) -> Set<String> {
        Set(indexes.flatMap(\.nodes).compactMap { indexed in
            guard let current = try? FileMetadata.read(URL(fileURLWithPath: indexed.path)).node,
                  current.identity == indexed.identity,
                  current.logicalBytes == indexed.logicalBytes,
                  current.modifiedAt == indexed.modifiedAt else {
                return indexed.path
            }
            return nil
        })
    }

    private func reconcileHomes(
        _ homes: [AgentHome],
        definitions: [AgentDefinition],
        indexes: [DirectoryIndex],
        unstablePaths: Set<String>
    ) -> [AgentHome] {
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        return homes.map { home in
            let requiredPaths = definitionsByID[home.productID]?.fingerprints.required.map {
                URL(fileURLWithPath: home.path).appending(path: $0.relativePath).standardizedFileURL.path
            } ?? []
            let unstableEvidence = ([home.path] + requiredPaths).filter { unstablePaths.contains($0) }
            let confidence: AgentHomeConfidence = home.confidence == .confirmed && !unstableEvidence.isEmpty
                ? .possible
                : home.confidence
            let stableMeasurement = measurement(for: URL(fileURLWithPath: home.path), indexes: indexes, excluding: unstablePaths)
            return AgentHome(
                id: home.id,
                productID: home.productID,
                displayName: home.displayName,
                path: home.path,
                source: home.source,
                confidence: confidence,
                evidence: home.evidence + unstableEvidence.map { "unstable:\($0)" },
                storage: stableMeasurement
            )
        }
    }

    private func uniquePaths(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func isWithin(_ url: URL, root: URL) -> Bool {
        CanonicalPath.isEqualOrDescendant(url.path, of: root.path)
    }

    private func isIgnored(_ url: URL, ignoredLocations: [URL]) -> Bool {
        ignoredLocations.contains { CanonicalPath.isEqualOrDescendant(url.path, of: $0.path) }
    }
}

public actor ScanCoordinator {
    private let useCase: ScanUseCase
    private var currentTask: Task<DeviceSnapshot, Error>?
    private var currentGeneration: UUID?
    private var publishedSnapshot: DeviceSnapshot?

    public init(useCase: ScanUseCase) {
        self.useCase = useCase
    }

    public func scan(
        request: ScanRequest,
        progress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }
    ) async throws -> DeviceSnapshot {
        currentTask?.cancel()
        let generation = UUID()
        currentGeneration = generation
        let task = Task { try await useCase.execute(request: request, generation: generation, progress: progress) }
        currentTask = task
        let snapshot = try await task.value
        guard currentGeneration == generation else { throw CancellationError() }
        publishedSnapshot = snapshot
        currentTask = nil
        return snapshot
    }

    public func cancel() {
        currentTask?.cancel()
    }

    public func rescanHome(
        at homePath: String,
        baseline: DeviceSnapshot,
        request: ScanRequest,
        progress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }
    ) async throws -> DeviceSnapshot {
        currentTask?.cancel()
        let generation = UUID()
        currentGeneration = generation
        let task = Task {
            let replacement = try await useCase.execute(request: request, generation: generation, progress: progress)
            return try SnapshotReconciler().replacingHome(at: homePath, in: baseline, with: replacement)
        }
        currentTask = task
        let snapshot = try await task.value
        guard currentGeneration == generation else { throw CancellationError() }
        publishedSnapshot = snapshot
        currentTask = nil
        return snapshot
    }

    public func snapshot() -> DeviceSnapshot? {
        publishedSnapshot
    }
}
