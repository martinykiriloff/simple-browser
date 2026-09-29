import AppKit
import WebKit
import BrowserKit

/// One tab's downloads: "Save Link As…" and "Save Image As…" from the
/// context menu, which ask where, and files a page hands over instead of
/// showing (`Content-Disposition: attachment`, a zip, a dmg), which go
/// straight to the downloads folder as in every browser.
///
/// The downloads themselves belong to the profile's `DownloadManager`; this
/// is the tab's way in, and its account of what it started.
@MainActor
final class DownloadController {
    weak var webView: WKWebView?
    var manager: DownloadManager
    /// The page the tab is on, recorded with what it downloads.
    var page: (() -> URL?)?
    /// Overrides the downloads folder for this tab. The self-tests point it at a scratch folder.
    var downloadsDirectory: URL?
    /// Replaces the save panel, for the self-test.
    var chooseDestination: ((String) async -> URL?)?

    private var started: [UUID] = []

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func download(_ url: URL, askWhere: Bool) {
        guard let webView else { return }
        manager.start(url, in: webView, page: page?(), askWhere: askWhere, folder: downloadsDirectory, choose: chooseDestination) { [weak self] id in
            self?.started.append(id)
        }
    }

    /// A navigation or link WebKit turned into a download.
    func adopt(_ download: WKDownload, askWhere: Bool = false) {
        manager.adopt(download, page: page?(), askWhere: askWhere, window: webView?.window, folder: downloadsDirectory, choose: chooseDestination) { [weak self] id in
            self?.started.append(id)
        }
    }

    /// What this tab started, as the manager has it now.
    var items: [DownloadItem] { started.compactMap { manager.list[$0] } }
    /// Finished downloads, oldest first.
    var finished: [URL] { items.filter { $0.state == .finished }.map { URL(fileURLWithPath: $0.path) } }
    var failures: [String] { items.filter { $0.state == .failed }.map { "\($0.fileName): \($0.failure ?? "failed")" } }
}
