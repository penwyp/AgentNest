import Darwin
import Foundation

public struct DiskUtilityVolumeInfo: Equatable, Sendable {
    public let wholeDiskNames: [String]
    public let health: DeviceHealthState

    public init(wholeDiskNames: [String], health: DeviceHealthState) {
        self.wholeDiskNames = wholeDiskNames
        self.health = health
    }
}

public final class DiskUtilityProbe: @unchecked Sendable {
    private struct CacheEntry {
        let capturedAt: Date
        let info: DiskUtilityVolumeInfo
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private let cacheLifetime: TimeInterval

    public init(cacheLifetime: TimeInterval = 60) {
        self.cacheLifetime = cacheLifetime
    }

    public func info(mountPath: String, now: Date = Date()) -> DiskUtilityVolumeInfo {
        guard mountPath.hasPrefix("/"), !mountPath.contains("\0") else {
            return DiskUtilityVolumeInfo(wholeDiskNames: [], health: .unavailable)
        }
        lock.lock()
        if let cached = cache[mountPath], now.timeIntervalSince(cached.capturedAt) <= cacheLifetime {
            lock.unlock()
            return cached.info
        }
        lock.unlock()

        let result = runDiskUtility(mountPath: mountPath).flatMap(Self.parseInfo)
            ?? DiskUtilityVolumeInfo(wholeDiskNames: [], health: .unavailable)
        lock.lock()
        cache[mountPath] = CacheEntry(capturedAt: now, info: result)
        lock.unlock()
        return result
    }

    public static func parseInfo(data: Data) -> DiskUtilityVolumeInfo? {
        guard data.count <= 262_144,
              let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        var identifiers: [String] = []
        if let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]] {
            identifiers.append(contentsOf: stores.compactMap { $0["APFSPhysicalStore"] as? String })
        }
        if let parent = dictionary["ParentWholeDisk"] as? String {
            identifiers.append(parent)
        }
        let wholeDisks = Array(Set(identifiers.compactMap(wholeDiskName))).sorted()
        let health: DeviceHealthState
        if let status = dictionary["SMARTStatus"] as? String {
            switch status.lowercased() {
            case "verified": health = .verified
            case "failing", "fail": health = .failing
            case "not supported", "unsupported": health = .unsupported
            default: health = .unavailable
            }
        } else {
            health = .unsupported
        }
        return DiskUtilityVolumeInfo(wholeDiskNames: wholeDisks, health: health)
    }

    private static func wholeDiskName(_ input: String) -> String? {
        let value = input.replacingOccurrences(of: "/dev/", with: "")
        guard value.hasPrefix("disk") else { return nil }
        let suffix = value.dropFirst(4)
        let digits = suffix.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return "disk\(digits)"
    }

    private func runDiskUtility(mountPath: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", mountPath]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return data.count <= 262_144 ? data : nil
    }
}
