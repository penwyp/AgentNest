import Darwin
import Foundation

public struct IndexedNode: Sendable {
    public let path: String
    public let identity: PhysicalResourceIdentity
    public let logicalBytes: UInt64
    public let physicalBytes: UInt64
    public let isSymbolicLink: Bool
    public let modifiedAt: Date?

    public init(
        path: String,
        identity: PhysicalResourceIdentity,
        logicalBytes: UInt64,
        physicalBytes: UInt64,
        isSymbolicLink: Bool,
        modifiedAt: Date?
    ) {
        self.path = path
        self.identity = identity
        self.logicalBytes = logicalBytes
        self.physicalBytes = physicalBytes
        self.isSymbolicLink = isSymbolicLink
        self.modifiedAt = modifiedAt
    }
}

public struct DirectoryIndex: Sendable {
    public let root: URL
    public let nodes: [IndexedNode]
    public let unreadablePaths: [String]

    public init(
        root: URL,
        nodes: [IndexedNode],
        unreadablePaths: [String]
    ) {
        self.root = root
        self.nodes = nodes
        self.unreadablePaths = unreadablePaths
    }
}

public struct FileIndexer: Sendable {
    public init() {}

    public func index(
        root inputRoot: URL,
        ignoredLocations: [URL] = [],
        progress: @Sendable (String, Int, UInt64) async -> Void
    ) async throws -> DirectoryIndex {
        try Task.checkCancellation()
        let root = inputRoot.resolvingSymlinksInPath().standardizedFileURL
        let ignoredPaths = ignoredLocations.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        if ignoredPaths.contains(where: { CanonicalPath.isEqualOrDescendant(root.path, of: $0) }) {
            return DirectoryIndex(root: root, nodes: [], unreadablePaths: [])
        }
        let rootIdentity: FileMetadata.Value
        do {
            rootIdentity = try FileMetadata.read(root)
        } catch {
            return DirectoryIndex(
                root: root,
                nodes: [],
                unreadablePaths: [root.path]
            )
        }
        var nodes = [rootIdentity.node]
        var unreadable: [String] = []
        var bytes = rootIdentity.node.physicalBytes
        var lastProgressCount = 0

        guard rootIdentity.node.identity.kind == .directory else {
            return DirectoryIndex(
                root: root,
                nodes: nodes,
                unreadablePaths: []
            )
        }

        var enumerationErrorPath: String?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, _ in
                enumerationErrorPath = url.path
                return true
            }
        ) else {
            return DirectoryIndex(root: root, nodes: nodes, unreadablePaths: [root.path])
        }

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let normalizedPath = url.standardizedFileURL.path
            if ignoredPaths.contains(where: { CanonicalPath.isEqualOrDescendant(normalizedPath, of: $0) }) {
                enumerator.skipDescendants()
                continue
            }
            do {
                let node = try FileMetadata.read(url).node
                guard node.identity.device == rootIdentity.node.identity.device else {
                    enumerator.skipDescendants()
                    continue
                }
                nodes.append(node)
                bytes &+= node.physicalBytes
                if node.identity.kind == .directory,
                   (node.isSymbolicLink || shouldSkipDescendants(url: url, kind: node.identity.kind)) {
                    enumerator.skipDescendants()
                }
            } catch {
                unreadable.append(normalizedPath)
                enumerator.skipDescendants()
            }

            if let path = enumerationErrorPath {
                unreadable.append(path)
                enumerationErrorPath = nil
            }
            if nodes.count - lastProgressCount >= 128 {
                lastProgressCount = nodes.count
                await progress(normalizedPath, nodes.count, bytes)
            }
        }
        if let path = enumerationErrorPath { unreadable.append(path) }
        try Task.checkCancellation()
        await progress(root.path, nodes.count, bytes)
        return DirectoryIndex(
            root: root,
            nodes: nodes,
            unreadablePaths: Array(Set(unreadable)).sorted()
        )
    }

    private func shouldSkipDescendants(url: URL, kind: ResourceKind) -> Bool {
        guard kind == .directory else { return false }
        let name = url.lastPathComponent.lowercased()
        if name == "node_modules" || name == "vendor" || name == "deriveddata" {
            return true
        }
        if url.pathExtension.lowercased() == "app" || url.pathExtension.lowercased() == "bundle" {
            return true
        }
        let components = url.pathComponents
        return components.count >= 2 && components.suffix(2) == [".git", "objects"]
    }

}

enum FileMetadata {
    struct Value {
        let node: IndexedNode
    }

    static func read(_ url: URL) throws -> Value {
        var value = Darwin.stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fileType = value.st_mode & S_IFMT
        let kind: ResourceKind
        switch fileType {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        default: kind = .other
        }
        return Value(node: IndexedNode(
            path: url.standardizedFileURL.path,
            identity: PhysicalResourceIdentity(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino),
                kind: kind
            ),
            logicalBytes: value.st_size > 0 ? UInt64(value.st_size) : 0,
            physicalBytes: value.st_blocks > 0 ? UInt64(value.st_blocks) * 512 : 0,
            isSymbolicLink: fileType == S_IFLNK,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec) + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        ))
    }
}
