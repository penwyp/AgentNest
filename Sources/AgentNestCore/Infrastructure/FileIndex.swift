import Darwin
import Foundation

public struct IndexedNode: Sendable {
    public let path: String
    public let identity: PhysicalResourceIdentity
    public let logicalBytes: UInt64
    public let physicalBytes: UInt64
    public let isSymbolicLink: Bool

    public init(
        path: String,
        identity: PhysicalResourceIdentity,
        logicalBytes: UInt64,
        physicalBytes: UInt64,
        isSymbolicLink: Bool
    ) {
        self.path = path
        self.identity = identity
        self.logicalBytes = logicalBytes
        self.physicalBytes = physicalBytes
        self.isSymbolicLink = isSymbolicLink
    }
}

public struct DirectoryIndex: Sendable {
    public let root: URL
    public let nodes: [IndexedNode]
    public let jsonAnchorParents: [URL]
    public let suspiciousDirectoryPaths: [URL]
    public let unreadablePaths: [String]
    public let isPartial: Bool

    public init(
        root: URL,
        nodes: [IndexedNode],
        jsonAnchorParents: [URL],
        suspiciousDirectoryPaths: [URL],
        unreadablePaths: [String],
        isPartial: Bool = false
    ) {
        self.root = root
        self.nodes = nodes
        self.jsonAnchorParents = jsonAnchorParents
        self.suspiciousDirectoryPaths = suspiciousDirectoryPaths
        self.unreadablePaths = unreadablePaths
        self.isPartial = isPartial
    }
}

public struct FileIndexer: Sendable {
    public init() {}

    public func index(
        root inputRoot: URL,
        progress: @Sendable (String, Int, UInt64) async -> Void
    ) async throws -> DirectoryIndex {
        let root = inputRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootIdentity: FileMetadata.Value
        do {
            rootIdentity = try FileMetadata.read(root)
        } catch {
            return DirectoryIndex(
                root: root,
                nodes: [],
                jsonAnchorParents: [],
                suspiciousDirectoryPaths: [],
                unreadablePaths: [root.path],
                isPartial: true
            )
        }
        var nodes = [rootIdentity.node]
        var anchors: [URL] = []
        var suspicious: [URL] = root.lastPathComponent == ".codex" ? [root] : []
        var unreadable: [String] = []
        var bytes = rootIdentity.node.physicalBytes
        var lastProgressCount = 0

        guard rootIdentity.node.identity.kind == .directory else {
            return DirectoryIndex(
                root: root,
                nodes: nodes,
                jsonAnchorParents: [],
                suspiciousDirectoryPaths: [],
                unreadablePaths: [],
                isPartial: false
            )
        }

        var pendingDirectories = [root]
        var nextDirectoryIndex = 0
        var wasCancelled = false
        scanLoop: while nextDirectoryIndex < pendingDirectories.count {
            if Task.isCancelled { wasCancelled = true; break }
            let directory = pendingDirectories[nextDirectoryIndex]
            nextDirectoryIndex += 1
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                unreadable.append(directory.path)
                continue
            }
            for url in children {
                if Task.isCancelled { wasCancelled = true; break scanLoop }
                do {
                    let metadata = try FileMetadata.read(url)
                    let node = metadata.node
                    guard node.identity.device == rootIdentity.node.identity.device else { continue }
                    nodes.append(node)
                    bytes &+= node.physicalBytes

                    if url.lastPathComponent == "version.json", node.identity.kind == .file, !node.isSymbolicLink {
                        anchors.append(url.deletingLastPathComponent())
                    }
                    if url.lastPathComponent == ".codex", node.identity.kind == .directory, !node.isSymbolicLink {
                        suspicious.append(url)
                    }
                    if node.identity.kind == .directory,
                       !node.isSymbolicLink,
                       !shouldSkipDescendants(url: url, kind: node.identity.kind) {
                        pendingDirectories.append(url)
                    }
                } catch {
                    unreadable.append(url.path)
                }

                if nodes.count - lastProgressCount >= 128 {
                    lastProgressCount = nodes.count
                    await progress(url.path, nodes.count, bytes)
                }
            }
        }
        await progress(root.path, nodes.count, bytes)
        return DirectoryIndex(
            root: root,
            nodes: nodes,
            jsonAnchorParents: anchors,
            suspiciousDirectoryPaths: suspicious,
            unreadablePaths: Array(Set(unreadable)).sorted(),
            isPartial: wasCancelled
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
            isSymbolicLink: fileType == S_IFLNK
        ))
    }
}
