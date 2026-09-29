import AppKit
import BrowserKit

/// #20 Moving to the Applications folder, so the app opens without a
/// warning and can update itself.
extension FeatureSelfTest {

    func distribution() async {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("SimpleBrowser-move-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        let home = scratch.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        let app = downloads.appendingPathComponent("SimpleBrowser.app")
        let binary = app.appendingPathComponent("Contents/MacOS/SimpleBrowser")
        let locked = scratch.appendingPathComponent("Applications")
        let mine = home.appendingPathComponent("Applications")
        try? fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("new".utf8).write(to: binary)
        // As a download is: quarantined, the app and everything in it.
        for path in [app.path, binary.path] {
            _ = setxattr(path, "com.apple.quarantine", "0081;66f0f0f0;Safari;", 21, 0, XATTR_NOFOLLOW)
        }
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        // An older copy is there already.
        try? fm.createDirectory(at: mine.appendingPathComponent("SimpleBrowser.app/Contents/MacOS"), withIntermediateDirectories: true)
        try? Data("old".utf8).write(to: mine.appendingPathComponent("SimpleBrowser.app/Contents/MacOS/SimpleBrowser"))

        let mover = ApplicationMover()
        mover.bundle = app
        mover.home = home
        mover.applicationFolders = [locked, mine]
        var asked = 0
        var relaunched: URL?
        var discarded: URL?
        mover.ask = { asked += 1; return (true, false) }
        mover.relaunch = { relaunched = $0 }
        mover.discard = { url in discarded = url; try? fm.removeItem(at: url) }
        BrowserSettings.neverOfferMove = false

        check("move: opened from Downloads, it offers to move", mover.location == .elsewhere && mover.location.shouldOfferMove)
        let moved = mover.offerIfNeeded()
        let destination = mine.appendingPathComponent("SimpleBrowser.app")
        check("move: …asking once, it moves to the first Applications folder it may write to", asked == 1 && moved == destination, mover.lastError as Any)
        check("move: …replacing the older copy", (try? String(contentsOf: destination.appendingPathComponent("Contents/MacOS/SimpleBrowser"), encoding: .utf8)) == "new")
        check("move: …without the download's quarantine, so it is not moved away again",
              getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0
              && getxattr(destination.appendingPathComponent("Contents/MacOS/SimpleBrowser").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0)
        check("move: …the copy in Downloads goes", discarded == app && !fm.fileExists(atPath: app.path))
        check("move: …and it opens again from there", relaunched == destination)
        check("move: nothing is left half way", (try? fm.contentsOfDirectory(atPath: mine.path)) == ["SimpleBrowser.app"])

        let fromApplications = ApplicationMover()
        fromApplications.bundle = destination
        fromApplications.home = home
        fromApplications.ask = { asked += 1; return (true, false) }
        fromApplications.relaunch = { _ in }
        check("move: from an Applications folder, it asks nothing", fromApplications.offerIfNeeded() == nil && asked == 1)

        let fromImage = ApplicationMover()
        fromImage.bundle = URL(fileURLWithPath: "/Volumes/SimpleBrowser/SimpleBrowser.app")
        fromImage.home = home
        fromImage.ask = { (false, true) }
        check("move: from the disk image, the original is not the person's to throw away", fromImage.location == .diskImage && !fromImage.location.removesOriginal)
        _ = fromImage.offerIfNeeded()
        check("move: “Don't ask again” is kept", BrowserSettings.neverOfferMove)
        fromImage.ask = { asked += 1; return (true, false) }
        check("move: …and then it does not ask", fromImage.offerIfNeeded() == nil && asked == 1)
        BrowserSettings.neverOfferMove = false
        check("move: this test run was not offered a move", self.app.mover.lastError == nil)
    }
}
