import Foundation

public struct SnapshotStore: Sendable {
    public let fileURL: URL
    private let maximumBytes = 128 * 1_024 * 1_024

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AgentNest/Snapshots/latest.json")
    }

    public func load() throws -> DeviceSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let metadata = try FileMetadata.read(fileURL).node
        guard metadata.identity.kind == .file, !metadata.isSymbolicLink, metadata.logicalBytes <= UInt64(maximumBytes) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let permissions = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        return try JSONDecoder().decode(DeviceSnapshot.self, from: Data(contentsOf: fileURL, options: [.mappedIfSafe]))
    }

    public func save(_ snapshot: DeviceSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
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
        let temporary = directory.appending(path: ".snapshot-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableTemporary = temporary
            try mutableTemporary.setResourceValues(values)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
