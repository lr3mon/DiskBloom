import DiskBloomCore
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let path = arguments.first ?? FileManager.default.homeDirectoryForCurrentUser.path
let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
let token = ScanCancellationToken()
let scanner = DiskScanner(cancellationToken: token)

signal(SIGINT) { _ in
    token.cancel()
}

fputs("DiskBloom scan: \(url.path)\n", stderr)

do {
    let result = try scanner.scan(url: url) { progress in
        let line = "\r\(DiskBloomFormat.count(progress.items))개 · \(DiskBloomFormat.bytes(progress.bytes)) · \(progress.currentPath.prefix(70))"
        fputs(line, stderr)
        fflush(stderr)
    }
    fputs("\n", stderr)
    print("총 용량: \(DiskBloomFormat.bytes(result.root.size))")
    print("파일: \(DiskBloomFormat.count(result.root.fileCount))개")
    print("폴더: \(DiskBloomFormat.count(result.root.folderCount))개")
    print("읽기 실패: \(DiskBloomFormat.count(result.unreadableCount))개")
    print("소요 시간: \(DiskBloomFormat.duration(result.elapsed))")
    print("\n가장 큰 파일")
    for file in result.largestFiles.prefix(20) {
        print("\(DiskBloomFormat.bytes(file.size))\t\(file.path)")
    }
} catch {
    fputs("\n오류: \(error.localizedDescription)\n", stderr)
    exit(1)
}
