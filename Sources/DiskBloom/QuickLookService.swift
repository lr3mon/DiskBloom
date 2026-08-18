import AppKit
@preconcurrency import QuickLookUI

final class QuickLookService: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookService()
    private var previewURL: URL?

    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
