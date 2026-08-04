public enum CanonicalPath {
    public static func isEqualOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || isDescendant(path, of: root)
    }

    public static func isDescendant(_ path: String, of root: String) -> Bool {
        guard path != root else { return false }
        let prefix = root == "/" ? "/" : root + "/"
        return path.hasPrefix(prefix)
    }
}
