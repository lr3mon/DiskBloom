import Foundation
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
