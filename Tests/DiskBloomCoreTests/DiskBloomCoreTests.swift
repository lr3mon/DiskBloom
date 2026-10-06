import Foundation
import Darwin
import XCTest
@testable import DiskBloomCore

final class DiskBloomCoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskBloomTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testScannerAggregatesFilesAndSkipsSymbolicLinks() throws {
        let a = temporaryDirectory.appendingPathComponent("A", isDirectory: true)
        let b = a.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000).write(to: temporaryDirectory.appendingPathComponent("small.bin"))
        try Data(repeating: 2, count: 20_000).write(to: a.appendingPathComponent("medium.bin"))
        try Data(repeating: 3, count: 200_000).write(to: b.appendingPathComponent("large.bin"))
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent("loop"),
            withDestinationURL: temporaryDirectory
        )

        let result = try DiskScanner().scan(url: temporaryDirectory)

        XCTAssertEqual(result.root.fileCount, 3)
        XCTAssertEqual(result.root.folderCount, 3)
        XCTAssertGreaterThan(result.root.size, 0)
        XCTAssertEqual(result.largestFiles.first?.name, "large.bin")
        XCTAssertFalse(result.root.children.contains { $0.name == "loop" })
    }

    func testCollapsedDepthStillCountsNestedContent() throws {
        var folder = temporaryDirectory!
        for index in 0..<5 {
            folder = folder.appendingPathComponent("d\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(repeating: 4, count: 50_000).write(to: folder.appendingPathComponent("deep.dat"))

        let options = DiskScanner.Options(maximumTreeDepth: 2)
        let result = try DiskScanner(options: options).scan(url: temporaryDirectory)

        XCTAssertEqual(result.root.fileCount, 1)
        XCTAssertEqual(result.root.folderCount, 6)
        XCTAssertEqual(result.largestFiles.first?.name, "deep.dat")
    }

    func testCancellationBeforeScan() throws {
        let token = ScanCancellationToken()
        token.cancel()
        let scanner = DiskScanner(cancellationToken: token)

        XCTAssertThrowsError(try scanner.scan(url: temporaryDirectory)) { error in
            guard case DiskScanError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
    }

    func testChildCompressionPreservesTotalCounts() throws {
        for index in 0..<30 {
            try Data(repeating: UInt8(index % 255), count: 1_000 + index)
                .write(to: temporaryDirectory.appendingPathComponent("file-\(index).dat"))
        }

        let options = DiskScanner.Options(maximumChildrenPerFolder: 8)
        let result = try DiskScanner(options: options).scan(url: temporaryDirectory)

        XCTAssertEqual(result.root.fileCount, 30)
        XCTAssertEqual(result.root.children.count, 8)
        XCTAssertEqual(result.root.children.last?.kind, .aggregate)
        XCTAssertEqual(result.root.children.reduce(0) { $0 + $1.fileCount }, 30)
    }

    func testFormatting() {
        XCTAssertTrue(DiskBloomFormat.bytes(1_000_000).contains("MB"))
        XCTAssertEqual(DiskBloomFormat.duration(65), "1분 5초")
        XCTAssertEqual(DiskBloomFormat.count(1_234), "1,234")
    }

    func testExcludedPathsAreNotCounted() throws {
        let local = temporaryDirectory.appendingPathComponent("local", isDirectory: true)
        let cloud = temporaryDirectory.appendingPathComponent("CloudStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: local.appendingPathComponent("keep.dat"))
        try Data(repeating: 2, count: 100_000).write(to: cloud.appendingPathComponent("skip.dat"))

        let options = DiskScanner.Options(excludedPaths: [cloud.path])
        let result = try DiskScanner(options: options).scan(url: temporaryDirectory)

        XCTAssertEqual(result.root.fileCount, 1)
        XCTAssertEqual(result.largestFiles.first?.name, "keep.dat")
        XCTAssertFalse(result.root.children.contains { $0.name == "CloudStorage" })
    }

    func testSnapshotRoundTrip() throws {
        let node = DiskNode(
            name: "Root",
            url: temporaryDirectory,
            size: 42,
            kind: .folder,
            fileCount: 1,
            folderCount: 1
        )
        let original = ScanResult(root: node, largestFiles: [], unreadableCount: 3, elapsed: 1.25)
        let encoded = try JSONEncoder().encode(DiskScanSnapshot(result: original))
        let restored = try JSONDecoder().decode(DiskScanSnapshot.self, from: encoded).result

        XCTAssertEqual(restored.root.name, "Root")
        XCTAssertEqual(restored.root.size, 42)
        XCTAssertEqual(restored.unreadableCount, 3)
        XCTAssertEqual(restored.elapsed, 1.25, accuracy: 0.001)
    }

    func testBulkMetadataMatchesFoundationForSparseFilesAndResourceForks() throws {
        let sparse = temporaryDirectory.appendingPathComponent("희소 파일.dat")
        let descriptor = sparse.path.withCString { Darwin.open($0, O_CREAT | O_RDWR, 0o600) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 64 * 1024 * 1024), 0)
        var byte: UInt8 = 1
        XCTAssertEqual(pwrite(descriptor, &byte, 1, 63 * 1024 * 1024), 1)

        let forked = temporaryDirectory.appendingPathComponent("resource-fork.dat")
        try Data(repeating: 2, count: 1_024).write(to: forked)
        let fork = Data(repeating: 3, count: 32_768)
        let forkStatus = forked.path.withCString { path in
            fork.withUnsafeBytes { bytes in
                setxattr(path, "com.apple.ResourceFork", bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        XCTAssertEqual(forkStatus, 0)

        let hardLink = temporaryDirectory.appendingPathComponent("hard-link.dat")
        try FileManager.default.linkItem(at: forked, to: hardLink)
        let fifo = temporaryDirectory.appendingPathComponent("pipe")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        try Data().write(to: temporaryDirectory.appendingPathComponent(".hidden"))

        let bulk = try DiskScanner().scan(url: temporaryDirectory)
        let reference = try DiskScanner(options: .init(metadataStrategy: .foundation)).scan(url: temporaryDirectory)
        assertEquivalentTrees(bulk.root, reference.root)
        XCTAssertEqual(bulk.unreadableCount, reference.unreadableCount)
        XCTAssertEqual(bulk.root.fileCount, 4)
        XCTAssertLessThan(bulk.root.size, 64 * 1024 * 1024)
        XCTAssertFalse(bulk.root.children.contains { $0.name == "pipe" })
    }

    func testBulkReadsMultipleBatchesAndSelectsNaturalNameOrder() throws {
        for index in 0..<4_000 {
            try Data().write(to: temporaryDirectory.appendingPathComponent("item-\(index).dat"))
        }
        let result = try DiskScanner(options: .init(maximumChildrenPerFolder: 8)).scan(url: temporaryDirectory)
        XCTAssertEqual(result.root.fileCount, 4_000)
        XCTAssertEqual(result.root.children.dropLast().map(\.name), (0..<7).map { "item-\($0).dat" })
        XCTAssertEqual(result.root.children.last?.kind, .aggregate)
        XCTAssertEqual(result.root.children.last?.fileCount, 3_993)
        XCTAssertEqual(result.root.children.reduce(0) { $0 + $1.size }, result.root.size)
        XCTAssertEqual(result.unreadableCount, 0)
    }

    func testSelectionKeepsLargestChildrenAndFiles() throws {
        for index in 0..<40 {
            try Data(repeating: 1, count: (index + 1) * 8_192)
                .write(to: temporaryDirectory.appendingPathComponent("item-\(index).dat"))
        }
        let result = try DiskScanner(options: .init(maximumChildrenPerFolder: 8, largestFileLimit: 10)).scan(url: temporaryDirectory)
        XCTAssertEqual(result.root.children.dropLast().map(\.name), (33..<40).reversed().map { "item-\($0).dat" })
        XCTAssertEqual(result.largestFiles.map(\.name), (30..<40).reversed().map { "item-\($0).dat" })
        XCTAssertEqual(result.root.children.reduce(0) { $0 + $1.size }, result.root.size)
        XCTAssertEqual(result.root.children.reduce(0) { $0 + $1.fileCount }, 40)
        XCTAssertEqual(result.root.children.first?.id, result.largestFiles.first?.id)
    }

    func testCompressionBoundaryRetainsAllChildrenAtLimit() throws {
        for index in 0..<8 {
            try Data().write(to: temporaryDirectory.appendingPathComponent("item-\(index).dat"))
        }
        let result = try DiskScanner(options: .init(maximumChildrenPerFolder: 8)).scan(url: temporaryDirectory)
        XCTAssertEqual(result.root.children.count, 8)
        XCTAssertTrue(result.root.children.allSatisfy { $0.kind == .file })
    }

    func testCollapsedBulkTraversalPreservesExclusionsAndSkipsLinks() throws {
        let excluded = temporaryDirectory.appendingPathComponent("skip", isDirectory: true)
        let sibling = temporaryDirectory.appendingPathComponent("skip-sibling/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8_192).write(to: excluded.appendingPathComponent("excluded.dat"))
        try Data(repeating: 2, count: 16_384).write(to: sibling.appendingPathComponent("keep.dat"))
        try FileManager.default.createSymbolicLink(at: sibling.appendingPathComponent("loop"), withDestinationURL: temporaryDirectory)

        let bulk = try DiskScanner(options: .init(maximumTreeDepth: 0, excludedPaths: [excluded.path + "/"])).scan(url: temporaryDirectory)
        let reference = try DiskScanner(options: .init(maximumTreeDepth: 0, excludedPaths: [excluded.path], metadataStrategy: .foundation)).scan(url: temporaryDirectory)
        assertEquivalentTrees(bulk.root, reference.root)
        XCTAssertEqual(bulk.root.fileCount, 1)
        XCTAssertEqual(bulk.root.folderCount, 3)
        XCTAssertEqual(bulk.largestFiles.first?.name, "keep.dat")
    }

    func testUnreadableDirectoryDoesNotDiscardReadableSiblings() throws {
        let denied = temporaryDirectory.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8_192).write(to: denied.appendingPathComponent("hidden.dat"))
        try Data(repeating: 2, count: 16_384).write(to: temporaryDirectory.appendingPathComponent("readable.dat"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }

        let bulk = try DiskScanner().scan(url: temporaryDirectory)
        let reference = try DiskScanner(options: .init(metadataStrategy: .foundation)).scan(url: temporaryDirectory)
        assertEquivalentTrees(bulk.root, reference.root)
        XCTAssertEqual(bulk.unreadableCount, reference.unreadableCount)
        if geteuid() != 0 {
            XCTAssertEqual(bulk.unreadableCount, 1)
            XCTAssertEqual(bulk.root.fileCount, 1)
        }
    }

    func testCancellationFromProgressAndScannerReuse() throws {
        try Data(repeating: 1, count: 8_192).write(to: temporaryDirectory.appendingPathComponent("file.dat"))
        let token = ScanCancellationToken()
        XCTAssertThrowsError(try DiskScanner(cancellationToken: token).scan(url: temporaryDirectory) { _ in token.cancel() }) { error in
            guard case DiskScanError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        let scanner = DiskScanner()
        let first = try scanner.scan(url: temporaryDirectory)
        let second = try scanner.scan(url: temporaryDirectory)
        assertEquivalentTrees(first.root, second.root)
        XCTAssertEqual(second.largestFiles.count, 1)
    }

    func testCollapsedTraversalStopsAtExistingSimulatorMounts() throws {
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Cryptex", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("No simulator mount fixture on this Mac")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var files = 0
        var folders = 1
        var bytes: Int64 = 0
        var errors = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, _ in errors += 1; return true }) else {
            throw XCTSkip("Simulator mount fixture is inaccessible")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { folders += 1 }
            else {
                files += 1
                bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        let result = try DiskScanner(options: .init(maximumTreeDepth: 0)).scan(url: root)
        XCTAssertEqual(result.root.fileCount, files)
        XCTAssertEqual(result.root.folderCount, folders)
        XCTAssertEqual(result.root.size, bytes)
        XCTAssertEqual(result.unreadableCount, errors)
    }

    func testEnumerationMatchesFoundationAppleDoubleFiltering() throws {
        try Data(repeating: 1, count: 8_192).write(to: temporaryDirectory.appendingPathComponent(".hidden"))
        try Data(repeating: 2, count: 16_384).write(to: temporaryDirectory.appendingPathComponent("._metadata"))
        let folder = temporaryDirectory.appendingPathComponent("._folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 32_768).write(to: folder.appendingPathComponent("nested.dat"))
        for depth in [0, 2] {
            let result = try DiskScanner(options: .init(maximumTreeDepth: depth)).scan(url: temporaryDirectory)
            let reference = try DiskScanner(options: .init(maximumTreeDepth: depth, metadataStrategy: .foundation)).scan(url: temporaryDirectory)
            assertEquivalentTrees(result.root, reference.root)
            XCTAssertTrue(result.largestFiles.contains { $0.name == ".hidden" })
            XCTAssertFalse(result.largestFiles.contains { $0.name == "._metadata" })
        }
        // An explicitly selected file remains a valid scan root.
        let direct = try DiskScanner().scan(url: temporaryDirectory.appendingPathComponent("._metadata"))
        XCTAssertEqual(direct.root.fileCount, 1)
    }

    func testParallelScannerMatchesSerialTreeAndExclusions() async throws {
        for directory in 0..<3 {
            let folder = temporaryDirectory.appendingPathComponent("folder-\(directory)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in 0..<12 {
                try Data(repeating: 1, count: (directory * 12 + file + 1) * 8_192)
                    .write(to: folder.appendingPathComponent("file-\(file).dat"))
            }
        }
        try FileManager.default.createSymbolicLink(at: temporaryDirectory.appendingPathComponent("loop"), withDestinationURL: temporaryDirectory)
        let options = DiskScanner.Options(maximumTreeDepth: 2, maximumChildrenPerFolder: 8, largestFileLimit: 10,
                                          excludedPaths: [temporaryDirectory.appendingPathComponent("folder-1").path])
        let reference = try DiskScanner(options: options).scan(url: temporaryDirectory)
        let target = LocalScanTarget(id: "fixture", name: temporaryDirectory.lastPathComponent, url: temporaryDirectory, isSystemVolume: false)
        for workers in [1, 4] {
            let parallel = try await LocalStorageScanner.scan(target: target, options: options, cancellationToken: ScanCancellationToken(), maximumWorkers: workers)
            // The plan's reconstructed root has no modification date; leaf
            // metadata, retained trees, sizes and counts must still match.
            assertEquivalentTrees(parallel.root, reference.root, checkModifiedAt: false)
            XCTAssertEqual(parallel.largestFiles.map(\.path), reference.largestFiles.map(\.path))
            XCTAssertEqual(parallel.unreadableCount, reference.unreadableCount)
        }
    }

    func testParallelCancellationBeforePlanning() async throws {
        let token = ScanCancellationToken()
        token.cancel()
        let target = LocalScanTarget(id: "fixture", name: temporaryDirectory.lastPathComponent, url: temporaryDirectory, isSystemVolume: false)
        do {
            _ = try await LocalStorageScanner.scan(target: target, options: .init(), cancellationToken: token)
            XCTFail("Expected cancellation")
        } catch DiskScanError.cancelled {}
    }

    func testSharedVolumePolicyPreservesAPFSAndCloudExclusions() {
        let system = LocalScanTarget(id: "system", name: "System", url: URL(fileURLWithPath: "/"), isSystemVolume: true)
        let external = LocalScanTarget(id: "external", name: "External", url: URL(fileURLWithPath: "/Volumes/Fixture"), isSystemVolume: false)
        let systemPaths = LocalStorageScanner.excludedPaths(for: system)
        let externalPaths = LocalStorageScanner.excludedPaths(for: external)
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage").path
        XCTAssertTrue(systemPaths.contains("/System/Volumes/Data"))
        XCTAssertTrue(systemPaths.contains("/Library/Developer/CoreSimulator/Volumes"))
        XCTAssertTrue(systemPaths.contains("/Volumes"))
        XCTAssertTrue(systemPaths.contains(cloud))
        XCTAssertTrue(externalPaths.contains(cloud))
        XCTAssertFalse(externalPaths.contains("/Volumes"))
    }

    func testBulkBufferReusePreservesNestedUnicodeEntries() throws {
        for index in 0..<40 {
            let folder = temporaryDirectory.appendingPathComponent("폴더-\(index)-😀/cafe\u{301}", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in 0..<3 {
                try Data(repeating: 1, count: (index * 3 + file + 1) * 8_192)
                    .write(to: folder.appendingPathComponent("문서-\(file)-é-😀.dat"))
            }
        }
        let options = DiskScanner.Options(maximumTreeDepth: 4, largestFileLimit: 10)
        let scanner = DiskScanner(options: options)
        let first = try scanner.scan(url: temporaryDirectory)
        let reference = try DiskScanner(options: .init(maximumTreeDepth: 4, largestFileLimit: 10, metadataStrategy: .foundation)).scan(url: temporaryDirectory)
        let second = try scanner.scan(url: temporaryDirectory)
        assertEquivalentTrees(first.root, reference.root)
        assertEquivalentTrees(second.root, reference.root)
        XCTAssertEqual(first.root.fileCount, 120)
        XCTAssertEqual(first.largestFiles.map(\.path), reference.largestFiles.map(\.path))
        XCTAssertEqual(second.largestFiles.map(\.path), first.largestFiles.map(\.path))
    }

    func testParallelPlanningRetainsContentAfterFileSplitLimit() async throws {
        let nested = temporaryDirectory.appendingPathComponent("excluded-neighbor/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16_384).write(to: nested.appendingPathComponent("nested.dat"))
        for index in 0..<150 {
            try Data(repeating: 2, count: 8_192).write(to: temporaryDirectory.appendingPathComponent("file-\(index).dat"))
        }
        let excluded = temporaryDirectory.appendingPathComponent("excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 65_536).write(to: excluded.appendingPathComponent("skip.dat"))
        let options = DiskScanner.Options(maximumTreeDepth: 3, maximumChildrenPerFolder: 8, excludedPaths: [excluded.path])
        let reference = try DiskScanner(options: options).scan(url: temporaryDirectory)
        let target = LocalScanTarget(id: "fixture", name: temporaryDirectory.lastPathComponent, url: temporaryDirectory, isSystemVolume: false)
        let result = try await LocalStorageScanner.scan(target: target, options: options, cancellationToken: ScanCancellationToken(), maximumWorkers: 8)
        assertEquivalentTrees(result.root, reference.root)
        XCTAssertEqual(result.root.fileCount, 151)
        XCTAssertEqual(result.root.folderCount, 3)
        XCTAssertEqual(result.unreadableCount, 0)
    }

    private func assertEquivalentTrees(_ actual: DiskNode, _ expected: DiskNode, checkModifiedAt: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.name, expected.name, file: file, line: line)
        XCTAssertEqual(actual.path, expected.path, file: file, line: line)
        XCTAssertEqual(actual.kind, expected.kind, file: file, line: line)
        XCTAssertEqual(actual.size, expected.size, file: file, line: line)
        XCTAssertEqual(actual.fileCount, expected.fileCount, file: file, line: line)
        XCTAssertEqual(actual.folderCount, expected.folderCount, file: file, line: line)
        if checkModifiedAt {
            if let actualDate = actual.modifiedAt, let expectedDate = expected.modifiedAt {
                XCTAssertEqual(actualDate.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
            } else { XCTAssertEqual(actual.modifiedAt, expected.modifiedAt, file: file, line: line) }
        }
        XCTAssertEqual(actual.children.count, expected.children.count, file: file, line: line)
        for (child, reference) in zip(actual.children, expected.children) {
            assertEquivalentTrees(child, reference, file: file, line: line)
        }
    }

    func testDeletionPolicyProtectsRootAndSyntheticNodes() {
        let root = DiskNode(
            name: "Root",
            url: temporaryDirectory,
            size: 10,
            kind: .folder,
            fileCount: 1,
            folderCount: 1
        )
        let file = DiskNode(
            name: "file.dat",
            url: temporaryDirectory.appendingPathComponent("file.dat"),
            size: 10,
            kind: .file,
            fileCount: 1,
            folderCount: 0
        )
        let synthetic = DiskNode(
            name: "기타 항목",
            url: nil,
            size: 10,
            kind: .aggregate,
            fileCount: 1,
            folderCount: 0
        )

        XCTAssertFalse(DiskBloomDeletionPolicy.canMoveToTrash(root, root: root))
        XCTAssertFalse(DiskBloomDeletionPolicy.canMoveToTrash(synthetic, root: root))
        XCTAssertTrue(DiskBloomDeletionPolicy.canMoveToTrash(file, root: root))
    }

    func testDeletionPolicyProtectsVolumeHomeAndSystemRoots() {
        let overview = DiskNode(
            name: "All Local Storage",
            url: nil,
            size: 100,
            kind: .aggregate,
            fileCount: 1,
            folderCount: 1
        )
        let paths = [
            URL(fileURLWithPath: "/", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Volumes/External", isDirectory: true)
        ]

        for url in paths {
            let node = DiskNode(
                name: url.lastPathComponent,
                url: url,
                size: 100,
                kind: .folder,
                fileCount: 1,
                folderCount: 1
            )
            XCTAssertFalse(
                DiskBloomDeletionPolicy.canMoveToTrash(node, root: overview),
                "Expected protected path: \(url.path)"
            )
        }
    }
}
