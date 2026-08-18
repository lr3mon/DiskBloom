import DiskBloomCore
import Foundation

struct LocalScanTarget: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL
    let isSystemVolume: Bool
}

struct IndexedLocation: Identifiable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    let node: DiskNode
}

enum LocalStorageIndex {
    static func discoverTargets(fileManager: FileManager = .default) -> [LocalScanTarget] {
#if DEBUG
        if let overridePath = ProcessInfo.processInfo.environment["DISKBLOOM_SCAN_ROOT"], !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath, isDirectory: true).standardizedFileURL
            return [LocalScanTarget(id: "debug-override", name: url.lastPathComponent, url: url, isSystemVolume: false)]
        }
#endif
        let keys: Set<URLResourceKey> = [
            .volumeIsLocalKey,
            .volumeIsBrowsableKey,
            .volumeLocalizedNameKey,
            .volumeUUIDStringKey
        ]
        let mounted = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        var targets: [LocalScanTarget] = []
        var seenPaths = Set<String>()
        for rawURL in mounted + [URL(fileURLWithPath: "/", isDirectory: true)] {
            let url = rawURL.standardizedFileURL
            let path = url.path
            guard seenPaths.insert(path).inserted else { continue }
            guard path == "/" || path.hasPrefix("/Volumes/") else { continue }
            guard !path.contains("/Library/Developer/CoreSimulator/Volumes/") else { continue }

            let values = try? url.resourceValues(forKeys: keys)
            guard values?.volumeIsLocal != false else { continue }
            guard path == "/" || values?.volumeIsBrowsable != false else { continue }

            let isSystem = path == "/"
            let name = isSystem
                ? (values?.volumeLocalizedName ?? "Macintosh HD")
                : (values?.volumeLocalizedName ?? url.lastPathComponent)
            let identifier = values?.volumeUUIDString ?? path
            targets.append(
                LocalScanTarget(
                    id: identifier,
                    name: name,
                    url: url,
                    isSystemVolume: isSystem
                )
            )
        }

        return targets.sorted {
            if $0.isSystemVolume != $1.isSystemVolume { return $0.isSystemVolume }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func excludedPaths(for target: LocalScanTarget, fileManager: FileManager = .default) -> [String] {
        guard target.isSystemVolume else { return cloudProviderPaths(fileManager: fileManager) }

        let apfsAndTransientPaths = [
            "/System/Volumes/Data",
            "/System/Volumes/Preboot",
            "/System/Volumes/VM",
            "/System/Volumes/Update",
            "/System/Volumes/xarts",
            "/System/Volumes/iSCPreboot",
            "/System/Volumes/Hardware",
            "/Library/Developer/CoreSimulator/Volumes",
            "/Volumes",
            "/Network",
            "/dev",
            "/net",
            "/home",
            "/.nofollow",
            "/.resolve",
            "/.vol",
            "/.file"
        ]
        return Array(Set(apfsAndTransientPaths + cloudProviderPaths(fileManager: fileManager))).sorted()
    }

    static func scan(
        target: LocalScanTarget,
        options: DiskScanner.Options,
        cancellationToken: ScanCancellationToken,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResult {
        let startedAt = Date()
        let planBudget = ScanPlanBudget(limit: 1_000)
        let plan = makeScanPlan(
            url: target.url,
            target: target,
            excludedPaths: options.excludedPaths,
            depth: 0,
            budget: planBudget
        )
        let leaves = plan.leaves
        guard !leaves.isEmpty else {
            return try DiskScanner(options: options, cancellationToken: cancellationToken)
                .scan(url: target.url, progress: progress)
        }

        let workerCount = min(4, leaves.count)
        let queue = ScanPlanQueue(leaves: leaves)
        let accumulator = ConcurrentScanProgress(progress: progress)
        let errorCounter = ScanErrorCounter()

        let partialResults = try await withThrowingTaskGroup(of: [ScanResult].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var results: [ScanResult] = []
                    while let leaf = await queue.next() {
                        if cancellationToken.isCancelled { throw DiskScanError.cancelled }
                        let leafOptions = DiskScanner.Options(
                            maximumTreeDepth: max(0, options.maximumTreeDepth - leaf.depth),
                            maximumChildrenPerFolder: options.maximumChildrenPerFolder,
                            largestFileLimit: options.largestFileLimit,
                            progressItemInterval: options.progressItemInterval,
                            excludedPaths: options.excludedPaths
                        )
                        let scanner = DiskScanner(options: leafOptions, cancellationToken: cancellationToken)
                        let key = leaf.url.standardizedFileURL.path
                        do {
                            let result = try scanner.scan(url: leaf.url) { update in
                                accumulator.update(key: key, label: target.name, progress: update)
                            }
                            results.append(result)
                        } catch DiskScanError.cancelled {
                            throw DiskScanError.cancelled
                        } catch {
                            await errorCounter.increment()
                        }
                    }
                    return results
                }
            }

            var flattened: [ScanResult] = []
            for try await results in group {
                flattened.append(contentsOf: results)
            }
            return flattened
        }

        let resultsByPath = Dictionary(
            uniqueKeysWithValues: partialResults.compactMap { result in
                result.root.url.map { ($0.standardizedFileURL.path, result) }
            }
        )
        guard let rebuiltRoot = rebuild(plan: plan, targetName: target.name, resultsByPath: resultsByPath, childLimit: options.maximumChildrenPerFolder) else {
            throw DiskScanError.inaccessible(target.url)
        }
        let largestFiles = partialResults
            .flatMap(\.largestFiles)
            .sorted { lhs, rhs in
                if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return lhs.size > rhs.size
            }
        return ScanResult(
            root: rebuiltRoot,
            largestFiles: Array(largestFiles.prefix(options.largestFileLimit)),
            unreadableCount: partialResults.reduce(0) { $0 + $1.unreadableCount } + (await errorCounter.value),
            elapsed: Date().timeIntervalSince(startedAt),
            scannedAt: Date()
        )
    }

    static func combine(_ results: [(LocalScanTarget, ScanResult)]) -> ScanResult {
        let roots = results.map(\.1.root).sorted { lhs, rhs in
            if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.size > rhs.size
        }
        let root = DiskNode(
            name: "모든 로컬 저장소",
            url: nil,
            size: roots.reduce(0) { safeAdd($0, $1.size) },
            kind: .folder,
            children: roots,
            fileCount: roots.reduce(0) { $0 + $1.fileCount },
            folderCount: 1 + roots.reduce(0) { $0 + $1.folderCount }
        )
        let largestFiles = results
            .flatMap(\.1.largestFiles)
            .sorted { lhs, rhs in
                if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return lhs.size > rhs.size
            }

        return ScanResult(
            root: root,
            largestFiles: Array(largestFiles.prefix(300)),
            unreadableCount: results.reduce(0) { $0 + $1.1.unreadableCount },
            elapsed: results.reduce(0) { $0 + $1.1.elapsed },
            scannedAt: Date()
        )
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

    private static func makeScanPlan(
        url: URL,
        target: LocalScanTarget,
        excludedPaths: [String],
        depth: Int,
        budget: ScanPlanBudget
    ) -> ScanPlanNode {
        return autoreleasepool {
        let ownValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard ownValues?.isDirectory == true, ownValues?.isSymbolicLink != true else {
            return ScanPlanNode(url: url, depth: depth, children: [])
        }
        guard budget.hasCapacity else {
            return ScanPlanNode(url: url, depth: depth, children: [])
        }
        guard shouldExpand(url: url, target: target, depth: depth) else {
            return ScanPlanNode(url: url, depth: depth, children: [])
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return ScanPlanNode(url: url, depth: depth, children: [])
        }
        let candidates = entries.compactMap { entry -> (url: URL, isDirectory: Bool)? in
            guard !isExcluded(entry, paths: excludedPaths) else { return nil }
            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true else { return nil }
            return (entry, values?.isDirectory == true)
        }
        let prioritizedCandidates = candidates.sorted {
            let left = planPriority(for: $0.url)
            let right = planPriority(for: $1.url)
            return left == right
                ? $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                : left < right
        }
        let directoryCount = prioritizedCandidates.reduce(0) { $0 + ($1.isDirectory ? 1 : 0) }
        let fileCount = prioritizedCandidates.count - directoryCount
        guard directoryCount > 0, prioritizedCandidates.count <= 10_000, fileCount <= 128 else {
            return ScanPlanNode(url: url, depth: depth, children: [])
        }
        guard budget.reserve(prioritizedCandidates.count) else {
            return ScanPlanNode(url: url, depth: depth, children: [])
        }
        let children = prioritizedCandidates.map {
            let childBudget = branchBudgetLimit(parent: url, child: $0.url)
                .map { ScanPlanBudget(limit: $0) } ?? budget
            return makeScanPlan(
                url: $0.url,
                target: target,
                excludedPaths: excludedPaths,
                depth: depth + 1,
                budget: childBudget
            )
        }
        return children.isEmpty
            ? ScanPlanNode(url: url, depth: depth, children: [])
            : ScanPlanNode(url: url, depth: depth, children: children)
        }
    }

    private static func shouldExpand(url: URL, target: LocalScanTarget, depth: Int) -> Bool {
        if depth == 0 { return true }
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let expandable = Set([
            "/Applications",
            "/Users",
            home,
            home + "/Library",
            home + "/Library/Application Support",
            home + "/Library/Caches",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/Developer",
            "/Library",
            "/Library/Application Support",
            "/Library/Caches",
            "/Library/Developer",
            "/private",
            "/private/var",
            "/private/var/folders",
            "/opt",
            "/usr/local"
        ])
        if expandable.contains(path) { return true }

        let recursiveRoots: [(String, Int)] = [
            (home + "/Library/Application Support", 5),
            (home + "/Library/Caches", 4),
            (home + "/Library/Containers", 5),
            (home + "/Library/Group Containers", 7),
            (home + "/Library/Developer", 6),
            (home, 2),
            ("/Library/Application Support", 4),
            ("/Library/Developer", 5),
            ("/private/var/folders", 5),
            ("/opt", 5),
            ("/usr/local", 5)
        ]
        for (root, limit) in recursiveRoots where path.hasPrefix(root + "/") {
            let suffix = String(path.dropFirst(root.count + 1))
            if suffix.split(separator: "/").count <= limit { return true }
        }
        return false
    }

    private static func planPriority(for url: URL) -> Int {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home + "/Library" || path.hasPrefix(home + "/Library/") { return 0 }
        if path == "/Users" || path == home || path.hasPrefix(home + "/") { return 1 }
        if path == "/Applications" || path.hasPrefix("/Applications/") { return 2 }
        if path == "/Library" || path.hasPrefix("/Library/") { return 3 }
        if path == "/opt" || path.hasPrefix("/opt/") || path == "/usr/local" || path.hasPrefix("/usr/local/") { return 4 }
        if path == "/System" || path.hasPrefix("/System/") { return 9 }
        return 5
    }

    private static func branchBudgetLimit(parent: URL, child: URL) -> Int? {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        if parentPath == home + "/Library" {
            let independentlyPlanned = Set([
                home + "/Library/Application Support",
                home + "/Library/Caches",
                home + "/Library/Containers",
                home + "/Library/Group Containers",
                home + "/Library/Developer"
            ])
            if independentlyPlanned.contains(childPath) { return 500 }
        }
        if parentPath == home, childPath != home + "/Library" { return 100 }
        if parentPath == "/", childPath == "/Library" || childPath == "/opt" || childPath == "/usr/local" {
            return 300
        }
        return nil
    }

    private static func rebuild(
        plan: ScanPlanNode,
        targetName: String,
        resultsByPath: [String: ScanResult],
        childLimit: Int
    ) -> DiskNode? {
        if plan.children.isEmpty {
            return resultsByPath[plan.url.standardizedFileURL.path]?.root
        }
        let children = plan.children
            .compactMap { rebuild(plan: $0, targetName: targetName, resultsByPath: resultsByPath, childLimit: childLimit) }
            .sorted { lhs, rhs in
                if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return lhs.size > rhs.size
            }
        guard !children.isEmpty else { return nil }
        let displayed = compress(children: children, limit: childLimit)
        let name = plan.depth == 0
            ? targetName
            : (plan.url.lastPathComponent.isEmpty ? plan.url.path : plan.url.lastPathComponent)
        return DiskNode(
            name: name,
            url: plan.url,
            size: children.reduce(0) { safeAdd($0, $1.size) },
            kind: .folder,
            children: displayed,
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            folderCount: 1 + children.reduce(0) { $0 + $1.folderCount }
        )
    }

    private static func compress(children: [DiskNode], limit: Int) -> [DiskNode] {
        guard children.count > limit else { return children }
        let keepCount = max(1, limit - 1)
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

    private static func cloudProviderPaths(fileManager: FileManager) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        var urls = [
            home.appendingPathComponent("Library/CloudStorage", isDirectory: true),
            home.appendingPathComponent("Library/Mobile Documents", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/CloudDocs", isDirectory: true),
            home.appendingPathComponent("Library/Group Containers/group.com.apple.CloudDocs", isDirectory: true),
            home.appendingPathComponent("Dropbox", isDirectory: true),
            home.appendingPathComponent("OneDrive", isDirectory: true),
            home.appendingPathComponent("Google Drive", isDirectory: true)
        ]

        if let homeEntries = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in homeEntries {
                let name = entry.lastPathComponent.lowercased()
                if name.hasPrefix("onedrive") || name.hasPrefix("dropbox") || name.hasPrefix("google drive") {
                    urls.append(entry)
                }
            }
        }
        return Array(Set(urls.map { $0.standardizedFileURL.path })).sorted()
    }

    private static func safeAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }

    private static func isExcluded(_ url: URL, paths: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return paths.contains { excluded in
            path == excluded || (excluded != "/" && path.hasPrefix(excluded + "/"))
        }
    }
}

