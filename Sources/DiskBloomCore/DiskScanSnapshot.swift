import Foundation

public struct DiskScanSnapshot: Codable, @unchecked Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let root: DiskNode
    public let largestFiles: [DiskNode]
    public let unreadableCount: Int
    public let elapsed: TimeInterval
    public let scannedAt: Date

    public init(result: ScanResult) {
        self.version = Self.currentVersion
        self.root = result.root
        self.largestFiles = result.largestFiles
        self.unreadableCount = result.unreadableCount
        self.elapsed = result.elapsed
        self.scannedAt = result.scannedAt
    }

    public var result: ScanResult {
        ScanResult(
            root: root,
            largestFiles: largestFiles,
            unreadableCount: unreadableCount,
            elapsed: elapsed,
            scannedAt: scannedAt
        )
    }
}
