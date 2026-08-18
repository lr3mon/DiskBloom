import Foundation

public final class DiskScanner: @unchecked Sendable {
    public struct Options: Sendable {
        public var maximumTreeDepth: Int
        public var maximumChildrenPerFolder: Int
        public var largestFileLimit: Int
        public var progressItemInterval: Int
        public var excludedPaths: [String]

        public init(
            maximumTreeDepth: Int = 8,
            maximumChildrenPerFolder: Int = 160,
            largestFileLimit: Int = 300,
            progressItemInterval: Int = 128,
            excludedPaths: [String] = []
        ) {
            self.maximumTreeDepth = max(0, maximumTreeDepth)
            self.maximumChildrenPerFolder = max(8, maximumChildrenPerFolder)
            self.largestFileLimit = max(10, largestFileLimit)
            self.progressItemInterval = max(16, progressItemInterval)
            self.excludedPaths = excludedPaths.map {
                var normalized = URL(fileURLWithPath: $0).standardizedFileURL.path
                while normalized.count > 1 && normalized.hasSuffix("/") {
                    normalized.removeLast()
                }
                return normalized
            }
        }
    }

    private let fileManager: FileManager
    private let options: Options
    private let cancellationToken: ScanCancellationToken
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey
    ]

    private var topFiles: TopFileHeap
    private var processedItems = 0
    private var processedBytes: Int64 = 0
    private var unreadableCount = 0
    private var lastProgressAt: TimeInterval = 0
    private var progressHandler: @Sendable (ScanProgress) -> Void = { _ in }

    public init(
        options: Options = Options(),
        cancellationToken: ScanCancellationToken = ScanCancellationToken(),
        fileManager: FileManager = .default
    ) {
        self.options = options
        self.cancellationToken = cancellationToken
        self.fileManager = fileManager
        self.topFiles = TopFileHeap(limit: options.largestFileLimit)
    }

    public func scan(
        url: URL,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> ScanResult {
        let startedAt = Date()
        progressHandler = progress
        processedItems = 0
        processedBytes = 0
        unreadableCount = 0
        lastProgressAt = 0
        topFiles = TopFileHeap(limit: options.largestFileLimit)

        let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw DiskScanError.inaccessible(rootURL)
        }

        guard let root = try scanEntry(rootURL, depth: 0) else {
            throw DiskScanError.inaccessible(rootURL)
        }

        emitProgress(path: rootURL.path, force: true)
        return ScanResult(
            root: root,
            largestFiles: topFiles.sortedDescending(),
            unreadableCount: unreadableCount,
            elapsed: Date().timeIntervalSince(startedAt)
        )
    }

    private func scanEntry(_ url: URL, depth: Int) throws -> DiskNode? {
        try checkCancellation()
        if isExcluded(url) { return nil }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: resourceKeys)
        } catch {
            unreadableCount += 1
            return nil
        }

        if values.isSymbolicLink == true {
            return nil
        }

        if values.isDirectory == true {
            processedItems += 1
            emitProgress(path: url.path)

            if depth >= options.maximumTreeDepth {
                return try scanCollapsedDirectory(url, rootValues: values)
            }

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: []
                )
            } catch {
                unreadableCount += 1
                return DiskNode(
                    name: displayName(for: url),
                    url: url,
                    size: 0,
                    kind: .folder,
                    fileCount: 0,
                    folderCount: 1,
                    modifiedAt: values.contentModificationDate
                )
            }

            var children: [DiskNode] = []
            children.reserveCapacity(min(entries.count, options.maximumChildrenPerFolder + 1))
            var totalSize: Int64 = 0
            var fileCount = 0
            var folderCount = 1

            for entry in entries {
                try checkCancellation()
                if let child = try autoreleasepool(invoking: {
                    try scanEntry(entry, depth: depth + 1)
                }) {
                    children.append(child)
                    totalSize = safeAdd(totalSize, child.size)
                    fileCount += child.fileCount
                    folderCount += child.folderCount
                }
            }

            children.sort { lhs, rhs in
                if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return lhs.size > rhs.size
            }

            let displayedChildren = compress(children: children)
            return DiskNode(
                name: displayName(for: url),
                url: url,
                size: totalSize,
                kind: .folder,
                children: displayedChildren,
                fileCount: fileCount,
                folderCount: folderCount,
                modifiedAt: values.contentModificationDate
            )
        }

        guard values.isRegularFile == true else { return nil }
        let size = allocatedSize(from: values)
        let node = DiskNode(
            name: displayName(for: url),
            url: url,
            size: size,
            kind: .file,
            fileCount: 1,
            folderCount: 0,
            modifiedAt: values.contentModificationDate
        )
        topFiles.insert(node)
        processedItems += 1
        processedBytes = safeAdd(processedBytes, size)
        emitProgress(path: url.path)
        return node
    }

    private func scanCollapsedDirectory(
        _ url: URL,
        rootValues: URLResourceValues
    ) throws -> DiskNode {
        var totalSize: Int64 = 0
        var fileCount = 0
        var folderCount = 1

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { [weak self] _, _ in
                self?.unreadableCount += 1
                return true
            }
        ) else {
            unreadableCount += 1
            return DiskNode(
                name: displayName(for: url),
                url: url,
                size: 0,
                kind: .folder,
                fileCount: 0,
                folderCount: 1,
                modifiedAt: rootValues.contentModificationDate
            )
        }

        for case let entry as URL in enumerator {
            try autoreleasepool {
                try checkCancellation()
                if isExcluded(entry) {
                    enumerator.skipDescendants()
                    return
                }
                let values: URLResourceValues
                do {
                    values = try entry.resourceValues(forKeys: resourceKeys)
                } catch {
                    unreadableCount += 1
                    return
                }
                if values.isSymbolicLink == true { return }
                if values.isDirectory == true {
                    folderCount += 1
                    processedItems += 1
                    emitProgress(path: entry.path)
                    return
                }
                guard values.isRegularFile == true else { return }

                let size = allocatedSize(from: values)
                totalSize = safeAdd(totalSize, size)
                fileCount += 1
                processedItems += 1
                processedBytes = safeAdd(processedBytes, size)
                topFiles.insert(
                    DiskNode(
                        name: displayName(for: entry),
                        url: entry,
                        size: size,
                        kind: .file,
                        fileCount: 1,
                        folderCount: 0,
                        modifiedAt: values.contentModificationDate
                    )
                )
                emitProgress(path: entry.path)
            }
        }

        return DiskNode(
            name: displayName(for: url),
            url: url,
            size: totalSize,
            kind: .folder,
            children: [],
            fileCount: fileCount,
            folderCount: folderCount,
            modifiedAt: rootValues.contentModificationDate
        )
    }

    private func compress(children: [DiskNode]) -> [DiskNode] {
        guard children.count > options.maximumChildrenPerFolder else { return children }
        let keepCount = max(1, options.maximumChildrenPerFolder - 1)
        let kept = Array(children.prefix(keepCount))
        let omitted = children.dropFirst(keepCount)
        let aggregate = DiskNode(
            name: "기타 \(DiskBloomFormat.count(omitted.count))개 항목",
            url: nil,
            size: omitted.reduce(0) { safeAdd($0, $1.size) },
            kind: .aggregate,
            fileCount: omitted.reduce(0) { $0 + $1.fileCount },
            folderCount: omitted.reduce(0) { $0 + $1.folderCount }
        )
        return kept + [aggregate]
    }

    private func allocatedSize(from values: URLResourceValues) -> Int64 {
        let raw = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        return Int64(max(0, raw))
    }

    private func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        if !name.isEmpty { return name }
        return url.path == "/" ? "Macintosh HD" : url.path
    }

    private func emitProgress(path: String, force: Bool = false) {
        let now = Date.timeIntervalSinceReferenceDate
        let itemBoundary = processedItems % options.progressItemInterval == 0
        guard force || itemBoundary || now - lastProgressAt > 0.15 else { return }
        lastProgressAt = now
        progressHandler(
            ScanProgress(
                items: processedItems,
                bytes: processedBytes,
                currentPath: path
            )
        )
    }

    private func checkCancellation() throws {
        if cancellationToken.isCancelled {
            throw DiskScanError.cancelled
        }
    }

    private func isExcluded(_ url: URL) -> Bool {
        guard !options.excludedPaths.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        return options.excludedPaths.contains { excluded in
            path == excluded || (excluded != "/" && path.hasPrefix(excluded + "/"))
        }
    }

    private func safeAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}

private struct TopFileHeap {
    private var values: [DiskNode] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    mutating func insert(_ node: DiskNode) {
        guard node.kind == .file else { return }
        if values.count < limit {
            values.append(node)
            siftUp(from: values.count - 1)
            return
        }
        guard let smallest = values.first, node.size > smallest.size else { return }
        values[0] = node
        siftDown(from: 0)
    }

    func sortedDescending() -> [DiskNode] {
        values.sorted { lhs, rhs in
            if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.size > rhs.size
        }
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard values[child].size < values[parent].size else { break }
            values.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < values.count && values[left].size < values[candidate].size {
                candidate = left
            }
            if right < values.count && values[right].size < values[candidate].size {
                candidate = right
            }
            guard candidate != parent else { return }
            values.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
