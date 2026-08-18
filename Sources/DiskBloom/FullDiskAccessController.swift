import AppKit
import Darwin
import Foundation

@MainActor
final class FullDiskAccessController: ObservableObject {
    @Published private(set) var isGranted = false
    @Published private(set) var statusMessage: String?

    init() {
        isGranted = Self.checkAccess()
    }

    @discardableResult
    func refresh(showFailureMessage: Bool = false) -> Bool {
        isGranted = Self.checkAccess()
        statusMessage = isGranted
            ? "전체 디스크 접근 권한이 확인되었습니다."
            : (showFailureMessage ? "아직 권한이 확인되지 않습니다. 설정에서 DiskBloom을 켠 뒤 다시 확인해 주세요." : nil)
        return isGranted
    }

    func openSystemSettings() {
        statusMessage = "시스템 설정에서 DiskBloom을 추가하거나 토글을 켠 뒤 이 창으로 돌아오세요."
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func checkAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        return probe.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let descriptor = Darwin.open(path, O_RDONLY)
            guard descriptor >= 0 else { return false }
            Darwin.close(descriptor)
            return true
        }
    }
}
