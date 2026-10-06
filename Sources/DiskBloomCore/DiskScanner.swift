import Foundation

public final class DiskScanner: @unchecked Sendable {
    public enum MetadataStrategy: Sendable {
        case automatic
        /// Reference backend for compatibility checks and scan diagnostics.
        case foundation
    }

    public struct Options: Sendable {
        public var maximumTreeDepth: Int
        public var maximumChildrenPerFolder: Int
        public var largestFileLimit: Int
        public var progressItemInterval: Int
        public var excludedPaths: [String]
        public var metadataStrategy: MetadataStrategy

        public init(
            maximumTreeDepth: Int = 8,
            maximumChildrenPerFolder: Int = 160,
            largestFileLimit: Int = 300,
            progressItemInterval: Int = 128,
            excludedPaths: [String] = [],
            metadataStrategy: MetadataStrategy = .automatic
        ) {
            self.maximumTreeDepth = max(0, maximumTreeDepth)
            self.maximumChildrenPerFolder = max(8, maximumChildrenPerFolder)
            self.largestFileLimit = max(10, largestFileLimit)
            self.progressItemInterval = max(16, progressItemInterval)
            self.excludedPaths = excludedPaths.map {
                var normalized = URL(fileURLWithPath: $0).standardizedFileURL.path
                while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
                return normalized
            }
            self.metadataStrategy = metadataStrategy
        }
    }

    private let options: Options
    private let cancellationToken: ScanCancellationToken
    private let reader: DirectoryReader
    private var topFiles: CandidateHeap
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
        self.reader = DirectoryReader(fileManager: fileManager, strategy: options.metadataStrategy)
        self.topFiles = CandidateHeap(limit: options.largestFileLimit, compareNames: false)
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
        topFiles = CandidateHeap(limit: options.largestFileLimit, compareNames: false)
        try checkCancellation()

