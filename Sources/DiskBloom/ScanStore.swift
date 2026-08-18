import AppKit
import DiskBloomCore
import Foundation

struct BloomAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class ScanStore: ObservableObject {
    @Published var selectedURL = URL(fileURLWithPath: "/", isDirectory: true)
    @Published var result: ScanResult?
    @Published var progress = ScanProgress(items: 0, bytes: 0, currentPath: "")
    @Published var isScanning = false
    @Published var statusText = "저장된 분석 결과를 확인하는 중…"
    @Published var alert: BloomAlert?
    @Published private(set) var indexedLocations: [IndexedLocation] = []
    @Published private(set) var selectedLocationID = "overview"
    @Published private(set) var cachedAt: Date?

    private let snapshotCache: DiskSnapshotCache
    private var masterResult: ScanResult?
    private var isShowingCachedIndex = false
    private var scanTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var cancellationToken: ScanCancellationToken?

    init(snapshotCache: DiskSnapshotCache = DiskSnapshotCache()) {
        self.snapshotCache = snapshotCache

        do {
            if let cached = try snapshotCache.load() {
                masterResult = cached
                result = cached
                indexedLocations = LocalStorageIndex.locations(in: cached)
                cachedAt = cached.scannedAt
                selectedLocationID = "overview"
                selectedURL = URL(fileURLWithPath: "/", isDirectory: true)
                isShowingCachedIndex = true
                statusText = "저장된 분석 · \(cached.scannedAt.formatted(date: .abbreviated, time: .shortened))"
            }
        } catch {
            statusText = "저장된 결과를 읽지 못해 새로 분석합니다"
        }

    }

    var needsInitialScan: Bool {
        masterResult == nil
    }

    func startAutomaticScanIfNeeded() {
        guard masterResult == nil, !isScanning else { return }
        refreshAllLocalStorage()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "스캔할 폴더 선택"
        panel.prompt = "이 폴더 스캔"
        panel.message = "직접 선택한 폴더는 임시로 분석하며 전체 저장소 스냅샷에는 합치지 않습니다."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = selectedURL
        if panel.runModal() == .OK, let url = panel.url {
            startScan(url)
        }
    }

    func selectLocation(_ id: String) {
        guard
            let masterResult,
            let location = indexedLocations.first(where: { $0.id == id })
        else { return }

        selectedLocationID = id
        selectedURL = location.node.url ?? URL(fileURLWithPath: "/", isDirectory: true)
        result = LocalStorageIndex.result(for: location.node, in: masterResult)
        isShowingCachedIndex = true
        statusText = "저장된 분석 · \(masterResult.scannedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func refreshAllLocalStorage() {
        stopScan(silent: true)
        let targets = LocalStorageIndex.discoverTargets()
        guard !targets.isEmpty else {
            alert = BloomAlert(title: "로컬 저장소를 찾지 못했습니다", message: "마운트된 로컬 볼륨이 없습니다.")
            return
        }

        let token = ScanCancellationToken()
        let cache = snapshotCache
        cancellationToken = token
        isScanning = true
        progress = ScanProgress(items: 0, bytes: 0, currentPath: targets[0].url.path)
        statusText = "전체 로컬 저장소 분석 시작"

        let (progressStream, progressContinuation) = AsyncStream<ScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        progressTask = Task { [weak self] in
            for await update in progressStream {
                guard let self, self.isScanning else { return }
                self.progress = update
                self.statusText = "\(DiskBloomFormat.count(update.items))개 항목 분석 중"
            }
        }

        scanTask = Task { [weak self] in
            do {
                let combined = try await Task.detached(priority: .userInitiated) {
                    var collected: [(LocalScanTarget, ScanResult)] = []
                    var itemOffset = 0
                    var byteOffset: Int64 = 0

                    for (index, target) in targets.enumerated() {
                        if token.isCancelled { throw DiskScanError.cancelled }
                        let currentItemOffset = itemOffset
                        let currentByteOffset = byteOffset
                        let options = DiskScanner.Options(
                            maximumTreeDepth: 4,
                            maximumChildrenPerFolder: 80,
                            largestFileLimit: 300,
                            progressItemInterval: 128,
                            excludedPaths: LocalStorageIndex.excludedPaths(for: target)
                        )
                        let scanResult = try await LocalStorageIndex.scan(
                            target: target,
                            options: options,
                            cancellationToken: token
                        ) { update in
                            progressContinuation.yield(
                                ScanProgress(
                                    items: currentItemOffset + update.items,
                                    bytes: currentByteOffset + update.bytes,
                                    currentPath: "\(index + 1)/\(targets.count) \(target.name) · \(update.currentPath)"
                                )
                            )
                        }
                        collected.append((target, scanResult))
                        itemOffset += scanResult.root.fileCount + scanResult.root.folderCount
                        byteOffset = Self.safeAdd(byteOffset, scanResult.root.size)
                    }
                    return LocalStorageIndex.combine(collected)
                }.value
                progressContinuation.finish()

                guard let self, !Task.isCancelled else { return }
                self.finishProgressTasks()
                self.applyMasterResult(combined)

                do {
                    try await Task.detached(priority: .utility) {
                        try cache.save(combined)
                    }.value
                    self.statusText = "분석 저장 완료 · \(combined.scannedAt.formatted(date: .abbreviated, time: .shortened))"
                } catch {
                    self.alert = BloomAlert(
                        title: "분석은 완료했지만 저장하지 못했습니다",
                        message: error.localizedDescription
                    )
                }
            } catch DiskScanError.cancelled {
                progressContinuation.finish()
                guard let self else { return }
                self.finishProgressTasks()
                self.statusText = self.masterResult == nil ? "전체 분석을 취소했습니다" : "갱신을 취소하고 저장된 결과를 유지합니다"
            } catch {
                progressContinuation.finish()
                guard let self else { return }
                self.finishProgressTasks()
                NSLog("DiskBloom local index failed: %@", String(describing: error))
                self.statusText = self.masterResult == nil ? "전체 분석 실패" : "갱신 실패 · 저장된 결과 유지"
                self.alert = BloomAlert(title: "로컬 저장소를 분석하지 못했습니다", message: error.localizedDescription)
            }
        }
    }

