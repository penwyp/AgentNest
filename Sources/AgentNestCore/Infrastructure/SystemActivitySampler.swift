import Darwin
import Foundation
import IOKit
import IOKit.storage

public protocol ActivityCounterProvider: Sendable {
    func readCounters() throws -> CumulativeActivityCounters
}

public struct DarwinActivityCounterProvider: ActivityCounterProvider, Sendable {
    public init() {}

    public func readCounters() throws -> CumulativeActivityCounters {
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw POSIXError(.EIO) }
        let network = networkCounters()
        let disk = diskCounters()
        return CumulativeActivityCounters(
            userCPUTicks: UInt64(cpuInfo.cpu_ticks.0) &+ UInt64(cpuInfo.cpu_ticks.3),
            systemCPUTicks: UInt64(cpuInfo.cpu_ticks.1),
            idleCPUTicks: UInt64(cpuInfo.cpu_ticks.2),
            diskReadBytes: disk?.read,
            diskWriteBytes: disk?.written,
            networkReceiveBytes: network?.received,
            networkSendBytes: network?.sent
        )
    }

    private func diskCounters() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(kIOBlockStorageDriverClass),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var found = false
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let value = IORegistryEntryCreateCFProperty(
                service,
                kIOBlockStorageDriverStatisticsKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
                  let bytesRead = value[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber,
                  let bytesWritten = value[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber else { continue }
            read &+= bytesRead.uint64Value
            written &+= bytesWritten.uint64Value
            found = true
        }
        return found ? (read, written) : nil
    }

    private func networkCounters() -> (received: UInt64, sent: UInt64)? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = cursor {
            defer { cursor = address.pointee.ifa_next }
            guard let socketAddress = address.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK),
                  let rawData = address.pointee.ifa_data else { continue }
            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            received &+= UInt64(data.ifi_ibytes)
            sent &+= UInt64(data.ifi_obytes)
        }
        return (received, sent)
    }
}

public struct CumulativeProcessObservation: Sendable {
    public let identity: ProcessStartIdentity
    public let name: String
    public let executablePath: String?
    public let workingDirectoryPath: String?
    public let cpuNanoseconds: UInt64
    public let requestedReadBytes: UInt64
    public let requestedWriteBytes: UInt64

    public init(
        identity: ProcessStartIdentity,
        name: String,
        executablePath: String?,
        workingDirectoryPath: String? = nil,
        cpuNanoseconds: UInt64,
        requestedReadBytes: UInt64,
        requestedWriteBytes: UInt64
    ) {
        self.identity = identity
        self.name = name
        self.executablePath = executablePath
        self.workingDirectoryPath = workingDirectoryPath
        self.cpuNanoseconds = cpuNanoseconds
        self.requestedReadBytes = requestedReadBytes
        self.requestedWriteBytes = requestedWriteBytes
    }
}

public struct CumulativeDeviceObservation: Sendable {
    public let id: UInt64
    public let name: String
    public let bsdName: String?
    public let readBytes: UInt64
    public let writeBytes: UInt64

    public init(id: UInt64, name: String, bsdName: String? = nil, readBytes: UInt64, writeBytes: UInt64) {
        self.id = id
        self.name = name
        self.bsdName = bsdName
        self.readBytes = readBytes
        self.writeBytes = writeBytes
    }
}

public struct SystemActivityEvidence: Sendable {
    public let processes: [CumulativeProcessObservation]
    public let devices: [CumulativeDeviceObservation]
    public let volumes: [MountedVolume]
    public let droppedCount: Int

    public init(
        processes: [CumulativeProcessObservation],
        devices: [CumulativeDeviceObservation],
        volumes: [MountedVolume],
        droppedCount: Int
    ) {
        self.processes = processes
        self.devices = devices
        self.volumes = volumes
        self.droppedCount = droppedCount
    }
}

public protocol SystemActivityEvidenceProvider: Sendable {
    func readEvidence() -> SystemActivityEvidence
}

public protocol ProcessFileEvidenceProvider: Sendable {
    func currentlyOpenFiles(pid: Int32, maximumCount: Int) -> (paths: [String], droppedCount: Int)
}

public struct DarwinProcessFileEvidenceProvider: ProcessFileEvidenceProvider, Sendable {
    public init() {}

