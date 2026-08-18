// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DiskBloom",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DiskBloomCore", targets: ["DiskBloomCore"]),
        .executable(name: "DiskBloom", targets: ["DiskBloom"]),
        .executable(name: "diskbloom-scan", targets: ["DiskBloomScan"])
    ],
    targets: [
        .target(
            name: "DiskBloomCore",
            path: "Sources/DiskBloomCore"
        ),
        .executableTarget(
            name: "DiskBloom",
            dependencies: ["DiskBloomCore"],
            path: "Sources/DiskBloom"
        ),
        .executableTarget(
            name: "DiskBloomScan",
            dependencies: ["DiskBloomCore"],
            path: "Sources/DiskBloomScan"
        ),
        .testTarget(
            name: "DiskBloomCoreTests",
            dependencies: ["DiskBloomCore"],
            path: "Tests/DiskBloomCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