        let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = rootURL.path
        guard !isExcluded(path, paths: options.excludedPaths),
              let entry = try? reader.metadata(at: rootURL), entry.kind != .other else {
            throw DiskScanError.inaccessible(rootURL)
        }
        emitProgress(path: path, force: true)
        let root: DiskNode
        if entry.kind == .directory {
            root = try scanDirectory(path: path, entry: entry, depth: 0, exclusions: options.excludedPaths)
        } else {
            let candidate = recordFile(entry, parentPath: rootURL.deletingLastPathComponent().path)
            root = candidate.materialize()
        }
        emitProgress(path: path, force: true)
        return ScanResult(
            root: root,
            largestFiles: topFiles.sortedDescending().map { $0.materialize() },
            unreadableCount: unreadableCount,
            elapsed: Date().timeIntervalSince(startedAt)
        )
    }

    private func scanDirectory(path: String, entry: ScanEntry, depth: Int, exclusions: [String]) throws -> DiskNode {
        try checkCancellation()
        processedItems += 1
        emitProgress(path: path)
        if depth >= options.maximumTreeDepth {
            return try scanCollapsedDirectory(path: path, entry: entry, exclusions: exclusions)
        }

        var children = ChildAccumulator(limit: options.maximumChildrenPerFolder)
        let childExclusions = descendantExclusions(of: path, paths: exclusions)
        try reader.enumerate(path: path, checkCancellation: checkCancellation, unreadable: { self.unreadableCount += 1 }) { child in
            guard child.kind != .other else { return }
            // Once outside excluded branches, files need no path construction or normalization.
            if !childExclusions.isEmpty && isExcluded(childPath(path, child.name), paths: childExclusions) { return }
            if child.kind == .directory {
                let node = try scanDirectory(path: childPath(path, child.name), entry: child, depth: depth + 1, exclusions: childExclusions)
                children.insert(NodeCandidate(folder: node))
            } else {
                children.insert(recordFile(child, parentPath: path))
            }
        }
        return DiskNode(
            name: displayName(path: path, name: entry.name),
            url: URL(fileURLWithPath: path, isDirectory: true),
            size: children.totalSize,
            kind: .folder,
            children: children.materialize(),
            fileCount: children.fileCount,
            folderCount: 1 + children.folderCount,
            modifiedAt: entry.modifiedAt
        )
    }

    private func scanCollapsedDirectory(path: String, entry: ScanEntry, exclusions: [String]) throws -> DiskNode {
        var totalSize: Int64 = 0
        var fileCount = 0
        var folderCount = 1
        var pending: [(path: String, exclusions: [String])] = [(path, exclusions)]
        // Iterative traversal keeps very deep trees off the call stack and closes
        // each directory descriptor before opening the next one.
        while let directory = pending.popLast() {
            try checkCancellation()
            let childExclusions = descendantExclusions(of: directory.path, paths: directory.exclusions)
            try reader.enumerate(path: directory.path, checkCancellation: checkCancellation, unreadable: { self.unreadableCount += 1 }) { child in
                guard child.kind != .other else { return }
                if !childExclusions.isEmpty && isExcluded(childPath(directory.path, child.name), paths: childExclusions) { return }
                if child.kind == .directory {
                    let childDirectory = childPath(directory.path, child.name)
                    // Foundation's recursive enumerator stops at nested mounts.
                    // Preserve that behavior so hidden simulator / system mounts
                    // are not added again to their containing local volume.
                    if !child.isMountPoint { pending.append((childDirectory, childExclusions)) }
                    folderCount += 1
                    processedItems += 1
                    emitProgress(path: childDirectory)
                } else {
                    totalSize = safeAdd(totalSize, child.size)
                    fileCount += 1
                    _ = recordFile(child, parentPath: directory.path)
                }
            }
        }
        return DiskNode(
            name: displayName(path: path, name: entry.name),
            url: URL(fileURLWithPath: path, isDirectory: true),
            size: totalSize,
            kind: .folder,
            fileCount: fileCount,
            folderCount: folderCount,
            modifiedAt: entry.modifiedAt
        )
    }

    private func recordFile(_ entry: ScanEntry, parentPath: String) -> NodeCandidate {
        var candidate = NodeCandidate(file: entry, parentPath: parentPath)
        // Candidates are lightweight values; UUIDs, URLs and DiskNodes are created
        // only for the retained children / largest files.
        if topFiles.wouldAccept(size: entry.size) {
            candidate.retainNode()
            _ = topFiles.insert(candidate)
        }
        processedItems += 1
        processedBytes = safeAdd(processedBytes, entry.size)
        emitProgress(path: childPath(parentPath, entry.name))
        return candidate
    }

    private func emitProgress(path: @autoclosure () -> String, force: Bool = false) {
        guard force || processedItems % options.progressItemInterval == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgressAt >= 0.15 else { return }
        lastProgressAt = now
        progressHandler(ScanProgress(items: processedItems, bytes: processedBytes, currentPath: path()))
    }

    private func checkCancellation() throws {
        if cancellationToken.isCancelled { throw DiskScanError.cancelled }
    }

    private func isExcluded(_ path: String, paths: [String]) -> Bool {
        paths.contains { excluded in
            path == excluded || (excluded != "/" && path.hasPrefix(excluded + "/"))
        }
    }

    private func descendantExclusions(of path: String, paths: [String]) -> [String] {
        guard !paths.isEmpty else { return [] }
        let prefix = path == "/" ? "/" : path + "/"
        return paths.filter { $0.hasPrefix(prefix) }
    }

    private func displayName(path: String, name: String) -> String {
        !name.isEmpty ? name : (path == "/" ? "Macintosh HD" : path)
    }
}

private func childPath(_ parent: String, _ name: String) -> String {
    parent == "/" ? "/" + name : parent + "/" + name
}

private func safeAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : value
}

private struct NodeCandidate {
    let name: String
    let size: Int64
    let fileCount: Int
    let folderCount: Int
    private let parentPath: String
    private let modifiedAt: Date?
    private var retainedNode: DiskNode?

