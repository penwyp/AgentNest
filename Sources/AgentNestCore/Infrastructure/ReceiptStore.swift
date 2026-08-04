import Foundation

public struct ReceiptStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AgentNest/License/entitlement.receipt")
    }

    public func load() throws -> SignedEntitlementReceipt? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let metadata = try FileMetadata.read(fileURL).node
        guard metadata.identity.kind == .file, !metadata.isSymbolicLink, metadata.logicalBytes <= 65_536 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return try JSONDecoder().decode(SignedEntitlementReceipt.self, from: data)
    }

    public func save(_ receipt: SignedEntitlementReceipt) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryMetadata = try FileMetadata.read(directory).node
        guard directoryMetadata.identity.kind == .directory, !directoryMetadata.isSymbolicLink else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let existing = try FileMetadata.read(fileURL).node
            guard existing.identity.kind == .file, !existing.isSymbolicLink else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        let data = try JSONEncoder().encode(receipt)
        let temporary = directory.appending(path: ".entitlement-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableTemporary = temporary
            try mutableTemporary.setResourceValues(values)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
