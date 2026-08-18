import Foundation

public enum DiskBloomDeletionPolicy {
    public static func canMoveToTrash(_ node: DiskNode, root: DiskNode) -> Bool {
        guard let nodeURL = node.url, node.id != root.id, !node.isSynthetic else { return false }

        let path = nodeURL.standardizedFileURL.resolvingSymlinksInPath().path
        if let rootURL = root.url,
           path == rootURL.standardizedFileURL.resolvingSymlinksInPath().path {
            return false
        }

        let protectedPaths: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes",
            "/bin", "/dev", "/etc", "/private", "/sbin", "/tmp", "/usr", "/var"
        ]
        if protectedPaths.contains(path) { return false }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return false }

        let components = nodeURL.standardizedFileURL.pathComponents
        if components.count == 3, components[1] == "Volumes" { return false }

        return true
    }
}
