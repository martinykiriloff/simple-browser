import AppKit
import BrowserKit

/// On a launch from anywhere but an Applications folder, offers to move
/// the app there, as many Mac apps do: from the disk image or Downloads,
/// macOS runs a temporary read-only copy that can never update itself.
///
/// The copy made keeps nothing of the download's quarantine: Gatekeeper
/// has already checked the app that is running, and a quarantined copy
/// would be moved to a temporary place again at its first launch.
@MainActor
final class ApplicationMover {
    var bundle: URL = Bundle.main.bundleURL
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Where it goes: /Applications, or ~/Applications when that cannot be written to.
    var applicationFolders: [URL] = [URL(fileURLWithPath: "/Applications"),
                                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    /// The question: Move, or not, and whether never to ask again.
    var ask: @MainActor () -> (move: Bool, never: Bool) = { ApplicationMover.askPerson() }
    /// Opens the moved app and quits this one.
    var relaunch: @MainActor (URL) -> Void = { ApplicationMover.relaunch($0) }

    /// Puts the original in the Trash.
    var discard: @MainActor (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    private(set) var lastError: String?

    var location: AppLocation { AppLocation.of(bundlePath: bundle.path, home: home.path) }

    /// At launch: asks, when there is something to ask, and moves.
    /// Returns where it moved to, if it did.
    @discardableResult
    func offerIfNeeded() -> URL? {
        guard bundle.pathExtension == "app", location.shouldOfferMove, !BrowserSettings.neverOfferMove else { return nil }
        let answer = ask()
        if answer.never { BrowserSettings.neverOfferMove = true }
        guard answer.move else { return nil }
        do {
            let moved = try move()
            relaunch(moved)
            return moved
        } catch {
            lastError = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "Keel could not be moved"
            alert.informativeText = "\(error.localizedDescription)\n\nDrag it to the Applications folder in the Finder instead."
            if !QuietMode.isOn { alert.runModal() }
            return nil
        }
    }

    /// Copies the app into the first Applications folder it can write to,
    /// replacing an older copy there, without the quarantine; then puts
    /// the original in the Trash when it is the person's own copy.
    func move() throws -> URL {
        let fm = FileManager.default
        guard let folder = applicationFolders.first(where: { folder in
            (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil && fm.isWritableFile(atPath: folder.path)
        }) else { throw CocoaError(.fileWriteNoPermission) }
        let destination = folder.appendingPathComponent(bundle.lastPathComponent)
        let staged = folder.appendingPathComponent("." + bundle.lastPathComponent + "-\(UUID().uuidString)")
        try fm.copyItem(at: bundle, to: staged)
        Self.removeQuarantine(staged)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        if location.removesOriginal { discard(bundle) }
        return destination
    }

    static func removeQuarantine(_ url: URL) {
        let name = "com.apple.quarantine"
        let paths = [url.path] + ((FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []).map { url.path + "/" + $0 }
        for path in paths { removexattr(path, name, XATTR_NOFOLLOW) }
    }

    static func askPerson() -> (move: Bool, never: Bool) {
        let alert = NSAlert()
        alert.messageText = "Move Keel to the Applications folder?"
        alert.informativeText = "From there it opens without a warning and keeps itself up to date. Opened from the downloaded disk image or from Downloads, it cannot update."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Do Not Move")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        let response = alert.runModal()
        return (response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
    }

    /// Waits for this process to end, then opens the moved app.
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", app.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