private final class ScanPlanNode: @unchecked Sendable {
    let url: URL
    let depth: Int
    let children: [ScanPlanNode]

    init(url: URL, depth: Int, children: [ScanPlanNode]) {
        self.url = url
        self.depth = depth
        self.children = children
    }

    var leaves: [ScanPlanNode] {
        children.isEmpty ? [self] : children.flatMap(\.leaves)
    }
}

private final class ScanPlanBudget {
    private var remaining: Int

    init(limit: Int) {
        self.remaining = max(0, limit)
    }

    var hasCapacity: Bool { remaining > 0 }

    func reserve(_ count: Int) -> Bool {
        guard count >= 0, count <= remaining else { return false }
        remaining -= count
        return true
    }
}

private actor ScanPlanQueue {
    private var leaves: [ScanPlanNode]
    private var index = 0

    init(leaves: [ScanPlanNode]) {
        self.leaves = leaves
    }

    func next() -> ScanPlanNode? {
        guard index < leaves.count else { return nil }
        defer { index += 1 }
        return leaves[index]
    }
}

private actor ScanErrorCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    var value: Int { count }
}

private final class ConcurrentScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let progressHandler: @Sendable (ScanProgress) -> Void
    private var latestByKey: [String: (items: Int, bytes: Int64)] = [:]
    private var totalItems = 0
    private var totalBytes: Int64 = 0

    init(progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.progressHandler = progress
    }

    func update(key: String, label: String, progress: ScanProgress) {
        lock.lock()
        let previous = latestByKey[key] ?? (0, 0)
        totalItems += max(0, progress.items - previous.items)
        totalBytes = safeAdd(totalBytes, max(0, progress.bytes - previous.bytes))
        latestByKey[key] = (progress.items, progress.bytes)
        let combined = ScanProgress(
            items: totalItems,
            bytes: totalBytes,
            currentPath: "\(label) · \(progress.currentPath)"
        )
        lock.unlock()
        progressHandler(combined)
    }

    private func safeAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