    public func currentlyOpenFiles(pid: Int32, maximumCount: Int) -> (paths: [String], droppedCount: Int) {
        let descriptorSize = MemoryLayout<proc_fdinfo>.size
        let requiredBytes = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard requiredBytes > 0 else { return ([], 0) }
        let requiredCount = requiredBytes / descriptorSize
        let capacity = min(requiredCount, max(maximumCount, 0))
        guard capacity > 0 else { return ([], requiredCount) }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let returnedBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedBytes > 0 else { return ([], requiredCount) }
        let returnedCount = min(Int(returnedBytes) / descriptorSize, descriptors.count)
        var paths: [String] = []
        for descriptor in descriptors.prefix(returnedCount) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let infoSize = MemoryLayout<vnode_fdinfowithpath>.size
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(infoSize)) == Int32(infoSize) else {
                continue
            }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { buffer -> String in
                let bytes = buffer.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            if path.hasPrefix("/") { paths.append(path) }
        }
        return (Array(Set(paths)).sorted(), max(0, requiredCount - capacity))
    }
}

public struct DarwinSystemActivityEvidenceProvider: SystemActivityEvidenceProvider, Sendable {
    private let maximumProcessCount = 4_096
    private let diskUtilityProbe = DiskUtilityProbe()

    public init() {}

    public func readEvidence() -> SystemActivityEvidence {
        let processResult = readProcesses()
        let devices = readDevices()
        return SystemActivityEvidence(
            processes: processResult.processes,
            devices: devices,
            volumes: readVolumes(devices: devices),
            droppedCount: processResult.dropped
        )
    }

    private func readProcesses() -> (processes: [CumulativeProcessObservation], dropped: Int) {
        let estimated = max(Int(proc_listallpids(nil, 0)), 0)
        var identifiers = [pid_t](repeating: 0, count: min(max(estimated + 256, 512), maximumProcessCount))
        let returned = identifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard returned > 0 else { return ([], 0) }
        let count = min(Int(returned), identifiers.count)
        var observations: [CumulativeProcessObservation] = []
        observations.reserveCapacity(count)
        var dropped = max(0, Int(returned) - identifiers.count)
        for pid in identifiers.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = MemoryLayout<proc_bsdinfo>.size
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(infoSize)) == Int32(infoSize) else {
                dropped += 1
                continue
            }
            var usage = rusage_info_v4()
            let usageResult = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard usageResult == 0 else { dropped += 1; continue }
            observations.append(CumulativeProcessObservation(
                identity: ProcessStartIdentity(
                    pid: pid,
                    startSeconds: UInt64(info.pbi_start_tvsec),
                    startMicroseconds: UInt64(info.pbi_start_tvusec)
                ),
                name: processName(pid: pid),
                executablePath: executablePath(pid: pid),
                workingDirectoryPath: workingDirectoryPath(pid: pid),
                cpuNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
                requestedReadBytes: usage.ri_diskio_bytesread,
                requestedWriteBytes: usage.ri_diskio_byteswritten
            ))
        }
        return (observations, dropped)
    }

    private func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "PID \(pid)" }
        return decodeCString(buffer)
    }

    private func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return decodeCString(buffer)
    }

    private func workingDirectoryPath(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let infoSize = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(infoSize)) == Int32(infoSize) else {
            return nil
        }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            let path = String(decoding: bytes, as: UTF8.self)
            return path.hasPrefix("/") ? path : nil
        }
    }

    private func decodeCString(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func readDevices() -> [CumulativeDeviceObservation] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(kIOBlockStorageDriverClass),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [CumulativeDeviceObservation] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
                  let statistics = IORegistryEntryCreateCFProperty(
                    service,
                    kIOBlockStorageDriverStatisticsKey as CFString,
                    kCFAllocatorDefault,
                    0
                  )?.takeRetainedValue() as? [String: Any],
                  let read = statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber,
                  let written = statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber else { continue }
            guard let bsdName = IORegistryEntrySearchCFProperty(
                service,
                kIOServicePlane,
                "BSD Name" as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively)
            ) as? String, !bsdName.isEmpty else { continue }
            let name = IORegistryEntryCreateCFProperty(
                service,
                kIOPropertyProductNameKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String ?? bsdName
            result.append(CumulativeDeviceObservation(
                id: registryID,
                name: name,
                bsdName: bsdName,
                readBytes: read.uint64Value,
                writeBytes: written.uint64Value
            ))
        }
        return result
    }

    private func readVolumes(devices: [CumulativeDeviceObservation]) -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRemovableKey
        ]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            var info = Darwin.stat()
            guard stat(url.path, &info) == 0 else { return nil }
            let diskInfo = values.volumeIsLocal == true
                ? diskUtilityProbe.info(mountPath: url.path)
                : DiskUtilityVolumeInfo(wholeDiskNames: [], health: .unsupported)
            let deviceIDs = devices.filter { device in
                device.bsdName.map { diskInfo.wholeDiskNames.contains($0) } == true
            }.map(\.id)
            return MountedVolume(
                id: VolumeIdentity(device: UInt64(info.st_dev), uuid: values.volumeUUIDString),
                name: values.volumeName ?? url.lastPathComponent,
                mountPath: url.path,
                totalBytes: values.volumeTotalCapacity.map(UInt64.init),
                availableBytes: values.volumeAvailableCapacity.map(UInt64.init),
                isLocal: values.volumeIsLocal,
                isWritable: values.volumeIsReadOnly.map { !$0 },
                isRemovable: values.volumeIsRemovable,
                physicalDeviceIDs: deviceIDs,
                health: diskInfo.health
            )
        }.sorted { $0.mountPath.localizedStandardCompare($1.mountPath) == .orderedAscending }
    }
}

