import AppKit
import WebKit

/// Downloads for one window: "Save Link As…" and "Save Image As…" from the
/// context menu, which ask where, and files a page hands over instead of
/// showing (`Content-Disposition: attachment`, a zip, a dmg), which go
/// straight to Downloads as in every browser.
///
/// Through `WKDownload`, so the request carries the profile's cookies: a
/// file behind a sign-in downloads as the signed-in person.
@MainActor
final class DownloadController: NSObject, WKDownloadDelegate {
    weak var webView: WKWebView?
    /// Where downloads that do not ask go. The self-test points it at a scratch folder.
    var downloadsDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    /// Replaces the save panel, for the self-test.
    var chooseDestination: ((String) async -> URL?)?

    private var asking: Set<ObjectIdentifier> = []
    private var destinations: [ObjectIdentifier: URL] = [:]
    /// Finished downloads, newest last.
    private(set) var finished: [URL] = []
    private(set) var failures: [String] = []

    func download(_ url: URL, askWhere: Bool) {
        webView?.startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated { self?.adopt(download, askWhere: askWhere) }
        }
    }

    /// A navigation or link WebKit turned into a download.
    func adopt(_ download: WKDownload, askWhere: Bool = false) {
        download.delegate = self
        if askWhere { asking.insert(ObjectIdentifier(download)) }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let name = Self.safeFileName(suggestedFilename)
        let destination: URL?
        if asking.remove(ObjectIdentifier(download)) != nil {
            destination = await ask(name)
        } else {
            destination = Self.unique(downloadsDirectory.appendingPathComponent(name))
        }
        if let destination { destinations[ObjectIdentifier(download)] = destination }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        finished.append(url)
        // What Safari posts: the Downloads stack in the Dock bounces.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let url = destinations.removeValue(forKey: ObjectIdentifier(download))
        failures.append("\(url?.lastPathComponent ?? "download"): \(error.localizedDescription)")
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func ask(_ name: String) async -> URL? {
        if let chooseDestination { return await chooseDestination(name) }
        guard let window = webView?.window else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloadsDirectory
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return nil }
        // The panel already asked about replacing; WebKit refuses to write over a file.
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// A name that is safe as a file name: no path separators, no control
    /// characters, not hidden, not empty, not absurdly long.
    static func safeFileName(_ proposed: String) -> String {
        let cleaned = proposed.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || "/:\\".unicodeScalars.contains($0) ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let name = cleaned.isEmpty ? "download" : cleaned
        return name.count > 200 ? String(name.prefix(200)) : name
    }

    /// `report.pdf`, then `report (2).pdf`, as Finder names copies.
    static func unique(_ url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        for n in 2... {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