    func startScan(_ url: URL) {
        stopScan(silent: true)
        selectedURL = url
        selectedLocationID = "custom:\(url.standardizedFileURL.path)"
        result = nil
        isShowingCachedIndex = false
        progress = ScanProgress(items: 0, bytes: 0, currentPath: url.path)
        isScanning = true
        statusText = "선택한 폴더 분석 중…"

        let token = ScanCancellationToken()
        cancellationToken = token
        let scanner = DiskScanner(cancellationToken: token)
        let (progressStream, progressContinuation) = AsyncStream<ScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        progressTask = Task { [weak self] in
            for await update in progressStream {
                guard let self, self.isScanning else { return }
                self.progress = update
                self.statusText = "\(DiskBloomFormat.count(update.items))개 항목 분석 중"
            }
        }

        scanTask = Task { [weak self] in
            do {
                let scanResult = try await Task.detached(priority: .userInitiated) {
                    try scanner.scan(url: url) { update in
                        progressContinuation.yield(update)
                    }
                }.value
                progressContinuation.finish()

                guard let self, !Task.isCancelled else { return }
                self.finishProgressTasks()
                self.result = scanResult
                self.statusText = "임시 분석 · \(DiskBloomFormat.count(scanResult.root.fileCount))개 파일"
            } catch DiskScanError.cancelled {
                progressContinuation.finish()
                guard let self else { return }
                self.finishProgressTasks()
                self.statusText = "스캔을 취소했습니다"
            } catch {
                progressContinuation.finish()
                guard let self else { return }
                self.finishProgressTasks()
                self.statusText = "스캔 실패"
                self.alert = BloomAlert(title: "폴더를 읽을 수 없습니다", message: error.localizedDescription)
            }
        }
    }

    func stopScan(silent: Bool = false) {
        cancellationToken?.cancel()
        scanTask?.cancel()
        progressTask?.cancel()
        scanTask = nil
        progressTask = nil
        cancellationToken = nil
        if isScanning {
            isScanning = false
            if !silent {
                statusText = masterResult == nil ? "스캔을 취소했습니다" : "저장된 결과를 유지합니다"
            }
        }
    }

    func reveal(_ node: DiskNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ node: DiskNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.open(url)
    }

    func preview(_ node: DiskNode) {
        guard let url = node.url else { return }
        QuickLookService.shared.show(url)
    }

    func moveToTrash(_ node: DiskNode) {
        guard
            let root = result?.root,
            let url = node.url,
            DiskBloomDeletionPolicy.canMoveToTrash(node, root: root)
        else { return }

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            statusText = "‘\(node.name)’을(를) 휴지통으로 이동했습니다"
            if isShowingCachedIndex {
                NotificationCenter.default.post(name: .diskBloomRescan, object: nil)
            } else if let rootURL = result?.root.url {
                startScan(rootURL)
            }
        } catch {
            alert = BloomAlert(title: "휴지통으로 이동하지 못했습니다", message: error.localizedDescription)
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyMasterResult(_ master: ScanResult) {
        masterResult = master
        result = master
        indexedLocations = LocalStorageIndex.locations(in: master)
        cachedAt = master.scannedAt
        selectedLocationID = "overview"
        selectedURL = URL(fileURLWithPath: "/", isDirectory: true)
        isShowingCachedIndex = true
    }

    private func finishProgressTasks() {
        progressTask?.cancel()
        progressTask = nil
        scanTask = nil
        cancellationToken = nil
        isScanning = false
    }

    nonisolated private static func safeAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
