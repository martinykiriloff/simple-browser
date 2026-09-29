import AppKit
import WebKit
import BrowserKit

/// #12 Downloads.
extension FeatureSelfTest {

    /// The fixture's slow file: byte i is (i * 31) % 251.
    private func isSlowFile(_ path: String, size: Int) -> Bool {
        guard let data = FileManager.default.contents(atPath: path), data.count == size else { return false }
        for index in stride(from: 0, to: size, by: 9973) where data[index] != UInt8((index * 31) % 251) { return false }
        return data[size - 1] == UInt8(((size - 1) * 31) % 251)
    }

    func downloads() async {
        let browser = first
        let manager = browser.downloads.manager
        manager.openFiles = false
        await manager.forgetAll()   // earlier sections (permissions) download too
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBrowser-feature-downloads-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        BrowserSettings.downloadFolder = scratch
        BrowserSettings.askWhereToSave = false
        defer { BrowserSettings.downloadFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
        await open("/second", in: browser)
        _ = await js("await fetch('/downloads/reset')", in: browser)
        func requests() async -> [[String: Any]] {
            (await js("return await (await fetch('/downloads/requests')).json()", in: browser) as? [[String: Any]]) ?? []
        }
        func item(named name: String) -> DownloadItem? { manager.list.items.first { $0.fileName == name } }

        check("downloads: there is no downloads button before the first download", browser.toolbarItemIsHidden("downloads"))

        // A download under way.
        let size = 2_400_000
        browser.downloads.download(URL(string: site + "/slow.bin?size=\(size)&rate=400000&name=film.bin")!, askWhere: false)
        check("downloads: a download appears in the list as it starts", await waitFor { item(named: "film.bin")?.state == .downloading }, manager.list.items.map(\.fileName))
        guard let film = item(named: "film.bin") else { return }
        check("downloads: …with the page it came from", film.page?.absoluteString == site + "/second" && film.source == "127.0.0.1", film.page as Any)
        check("downloads: …going into the folder chosen in Settings", film.path == scratch.appendingPathComponent("film.bin").path, film.path)
        check("downloads: the button appears with it", await waitFor { !browser.toolbarItemIsHidden("downloads") })
        check("downloads: …and every toolbar button still fits", browser.overflowingToolbarItems.isEmpty, browser.overflowingToolbarItems)
        check("downloads: progress is followed", await waitFor { (manager.list[film.id]?.received ?? 0) > 200_000 && manager.list[film.id]?.total == Int64(size) }, manager.list[film.id] as Any)
        check("downloads: …with how fast and how long", await waitFor { manager.status(of: manager.list[film.id]!).contains("/s · ") && manager.status(of: manager.list[film.id]!).hasSuffix(" left") },
              manager.status(of: manager.list[film.id]!))
        check("downloads: …and the button shows how far", manager.list.fraction != nil)

        browser.showDownloads(nil)
        check("downloads: the button opens the list", await waitFor { browser.downloadsList?.rows.first?.nameLabel.stringValue == "film.bin" })
        check("downloads: …where the download can be paused", browser.downloadsList?.rows.first?.primaryTitle == "Pause")
        await pause(0.4)
        snapshot(browser.downloadsList?.view.window, "downloads-popover")
        snapshot(browser.window, "downloads-button")

        // Pause and resume.
        browser.downloadsList?.rows.first?.primaryButton.performClick(nil)
        check("downloads: Pause pauses", await waitFor { manager.list[film.id]?.state == .paused }, manager.list[film.id]?.state as Any)
        let paused = manager.list[film.id]?.received ?? 0
        check("downloads: …keeping what it needs to go on", manager.list[film.id]?.canResume == true)
        await pause(1)
        check("downloads: …and nothing more arrives", manager.list[film.id]?.received == paused)
        check("downloads: the row now offers Resume", await waitFor { browser.downloadsList?.rows.first?.primaryTitle == "Resume" }, browser.downloadsList?.rows.first?.primaryTitle)
        check("downloads: …and says how far it got", browser.downloadsList?.rows.first?.statusLabel.stringValue.hasPrefix("Paused · ") == true)
        browser.downloadsList?.rows.first?.primaryButton.performClick(nil)
        check("downloads: Resume goes on", await waitFor { manager.list[film.id]?.state == .downloading }, manager.list[film.id]?.state as Any)
        check("downloads: …to the end", await waitFor(15) { manager.list[film.id]?.state == .finished }, manager.list[film.id] as Any)
        check("downloads: the file is whole and right, byte for byte", isSlowFile(film.path, size: size))
        let asked = await requests()
        check("downloads: it went on from where it stopped, not from the start", asked.count == 2 && ((asked.last?["start"] as? NSNumber)?.intValue ?? 0) > 100_000, asked)
        check("downloads: the finished row says its size and where from", browser.downloadsList?.rows.first?.statusLabel.stringValue.hasSuffix(" · 127.0.0.1") == true,
              browser.downloadsList?.rows.first?.statusLabel.stringValue)
        let quarantine = (try? URL(fileURLWithPath: film.path).resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        check("downloads: the file is marked as downloaded from the web", quarantine?[kLSQuarantineAgentNameKey as String] as? String == "SimpleBrowser"
              && (quarantine?[kLSQuarantineTypeKey as String] as? String) == (kLSQuarantineTypeWebDownload as String), quarantine as Any)
        check("downloads: clicking a finished download opens it", await {
            browser.downloadsList?.open(film.id)
            return await waitFor { manager.opened == [film.path] }
        }())

        // Cancel.
        browser.downloads.download(URL(string: site + "/slow.bin?size=3000000&rate=300000&name=unwanted.bin")!, askWhere: false)
        _ = await waitFor { (item(named: "unwanted.bin")?.received ?? 0) > 100_000 }
        if let unwanted = item(named: "unwanted.bin") {
            browser.downloadsList?.refresh()
            browser.downloadsList?.rows.first { $0.id == unwanted.id }?.removeButton.performClick(nil)
            check("downloads: Cancel stops a download", await waitFor { manager.list[unwanted.id]?.state == .cancelled })
            check("downloads: …and removes what was saved of it", !FileManager.default.fileExists(atPath: unwanted.path))
        }

        // The same name twice.
        browser.downloads.download(URL(string: site + "/slow.bin?size=50000&rate=500000&name=film.bin")!, askWhere: false)
        check("downloads: a second file of the same name does not replace the first", await waitFor { item(named: "film (2).bin")?.state == .finished }, manager.list.items.map(\.fileName))
        check("downloads: …which is untouched", isSlowFile(film.path, size: size))

        // A download that fails.
        browser.downloads.download(URL(string: site + "/broken.bin")!, askWhere: false)
        check("downloads: a connection lost half way is a failed download, saying why", await waitFor(10) { item(named: "broken.bin")?.state == .failed && item(named: "broken.bin")?.failure?.isEmpty == false },
              item(named: "broken.bin") as Any)

        // A file that can run.
        browser.downloads.download(URL(string: site + "/setup.command")!, askWhere: false)
        check("downloads: a file that can run is downloaded like any other", await waitFor { item(named: "setup.command")?.state == .finished })
        if let setup = item(named: "setup.command") {
            check("downloads: …and marked as needing a second look", setup.needsConfirmation && item(named: "film.bin")?.needsConfirmation == false)
            browser.downloadsList?.confirmRisk = { _ in false }
            browser.downloadsList?.open(setup.id)
            await pause(0.5)
            check("downloads: opening it asks first, and Cancel opens nothing", !manager.opened.contains(setup.path))
            browser.downloadsList?.confirmRisk = { _ in true }
            browser.downloadsList?.open(setup.id)
            check("downloads: …Open opens it", await waitFor { manager.opened.contains(setup.path) })
            check("downloads: …and it is not asked about again", manager.list[setup.id]?.needsConfirmation == false)
        }
        browser.downloadsPopover?.close()

        // Ask where to save each file.
        BrowserSettings.askWhereToSave = true
        let chosen = scratch.appendingPathComponent("elsewhere/named by hand.bin")
        try? FileManager.default.createDirectory(at: chosen.deletingLastPathComponent(), withIntermediateDirectories: true)
        var offered: [String] = []
        browser.downloads.chooseDestination = { name in offered.append(name); return chosen }
        browser.downloads.download(URL(string: site + "/slow.bin?size=40000&rate=400000&name=asked.bin")!, askWhere: false)
        check("downloads: with “Ask where to save each file”, it asks", await waitFor { offered == ["asked.bin"] }, offered)
        check("downloads: …and saves where it was told", await waitFor { FileManager.default.fileExists(atPath: chosen.path) && item(named: "named by hand.bin")?.state == .finished })
        browser.downloads.chooseDestination = { _ in nil }
        let before = manager.list.items.count
        browser.downloads.download(URL(string: site + "/slow.bin?size=40000&rate=400000&name=declined.bin")!, askWhere: false)
        await pause(1)
        check("downloads: Cancel in the save panel downloads nothing", manager.list.items.count == before && !FileManager.default.fileExists(atPath: scratch.appendingPathComponent("declined.bin").path))
        browser.downloads.chooseDestination = nil
        BrowserSettings.askWhereToSave = false

        // Settings.
        app.showSettings(nil)
        app.settingsWindow.show(.general)
        let settings = app.settingsWindow
        check("downloads: Settings shows the folder downloads go to", await waitFor { settings.downloadFolderPopUp.titleOfSelectedItem == FileManager.default.displayName(atPath: scratch.path) },
              settings.downloadFolderPopUp.titleOfSelectedItem)
        let other = scratch.appendingPathComponent("Chosen in Settings")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        settings.chooseDownloadFolder = { other }
        settings.downloadFolderPopUp.selectItem(withTitle: "Choose…")
        _ = settings.downloadFolderPopUp.target?.perform(settings.downloadFolderPopUp.action, with: settings.downloadFolderPopUp)
        check("downloads: Choose… changes it", BrowserSettings.downloadFolder.standardizedFileURL == other.standardizedFileURL
              && settings.downloadFolderPopUp.titleOfSelectedItem == "Chosen in Settings", settings.downloadFolderPopUp.titleOfSelectedItem)
        browser.downloads.download(URL(string: site + "/slow.bin?size=30000&rate=300000&name=there.bin")!, askWhere: false)
        check("downloads: …and the next download goes there", await waitFor { FileManager.default.fileExists(atPath: other.appendingPathComponent("there.bin").path) && item(named: "there.bin")?.state == .finished })
        settings.askWhereCheckbox.performClick(nil)
        check("downloads: “Ask where to save each file” is a setting", BrowserSettings.askWhereToSave && !settings.downloadFolderPopUp.isEnabled)
        settings.askWhereCheckbox.performClick(nil)
        let titles = settings.window?.contentView?.descendants(NSTextField.self).filter { $0.stringValue.hasSuffix(":") && !$0.isEditable } ?? []
        check("downloads: every title in Settings is shown whole", titles.count >= 6 && titles.allSatisfy { $0.frame.width >= $0.intrinsicContentSize.width - 0.5 },
              titles.filter { $0.frame.width < $0.intrinsicContentSize.width - 0.5 }.map(\.stringValue))
        await pause(0.3)
        snapshot(settings.window, "downloads-settings")
        settings.window?.close()
        BrowserSettings.downloadFolder = scratch

        // The Downloads window.
        let windowMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Window" }
        let menuItem = windowMenu?.items.first { $0.title == "Downloads" }
        check("downloads: Window → Downloads, ⌥⌘L", menuItem?.keyEquivalent == "l" && menuItem?.keyEquivalentModifierMask == [.command, .option], windowMenu?.items.map(\.title))
        browser.window?.makeKeyAndOrderFront(nil)
        app.showDownloadsWindow(nil)
        let all = app.downloadsWindow(for: browser.profile)
        check("downloads: the Downloads window lists every download", await waitFor { all?.window?.isVisible == true && all?.list.rows.count == manager.list.items.count }, all?.list.rows.count)
        check("downloads: …each with the page it came from", all?.list.rows.allSatisfy { !$0.pageLabel.isHidden && $0.pageLabel.stringValue == "From \(self.site)/second" } == true,
              all?.list.rows.map(\.pageLabel.stringValue))
        check("downloads: …what failed offering to try again, what was cancelled to download again", all?.list.rows.first { $0.nameLabel.stringValue == "broken.bin" }?.primaryTitle == "Try Again"
              && all?.list.rows.first { $0.nameLabel.stringValue == "unwanted.bin" }?.primaryTitle == "Download Again", all?.list.rows.map(\.primaryTitle))
        await pause(0.3)
        snapshot(all?.window, "downloads-window")
        all?.list.rows.first { $0.nameLabel.stringValue == "unwanted.bin" }?.primaryButton.performClick(nil)
        check("downloads: Download Again downloads it again", await waitFor(15) { item(named: "unwanted.bin")?.state == .finished }, item(named: "unwanted.bin") as Any)
        all?.list.clearButton.performClick(nil)
        check("downloads: Clear empties the list of what is over", await waitFor { manager.list.items.isEmpty && all?.list.rows.isEmpty == true }, manager.list.items.map(\.fileName))
        check("downloads: …and leaves the files where they are", FileManager.default.fileExists(atPath: film.path))
        all?.window?.close()

        // A private window's downloads are its own.
        app.newPrivateWindow(nil)
        _ = await waitFor { self.app.browserControllers.contains { $0.isPrivate } }
        if let secret = app.browserControllers.last(where: \.isPrivate) {
            secret.downloads.manager.openFiles = false
            secret.load(URL(string: site + "/second")!)
            _ = await waitFor { !secret.pageWebView.isLoading && secret.pageWebView.url?.path == "/second" }
            secret.downloads.download(URL(string: site + "/slow.bin?size=30000&rate=300000&name=private.bin")!, askWhere: false)
            check("downloads: a private window downloads", await waitFor { secret.downloads.manager.list.items.first?.state == .finished })
            check("downloads: …into its own list, not the profile's", manager.list.items.isEmpty && secret.downloads.manager !== manager)
            check("downloads: …which is kept nowhere", secret.downloads.manager.directory == nil)
            secret.window?.close()
        }
        browser.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Across a relaunch (scripts/test-downloads.sh)

    /// First launch: a download is started and paused, then the app quits.
    func downloadsSeed() async {
        let browser = first
        let manager = browser.downloads.manager
        guard let folder = manager.directory?.appendingPathComponent("Files") else {
            check("downloads: (setup) the test was given a folder with --downloads-dir", false)
            return
        }
        BrowserSettings.downloadFolder = folder
        await open("/second", in: browser)
        _ = await js("await fetch('/downloads/reset')", in: browser)
        browser.downloads.download(URL(string: site + "/slow.bin?size=3000000&rate=500000&name=large.bin")!, askWhere: false)
        check("downloads: a large download is under way", await waitFor { (manager.list.items.first?.received ?? 0) > 400_000 }, manager.list.items.first as Any)
        guard let id = manager.list.items.first?.id else { return }
        await manager.pause(id)
        check("downloads: …and paused, part of the way", manager.list[id]?.state == .paused && manager.list[id]?.canResume == true
              && (manager.list[id]?.received ?? 0) < 3_000_000, manager.list[id] as Any)
        check("downloads: the list is on disk", FileManager.default.fileExists(atPath: manager.directory!.appendingPathComponent("Downloads.json").path))
        // A second one left running: what quitting does to a download under way.
        browser.downloads.download(URL(string: site + "/slow.bin?size=3000000&rate=300000&name=running.bin")!, askWhere: false)
        check("downloads: another is left running as the app quits", await waitFor { (manager.list.items.first { $0.fileName == "running.bin" }?.received ?? 0) > 200_000 })
    }

    /// Second launch: both are there, paused, and go on to the end.
    func downloadsVerify() async {
        let browser = first
        let manager = browser.downloads.manager
        BrowserSettings.downloadFolder = manager.directory?.appendingPathComponent("Files") ?? BrowserSettings.downloadFolder
        await open("/second", in: browser)
        let large = manager.list.items.first { $0.fileName == "large.bin" }
        let running = manager.list.items.first { $0.fileName == "running.bin" }
        check("downloads: after a relaunch the paused download is in the list, paused", large?.state == .paused && large?.canResume == true, manager.list.items)
        check("downloads: …as far as it had got", (large?.received ?? 0) > 400_000, large?.received as Any)
        check("downloads: the one that was running when the app quit was paused, not lost", running?.state == .paused && running?.canResume == true, running as Any)
        check("downloads: the button is there for them, though nothing was downloaded this launch", !browser.toolbarItemIsHidden("downloads"))
        guard let large, let running else { return }
        await manager.resume(large.id, in: browser.pageWebView)
        await manager.resume(running.id, in: browser.pageWebView)
        check("downloads: both go on", await waitFor { manager.list[large.id]?.state == .downloading && manager.list[running.id]?.state == .downloading })
        check("downloads: …to the end", await waitFor(25) { manager.list[large.id]?.state == .finished && manager.list[running.id]?.state == .finished }, manager.list.items.map(\.state))
        check("downloads: the files are whole and right", isSlowFile(large.path, size: 3_000_000) && isSlowFile(running.path, size: 3_000_000))
        let asked = (await js("return await (await fetch('/downloads/requests')).json()", in: browser) as? [[String: Any]]) ?? []
        let resumed = asked.filter { (($0["start"] as? NSNumber)?.intValue ?? 0) > 0 }
        check("downloads: each went on from where it stopped", resumed.count == 2, asked)
    }
}

private extension NSView {
    /// Every view of the given type beneath this one, in depth-first order.
    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        subviews.flatMap { view in [view as? T].compactMap { $0 } + view.descendants(type) }
    }
}