public actor SystemActivitySampler {
    private let maximumVisibleProcessCount = 4_096
    private let provider: any ActivityCounterProvider
    private let evidenceProvider: any SystemActivityEvidenceProvider
    private let fileEvidenceProvider: any ProcessFileEvidenceProvider
    private var calculator = ActivityRateCalculator()
    private var previousEvidence: (time: TimeInterval, value: SystemActivityEvidence)?

    public init(
        provider: any ActivityCounterProvider = DarwinActivityCounterProvider(),
        evidenceProvider: any SystemActivityEvidenceProvider = DarwinSystemActivityEvidenceProvider(),
        fileEvidenceProvider: any ProcessFileEvidenceProvider = DarwinProcessFileEvidenceProvider()
    ) {
        self.provider = provider
        self.evidenceProvider = evidenceProvider
        self.fileEvidenceProvider = fileEvidenceProvider
    }

    public func sample(inventory: DeviceSnapshot? = nil) throws -> ActivitySnapshot {
        let monotonicTime = ProcessInfo.processInfo.systemUptime
        let counters = try provider.readCounters()
        let base = calculator.record(TimedActivityCounters(
            monotonicTime: monotonicTime,
            wallTime: Date(),
            counters: counters
        ))
        let evidence = evidenceProvider.readEvidence()
        let enriched = enrich(base, evidence: evidence, monotonicTime: monotonicTime, inventory: inventory)
        previousEvidence = (monotonicTime, evidence)
        return enriched
    }

    private func enrich(
        _ base: ActivitySnapshot,
        evidence: SystemActivityEvidence,
        monotonicTime: TimeInterval,
        inventory: DeviceSnapshot?
    ) -> ActivitySnapshot {
        let interval = previousEvidence.map { monotonicTime - $0.time } ?? 0
        let previousProcesses = Dictionary(uniqueKeysWithValues: (previousEvidence?.value.processes ?? []).map { ($0.identity, $0) })
        let previousDevices = Dictionary(uniqueKeysWithValues: (previousEvidence?.value.devices ?? []).map { ($0.id, $0) })
        let comparable = interval > 0 && interval <= 120
        let unavailable = MetricValue(value: nil, availability: .unavailable, observedSeconds: max(interval, 0), coverage: 0)

        var fileEvidenceDropped = max(0, evidence.processes.count - maximumVisibleProcessCount)
        let processes = evidence.processes.prefix(maximumVisibleProcessCount).map { process -> VisibleProcessActivity in
            let previous = previousProcesses[process.identity]
            let cpu: MetricValue
            let read: MetricValue
            let write: MetricValue
            if comparable, let previous,
               process.cpuNanoseconds >= previous.cpuNanoseconds,
               process.requestedReadBytes >= previous.requestedReadBytes,
               process.requestedWriteBytes >= previous.requestedWriteBytes {
                let capacity = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1)) * interval * 1_000_000_000
                cpu = MetricValue(
                    value: min(Double(process.cpuNanoseconds - previous.cpuNanoseconds) / capacity, 1),
                    availability: .available,
                    observedSeconds: interval,
                    coverage: 1
                )
                read = metricRate(process.requestedReadBytes, previous.requestedReadBytes, interval)
                write = metricRate(process.requestedWriteBytes, previous.requestedWriteBytes, interval)
            } else {
                cpu = unavailable
                read = unavailable
                write = unavailable
            }
            let attribution = attribute(process: process, inventory: inventory)
            let openFiles: [ProcessFileEvidence]
            if attribution.home != nil {
                let result = fileEvidenceProvider.currentlyOpenFiles(pid: process.identity.pid, maximumCount: 128)
                fileEvidenceDropped += result.droppedCount
                openFiles = result.paths.map {
                    ProcessFileEvidence(kind: .currentlyOpen, path: $0, observedAt: base.capturedAt)
                }
            } else {
                openFiles = []
            }
            return VisibleProcessActivity(
                id: process.identity,
                name: process.name,
                executablePath: process.executablePath,
                workingDirectoryPath: process.workingDirectoryPath,
                attribution: attribution.home == nil ? .other : .agent,
                productID: attribution.home?.productID,
                homeID: attribution.home?.id,
                evidence: attribution.evidence,
                cpuFraction: cpu,
                requestedReadBytesPerSecond: read,
                requestedWriteBytesPerSecond: write,
                currentlyOpenFiles: openFiles,
                recentChanges: []
            )
        }.sorted { ($0.cpuFraction.value ?? -1) > ($1.cpuFraction.value ?? -1) }

        let devices = evidence.devices.map { device in
            guard comparable, let previous = previousDevices[device.id] else {
                return PhysicalDeviceActivity(id: device.id, name: device.name, bsdName: device.bsdName, readBytesPerSecond: unavailable, writeBytesPerSecond: unavailable)
            }
            return PhysicalDeviceActivity(
                id: device.id,
                name: device.name,
                bsdName: device.bsdName,
                readBytesPerSecond: metricRate(device.readBytes, previous.readBytes, interval),
                writeBytesPerSecond: metricRate(device.writeBytes, previous.writeBytes, interval)
            )
        }
        return ActivitySnapshot(
            capturedAt: base.capturedAt,
            cpuFraction: base.cpuFraction,
            diskReadBytesPerSecond: base.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: base.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: base.networkReceiveBytesPerSecond,
            networkSendBytesPerSecond: base.networkSendBytesPerSecond,
            didResetBaseline: base.didResetBaseline,
            processes: processes,
            physicalDevices: devices,
            volumes: evidence.volumes,
            droppedEvidenceCount: evidence.droppedCount + fileEvidenceDropped
        )
    }

    private func metricRate(_ current: UInt64, _ previous: UInt64, _ interval: TimeInterval) -> MetricValue {
        guard current >= previous else {
            return MetricValue(value: nil, availability: .partial, observedSeconds: interval, coverage: 0)
        }
        return MetricValue(value: Double(current - previous) / interval, availability: .available, observedSeconds: interval, coverage: 1)
    }

    private func attribute(
        process: CumulativeProcessObservation,
        inventory: DeviceSnapshot?
    ) -> (home: AgentHome?, evidence: [String]) {
        guard let inventory else { return (nil, []) }
        if let workingDirectory = process.workingDirectoryPath {
            for product in inventory.products {
                if let home = product.homes.first(where: { CanonicalPath.isEqualOrDescendant(workingDirectory, of: $0.path) }) {
                    return (home, ["working-directory:\(workingDirectory)"])
                }
            }
        }
        guard let path = process.executablePath else { return (nil, []) }
        for product in inventory.products {
            if let installation = product.installations.first(where: { CanonicalPath.isEqualOrDescendant(path, of: $0.path) }) {
                let home = product.homes.first
                return (home, ["installation:\(installation.path)"])
            }
            if let home = product.homes.first(where: { CanonicalPath.isEqualOrDescendant(path, of: $0.path) }) {
                return (home, ["home:\(home.path)"])
            }
        }
        return (nil, [])
    }

}