    init(file: ScanEntry, parentPath: String) {
        self.name = file.name
        self.size = file.size
        self.fileCount = 1
        self.folderCount = 0
        self.parentPath = parentPath
        self.modifiedAt = file.modifiedAt
        self.retainedNode = nil
    }

    init(folder: DiskNode) {
        self.name = folder.name
        self.size = folder.size
        self.fileCount = folder.fileCount
        self.folderCount = folder.folderCount
        self.parentPath = ""
        self.modifiedAt = folder.modifiedAt
        self.retainedNode = folder
    }

    func materialize() -> DiskNode {
        retainedNode ?? DiskNode(name: name, url: URL(fileURLWithPath: childPath(parentPath, name)), size: size,
                           kind: .file, fileCount: 1, folderCount: 0, modifiedAt: modifiedAt)
    }

    mutating func retainNode() {
        if retainedNode == nil { retainedNode = materialize() }
    }
}

/// The root is the worst retained candidate, so selecting the displayed top K
/// requires O(N log K) work and O(K) retained candidates instead of sorting N.
private struct CandidateHeap {
    private var values: [NodeCandidate] = []
    private let limit: Int
    private let compareNames: Bool

    init(limit: Int, compareNames: Bool) {
        self.limit = limit
        self.compareNames = compareNames
        values.reserveCapacity(limit)
    }

    func wouldAccept(size: Int64) -> Bool {
        values.count < limit || size > (values.first?.size ?? 0)
    }

    mutating func insert(_ candidate: NodeCandidate) -> NodeCandidate? {
        if values.count < limit {
            values.append(candidate)
            var child = values.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard better(values[parent], than: values[child]) else { break }
                values.swapAt(child, parent)
                child = parent
            }
            return nil
        }
        guard better(candidate, than: values[0]) else { return candidate }
        let discarded = values[0]
        values[0] = candidate
        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var worst = parent
            if left < values.count && better(values[worst], than: values[left]) { worst = left }
            if right < values.count && better(values[worst], than: values[right]) { worst = right }
            guard worst != parent else { break }
            values.swapAt(parent, worst)
            parent = worst
        }
        return discarded
    }

    func sortedDescending() -> [NodeCandidate] {
        values.sorted { lhs, rhs in
            if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.size > rhs.size
        }
    }

    private func better(_ lhs: NodeCandidate, than rhs: NodeCandidate) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return compareNames && lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct ChildAccumulator {
    private var heap: CandidateHeap
    private let limit: Int
    private var count = 0
    private var omittedSize: Int64 = 0
    private var omittedFiles = 0
    private var omittedFolders = 0
    private(set) var totalSize: Int64 = 0
    private(set) var fileCount = 0
    private(set) var folderCount = 0

    init(limit: Int) {
        self.limit = limit
        self.heap = CandidateHeap(limit: limit, compareNames: true)
    }

    mutating func insert(_ candidate: NodeCandidate) {
        count += 1
        totalSize = safeAdd(totalSize, candidate.size)
        fileCount += candidate.fileCount
        folderCount += candidate.folderCount
        if let omitted = heap.insert(candidate) { recordOmitted(omitted) }
    }

    mutating func materialize() -> [DiskNode] {
        var kept = heap.sortedDescending()
        guard count > limit else { return kept.map { $0.materialize() } }
        recordOmitted(kept.removeLast())
        let aggregate = DiskNode(
            name: "기타 \(DiskBloomFormat.count(count - kept.count))개 항목", url: nil,
            size: omittedSize, kind: .aggregate, fileCount: omittedFiles, folderCount: omittedFolders
        )
        return kept.map { $0.materialize() } + [aggregate]
    }

    private mutating func recordOmitted(_ candidate: NodeCandidate) {
        omittedSize = safeAdd(omittedSize, candidate.size)
        omittedFiles += candidate.fileCount
        omittedFolders += candidate.folderCount
    }
}
