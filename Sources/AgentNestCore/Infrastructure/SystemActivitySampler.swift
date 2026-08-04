import Darwin
import Foundation

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
        return CumulativeActivityCounters(
            userCPUTicks: UInt64(cpuInfo.cpu_ticks.0) &+ UInt64(cpuInfo.cpu_ticks.3),
            systemCPUTicks: UInt64(cpuInfo.cpu_ticks.1),
            idleCPUTicks: UInt64(cpuInfo.cpu_ticks.2),
            diskReadBytes: nil,
            diskWriteBytes: nil,
            networkReceiveBytes: network?.received,
            networkSendBytes: network?.sent
        )
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

public actor SystemActivitySampler {
    private let provider: any ActivityCounterProvider
    private var calculator = ActivityRateCalculator()

    public init(provider: any ActivityCounterProvider = DarwinActivityCounterProvider()) {
        self.provider = provider
    }

    public func sample() throws -> ActivitySnapshot {
        let counters = try provider.readCounters()
        return calculator.record(TimedActivityCounters(
            monotonicTime: ProcessInfo.processInfo.systemUptime,
            wallTime: Date(),
            counters: counters
        ))
    }
}
