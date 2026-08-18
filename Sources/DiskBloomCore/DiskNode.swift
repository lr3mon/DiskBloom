import Foundation

public enum DiskNodeKind: String, Sendable, Codable {
    case file
    case folder
    case aggregate
}

public final class DiskNode: Identifiable, Hashable, Codable, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let url: URL?
    public let size: Int64
    public let kind: DiskNodeKind
    public let children: [DiskNode]
    public let fileCount: Int
    public let folderCount: Int
    public let modifiedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL?,
        size: Int64,
        kind: DiskNodeKind,
        children: [DiskNode] = [],
        fileCount: Int,
        folderCount: Int,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.size = max(0, size)
        self.kind = kind
        self.children = children
        self.fileCount = max(0, fileCount)
        self.folderCount = max(0, folderCount)
        self.modifiedAt = modifiedAt
    }

    public var isDirectory: Bool { kind == .folder }
    public var isSynthetic: Bool { kind == .aggregate || url == nil }
    public var path: String { url?.path ?? "" }
    public var fileExtension: String {
        guard kind == .file else { return "" }
        let value = url?.pathExtension.lowercased() ?? ""
        return value.isEmpty ? "확장자 없음" : value
    }

    public func fraction(of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(size) / Double(total)))
    }

    public static func == (lhs: DiskNode, rhs: DiskNode) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct ScanProgress: Sendable, Equatable {
    public let items: Int
    public let bytes: Int64
    public let currentPath: String

    public init(items: Int, bytes: Int64, currentPath: String) {
        self.items = items
        self.bytes = bytes
        self.currentPath = currentPath
    }
}

public struct ScanResult: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let root: DiskNode
    public let largestFiles: [DiskNode]
    public let unreadableCount: Int
    public let elapsed: TimeInterval
    public let scannedAt: Date

    public init(
        root: DiskNode,
        largestFiles: [DiskNode],
        unreadableCount: Int,
        elapsed: TimeInterval,
        scannedAt: Date = Date()
    ) {
        self.root = root
        self.largestFiles = largestFiles
        self.unreadableCount = unreadableCount
        self.elapsed = elapsed
        self.scannedAt = scannedAt
    }
}

public enum DiskScanError: LocalizedError {
    case inaccessible(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .inaccessible(let url):
            return "‘\(url.lastPathComponent)’ 폴더를 읽을 수 없습니다. 접근 권한을 확인해 주세요."
        case .cancelled:
            return "스캔을 취소했습니다."
        }
    }
}
