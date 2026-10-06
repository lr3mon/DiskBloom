import DiskBloomCore
import Foundation

struct IndexedLocation: Identifiable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    let node: DiskNode
}

enum LocalStorageIndex {
    static func discoverTargets(fileManager: FileManager = .default) -> [LocalScanTarget] {
        LocalStorageScanner.discoverTargets(fileManager: fileManager)
    }

    static func excludedPaths(for target: LocalScanTarget, fileManager: FileManager = .default) -> [String] {
        LocalStorageScanner.excludedPaths(for: target, fileManager: fileManager)
    }

    static func scan(
        target: LocalScanTarget,
        options: DiskScanner.Options,
        cancellationToken: ScanCancellationToken,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResult {
        try await LocalStorageScanner.scan(target: target, options: options, cancellationToken: cancellationToken, progress: progress)
    }

    static func combine(_ results: [(LocalScanTarget, ScanResult)]) -> ScanResult {
        LocalStorageScanner.combine(results)
    }

    static func locations(in result: ScanResult) -> [IndexedLocation] {
        var locations: [IndexedLocation] = [
            IndexedLocation(
                id: "overview",
                title: "전체 로컬 저장소",
                icon: "externaldrive.connected.to.line.below.fill",
                detail: DiskBloomFormat.bytes(result.root.size),
                node: result.root
            )
        ]

        for volume in result.root.children where volume.kind == .folder {
            locations.append(
                IndexedLocation(
                    id: "volume:\(volume.id.uuidString)",
                    title: volume.name,
                    icon: volume.url?.path == "/" ? "internaldrive.fill" : "externaldrive.fill",
                    detail: DiskBloomFormat.bytes(volume.size),
                    node: volume
                )
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let quickPaths: [(String, String, URL)] = [
            ("홈", "house.fill", home),
            ("다운로드", "arrow.down.circle.fill", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("문서", "doc.fill", home.appendingPathComponent("Documents", isDirectory: true)),
            ("응용 프로그램", "app.fill", URL(fileURLWithPath: "/Applications", isDirectory: true))
        ]
        var includedPaths = Set(locations.compactMap { $0.node.url?.standardizedFileURL.path })
        for (title, icon, url) in quickPaths {
            let path = url.standardizedFileURL.path
            guard !includedPaths.contains(path), let node = findNode(path: path, in: result.root) else { continue }
            includedPaths.insert(path)
            locations.append(
                IndexedLocation(
                    id: "path:\(path)",
                    title: title,
                    icon: icon,
                    detail: DiskBloomFormat.bytes(node.size),
                    node: node
                )
            )
        }
        return locations
    }

    static func result(for node: DiskNode, in master: ScanResult) -> ScanResult {
        guard node.id != master.root.id else { return master }
        let prefix = node.url?.standardizedFileURL.path
        let largest = master.largestFiles.filter { file in
            guard let prefix, let filePath = file.url?.standardizedFileURL.path else { return false }
            return filePath == prefix || filePath.hasPrefix(prefix + "/")
        }
        return ScanResult(
            root: node,
            largestFiles: largest,
            unreadableCount: master.unreadableCount,
            elapsed: master.elapsed,
            scannedAt: master.scannedAt
        )
    }

    static func findNode(path: String, in root: DiskNode) -> DiskNode? {
        if let rootPath = root.url?.standardizedFileURL.path,
           normalizedPath(rootPath) == normalizedPath(path) {
            return root
        }
        for child in root.children where child.kind != .aggregate {
            if let found = findNode(path: path, in: child) { return found }
        }
        return nil
    }

    private static func normalizedPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized != "/" else { return standardized }
        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

}
