import AppKit
import SwiftUI

extension Notification.Name {
    static let diskBloomChooseFolder = Notification.Name("DiskBloomChooseFolder")
    static let diskBloomRescan = Notification.Name("DiskBloomRescan")
}

@MainActor
final class DiskBloomAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DiskBloomApp: App {
    @NSApplicationDelegateAdaptor(DiskBloomAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DiskBloom", id: "main") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("폴더 열기…") {
                    NotificationCenter.default.post(name: .diskBloomChooseFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("스캔") {
                Button("전체 로컬 저장소 다시 스캔") {
                    NotificationCenter.default.post(name: .diskBloomRescan, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
