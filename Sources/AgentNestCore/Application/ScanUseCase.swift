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
        try Task.checkCancellation()
        var processedCount = 0
        var processedBytes: UInt64 = 0
        await progress(ScanProgress(generation: generation, phase: .discoveringAgents))
        try Task.checkCancellation()
        let ignoredLocations = request.ignoredLocations.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        var userConfirmedHomes: [String: String] = [:]
        for (path, productID) in request.userConfirmedHomes {
            userConfirmedHomes[URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path] = productID
        }

        let scanningDefinitions = catalog.definitions.filter(\.participatesInScanning)
        let candidateCount = scanningDefinitions.reduce(0) { count, definition in
            count + candidateHomes(
                definition: definition,
                request: request,
                userConfirmedHomes: userConfirmedHomes,
                ignoredLocations: ignoredLocations
            ).count
        }
        await progress(ScanProgress(generation: generation, phase: .validatingHomes, discoveredCount: candidateCount))
        try Task.checkCancellation()

        var homes: [AgentHome] = []
        var seenHomeIdentities: Set<PhysicalResourceIdentity> = []
        for definition in scanningDefinitions {
            let candidates = candidateHomes(
                definition: definition,
                request: request,
                userConfirmedHomes: userConfirmedHomes,
                ignoredLocations: ignoredLocations
            )
            for candidate in candidates {
                try Task.checkCancellation()
                guard let home = try validate(
                    candidate: candidate,
                    definition: definition,
                    userConfirmedHomes: userConfirmedHomes
                ) else { continue }
                guard seenHomeIdentities.insert(home.id).inserted else { continue }
                homes.append(home)
                // 渐进发现：每验证一个 Home 立即发布，界面逐个确认展示。
                await progress(ScanProgress(
                    generation: generation,
                    phase: .validatingHomes,
                    discoveredCount: candidateCount,
                    confirmedHomes: homes
                ))
            }
        }

        let confirmedRoots = homes
            .filter { $0.confidence == .confirmed }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        await progress(ScanProgress(generation: generation, phase: .indexingSkills, discoveredCount: confirmedRoots.count, confirmedHomes: homes))
        try Task.checkCancellation()

        var indexes: [DirectoryIndex] = []
        let confirmedHomesAtIndexing = homes
        for root in confirmedRoots {
            try Task.checkCancellation()
            let baseProcessedCount = processedCount
            let baseProcessedBytes = processedBytes
            let index = try await indexer.index(root: root, ignoredLocations: ignoredLocations) { path, count, bytes in
                await progress(ScanProgress(
                    generation: generation,
                    phase: .indexingSkills,
                    currentLocation: path,
                    discoveredCount: confirmedRoots.count,
                    processedCount: baseProcessedCount + count,
                    processedBytes: baseProcessedBytes &+ bytes,
                    confirmedHomes: confirmedHomesAtIndexing
                ))
            }
            indexes.append(index)
            processedCount += index.nodes.count
            processedBytes &+= index.nodes.reduce(0) { $0 &+ $1.physicalBytes }
        }

        await progress(ScanProgress(
            generation: generation,
            phase: .measuringSpace,
            discoveredCount: homes.count,
            processedCount: processedCount,
            processedBytes: processedBytes,
            confirmedHomes: homes
        ))
        try Task.checkCancellation()
        let unstablePaths = detectUnstablePaths(in: indexes)
        homes = reconcileHomes(homes, definitions: scanningDefinitions, indexes: indexes, unstablePaths: unstablePaths)
        homes.sort {
            if $0.confidence != $1.confidence { return $0.confidence == .confirmed }
            if $0.storage.physicalBytes != $1.storage.physicalBytes {
                return $0.storage.physicalBytes > $1.storage.physicalBytes
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

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
        await progress(ScanProgress(generation: generation, phase: .generatingFindings, discoveredCount: homes.count, confirmedHomes: homes))
        try Task.checkCancellation()
        await progress(ScanProgress(generation: generation, phase: .reconciling, discoveredCount: homes.count, processedBytes: storageLedger.total.physicalBytes, confirmedHomes: homes))
        try Task.checkCancellation()

        let isPartial = unreadableCount > 0 || !unstablePaths.isEmpty
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

    private func candidateHomes(
        definition: AgentDefinition,
        request: ScanRequest,
        userConfirmedHomes: [String: String],
        ignoredLocations: [URL]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for rawPath in definition.homeDiscovery.defaultPaths {
            candidates.append(contentsOf: expandDefaultPath(rawPath, homeDirectory: request.homeDirectory).map {
                Candidate(url: $0, source: .defaultPath)
            })
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
        userConfirmedHomes: [String: String]
    ) throws -> AgentHome? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let metadata = try FileMetadata.read(candidate.url).node
        var evidence: [String] = []
        var requiredValid = !definition.fingerprints.required.isEmpty
        for rule in definition.fingerprints.required {
            let target = candidate.url.appending(path: rule.relativePath)
            let valid = validateFingerprint(rule, at: target)
            requiredValid = requiredValid && valid
            if valid { evidence.append("required:\(rule.kind.rawValue):\(rule.relativePath)") }
        }
        for rule in definition.fingerprints.optional where validateFingerprint(rule, at: candidate.url.appending(path: rule.relativePath)) {
            evidence.append("optional:\(rule.kind.rawValue):\(rule.relativePath)")
        }
        let negativeHit = definition.fingerprints.negative.contains { rule in
            validateFingerprint(rule, at: candidate.url.appending(path: rule.relativePath))
        }
        let confidence: AgentHomeConfidence
        let isUserConfirmed = userConfirmedHomes[candidate.url.path] == definition.id
        let isDeclaredFingerprintlessHome = definition.fingerprints.required.isEmpty &&
            (candidate.source == .defaultPath || candidate.source == .environment)
        if (requiredValid || isDeclaredFingerprintlessHome || isUserConfirmed) && !negativeHit {
            confidence = .confirmed
            if isUserConfirmed { evidence.append("user-confirmed:\(definition.id)") }
        } else if candidate.source == .defaultPath && !negativeHit {
            confidence = .possible
            evidence.append("declared-default:\(candidate.url.lastPathComponent)")
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
            storage: StorageMeasurement(logicalBytes: 0, physicalBytes: 0, itemCount: 0)
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

    private func expandDefaultPath(_ rawPath: String, homeDirectory: URL) -> [URL] {
        if rawPath == "~" { return [homeDirectory] }
        let relativePath = String(rawPath.dropFirst(2))
        guard relativePath.contains("*") else {
            return [homeDirectory.appending(path: relativePath)]
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let pattern = components.last else { return [] }
        let parentRelativePath = components.dropLast().joined(separator: "/")
        let parent = parentRelativePath.isEmpty ? homeDirectory : homeDirectory.appending(path: parentRelativePath)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }
        return children.filter { wildcardMatch($0.lastPathComponent, pattern: pattern) }
    }

    private func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let value = Array(value)
        let pattern = Array(pattern)
        var valueIndex = 0
        var patternIndex = 0
        var starIndex: Int?
        var retryValueIndex = 0

        while valueIndex < value.count {
            if patternIndex < pattern.count, pattern[patternIndex] == value[valueIndex] {
                valueIndex += 1
                patternIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                patternIndex += 1
                retryValueIndex = valueIndex
            } else if let starIndex {
                retryValueIndex += 1
                valueIndex = retryValueIndex
                patternIndex = starIndex + 1
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" { patternIndex += 1 }
        return patternIndex == pattern.count
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
        do {
            let snapshot = try await task.value
            guard currentGeneration == generation else { throw CancellationError() }
            publishedSnapshot = snapshot
            currentTask = nil
            return snapshot
        } catch {
            if currentGeneration == generation { currentTask = nil }
            throw error
        }
    }

    public func cancel() {
        currentGeneration = nil
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
        do {
            let snapshot = try await task.value
            guard currentGeneration == generation else { throw CancellationError() }
            publishedSnapshot = snapshot
            currentTask = nil
            return snapshot
        } catch {
            if currentGeneration == generation { currentTask = nil }
            throw error
        }
    }

    public func snapshot() -> DeviceSnapshot? {
        publishedSnapshot
    }
}
