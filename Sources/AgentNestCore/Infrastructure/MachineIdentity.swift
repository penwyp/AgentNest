import CryptoKit
import Foundation
import IOKit

public enum MachineIdentityError: Error {
    case platformExpertUnavailable
    case platformUUIDUnavailable
}

public struct MachineIdentityProvider: Sendable {
    public init() {}

    public func machineIDHash() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw MachineIdentityError.platformExpertUnavailable }
        defer { IOObjectRelease(service) }
        guard let rawValue = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            throw MachineIdentityError.platformUUIDUnavailable
        }
        return Self.hash(rawMachineIdentifier: rawValue)
    }

    public static func hash(rawMachineIdentifier: String) -> String {
        let input = Data("AgentNest.machine.v1\0\(rawMachineIdentifier)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
