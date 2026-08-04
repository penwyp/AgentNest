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

        var indexes: [DirectoryIndex] = []
        let rootIndex = try await indexer.index(root: request.root) { path, count, bytes in
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

        let externalRoots = candidateExternalRoots(request: request)
            .filter { !isWithin($0, root: rootIndex.root) }
        for external in uniquePaths(externalRoots) where !rootIndex.isPartial && FileManager.default.fileExists(atPath: external.path) {
            if Task.isCancelled { break }
            let baseProcessedCount = processedCount
            let baseProcessedBytes = processedBytes
            let index = try await indexer.index(root: external) { path, count, bytes in
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
            let candidates = candidateHomes(definition: definition, request: request, indexes: indexes)
            for candidate in candidates {
                if Task.isCancelled { wasCancelled = true; break validationLoop }
                guard let home = try validate(
                    candidate: candidate,
                    definition: definition,
                    indexes: indexes
                ) else { continue }
                guard seenHomeIdentities.insert(home.id).inserted else { continue }
                homes.append(home)
            }
        }

        homes.sort {
            if $0.confidence != $1.confidence { return $0.confidence == .confirmed }
            if $0.storage.physicalBytes != $1.storage.physicalBytes {
                return $0.storage.physicalBytes > $1.storage.physicalBytes
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        await progress(ScanProgress(generation: generation, phase: .indexingSkills, discoveredCount: homes.count))
        await progress(ScanProgress(generation: generation, phase: .measuringSpace, discoveredCount: homes.count, processedBytes: processedBytes))

        let confirmed = homes.filter { $0.confidence == .confirmed }
        let totalStorage = reconcileStorage(homes: confirmed, indexes: indexes)
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
        await progress(ScanProgress(generation: generation, phase: .generatingFindings, discoveredCount: homes.count))
        await progress(ScanProgress(generation: generation, phase: .reconciling, discoveredCount: homes.count, processedBytes: totalStorage.physicalBytes))

        let isPartial = wasCancelled || unreadableCount > 0
        let directoryCoverage: CoverageState = isPartial ? .partial : .complete
        return DeviceSnapshot(
            generation: generation,
            createdAt: Date(),
            isPartial: isPartial,
            homes: homes,
            totalStorage: totalStorage,
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

    private func candidateExternalRoots(request: ScanRequest) -> [URL] {
        var roots = request.customLocations
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
        indexes: [DirectoryIndex]
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
        if definition.homeDiscovery.allowDeepDiscovery {
            for index in indexes {
                candidates.append(contentsOf: index.jsonAnchorParents.map { Candidate(url: $0, source: .deepScan) })
                candidates.append(contentsOf: index.suspiciousDirectoryPaths.map { Candidate(url: $0, source: .deepScan) })
            }
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let resolved = candidate.url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(resolved.path).inserted else { return nil }
            return Candidate(url: resolved, source: candidate.source)
        }
    }

    private func validate(
        candidate: Candidate,
        definition: AgentDefinition,
        indexes: [DirectoryIndex]
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
        if requiredValid && !negativeHit {
            confidence = .confirmed
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
            source: candidate.source,
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

    private func measurement(for home: URL, indexes: [DirectoryIndex]) -> StorageMeasurement {
        let prefix = home.standardizedFileURL.path + "/"
        var seen: Set<PhysicalResourceIdentity> = []
        var logical: UInt64 = 0
        var physical: UInt64 = 0
        for node in indexes.flatMap(\.nodes) where node.path == home.path || node.path.hasPrefix(prefix) {
            guard seen.insert(node.identity).inserted else { continue }
            logical &+= node.logicalBytes
            physical &+= node.physicalBytes
        }
        return StorageMeasurement(logicalBytes: logical, physicalBytes: physical, itemCount: seen.count)
    }

    private func reconcileStorage(homes: [AgentHome], indexes: [DirectoryIndex]) -> StorageMeasurement {
        var seen: Set<PhysicalResourceIdentity> = []
        var logical: UInt64 = 0
        var physical: UInt64 = 0
        let paths = homes.map { $0.path + "/" }
        for node in indexes.flatMap(\.nodes) {
            guard paths.contains(where: { node.path + "/" == $0 || node.path.hasPrefix($0) }),
                  seen.insert(node.identity).inserted else { continue }
            logical &+= node.logicalBytes
            physical &+= node.physicalBytes
        }
        return StorageMeasurement(logicalBytes: logical, physicalBytes: physical, itemCount: seen.count)
    }

    private func uniquePaths(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func isWithin(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
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

    public func snapshot() -> DeviceSnapshot? {
        publishedSnapshot
    }
}
