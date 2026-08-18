import DiskBloomCore
import Foundation

struct DiskSnapshotCache: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
#if DEBUG
        if let overridePath = ProcessInfo.processInfo.environment["DISKBLOOM_CACHE_PATH"], !overridePath.isEmpty {
            self.fileURL = URL(fileURLWithPath: overridePath, isDirectory: false)
            return
        }
#endif
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.fileURL = support
            .appendingPathComponent("DiskBloom", isDirectory: true)
            .appendingPathComponent("local-storage-snapshot.json", isDirectory: false)
    }

    func load() throws -> ScanResult? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        try hardenPermissions()
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DiskScanSnapshot.self, from: data)
        guard snapshot.version == DiskScanSnapshot.currentVersion else { return nil }
        return snapshot.result
    }

    func save(_ result: ScanResult) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(DiskScanSnapshot(result: result))
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
        excludeFromBackup()
    }

    var path: String { fileURL.path }

    private func hardenPermissions() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
        excludeFromBackup()
    }

    private func excludeFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }
}
