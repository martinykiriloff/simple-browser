import AppKit
import WebKit
import BrowserKit

/// Developer aid (`--feature-selftest <file>`, run by `scripts/test-features.sh`):
/// the roadmap features, each in its own section, against the fixture site in
/// `Tests/Fixtures/page`. Acts through the same menu actions, key equivalents
/// and page events a person would, then reads what happened.
///
/// Settings go to a scratch suite, so nothing here touches the person's own.
@MainActor
final class FeatureSelfTest {
    let app: AppDelegate
    let first: BrowserWindowController
    let site = "http://127.0.0.1:8767"
    private var failures: [String] = []
    private var environment: [String] = []
    /// What could not be tested where the run took place, and why. Said,
    /// not failed: the run is as good as its checks.
    private var skipped: [String] = []
    private var passed = 0
    private let snapshots: String?

    init(app: AppDelegate, browser: BrowserWindowController, snapshots: String?) {
        self.app = app
        self.first = browser
        self.snapshots = snapshots
    }

    static func run(app: AppDelegate, browser: BrowserWindowController, output: String, snapshots: String?, only: Set<String>, quitWhenDone: Bool = false) {
        let test = FeatureSelfTest(app: app, browser: browser, snapshots: snapshots)
        Task { @MainActor in
            let suite = "Keel.feature-selftest"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let scratch = UserDefaults(suiteName: suite) { BrowserSettings.store = scratch }
            BrowserSettings.newWindowContent = .empty
            BrowserSettings.showFavoritesBar = true
            BrowserSettings.searchSuggestions = false   // never ask a real search engine
            await test.pause(1)
            // "session-seed" and "session-verify" belong to scripts/test-session.sh,
            // either side of a SIGKILL: they run only when named.
            for (name, section) in test.sections where only.isEmpty ? !name.hasPrefix("session-") : only.contains(name) {
                await section()
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let report: [String: Any] = [
                "passed": test.failures.isEmpty && test.environment.isEmpty,
                "checksPassed": test.passed,
                "failures": test.failures,
                "environment": test.environment,
                "skipped": test.skipped,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            // Quits as a person would, so what quitting does (pausing downloads) happens.
            // From the run loop, not this task: a terminate that waits (.terminateLater)
            // runs a nested loop that cannot service the main queue this task is on.
            if quitWhenDone { RunLoop.main.perform { NSApp.terminate(nil) } }
        }
    }

    /// One entry per ticket, in the order they were built.
    var sections: [(String, () async -> Void)] {
        [("tabs", tabs), ("hibernation", hibernation), ("session", sessionRoundTrip), ("history", history), ("bookmarks", bookmarks), ("address-bar", addressBar),
         ("blocking", blocking), ("find", find), ("zoom", zoom), ("reader", reader), ("private", privateWindows), ("permissions", permissions), ("certificates", certificates), ("downloads", downloads), ("sidebar", sidebar), ("split", splitView), ("import", importing), ("extensions", webExtensions), ("autofill", autofillForms), ("distribution", distribution), ("media", media), ("polish", polish),
         ("session-seed", sessionSeed), ("session-verify", sessionVerify),
         ("session-downloads-seed", downloadsSeed), ("session-downloads-verify", downloadsVerify)]
    }

    // MARK: - Helpers

    func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
        if ok { passed += 1 } else { failures.append(detail.map { "\(name): \($0)" } ?? name) }
        FileHandle.standardError.write(Data("[selftest] \(ok ? "ok" : "FAIL") \(name)\(ok ? "" : detail.map { ": \($0)" } ?? "")\n".utf8))
    }

    func skip(_ why: String) {
        skipped.append(why)
        FileHandle.standardError.write(Data("[selftest] skipped \(why)\n".utf8))
    }

    func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    func waitFor(_ seconds: Double = 6, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            await pause(0.1)
        }
        return await condition()
    }

    func snapshot(_ window: NSWindow?, _ name: String) {
        guard let snapshots, let window else { return }
        window.displayIfNeeded()
        AppDelegate.snapshot(window, to: snapshots + "/" + name + ".png")
    }

    func js(_ script: String, in browser: BrowserWindowController) async -> Any? {
        try? await browser.evaluateInPage(script)
    }

    func open(_ path: String, in browser: BrowserWindowController) async {
        browser.load(URL(string: site + path)!)
        _ = await waitFor {
            guard browser.currentURL?.absoluteString == site + path else { return false }
            return (await js("return document.readyState", in: browser) as? String) == "complete"
        }
        await pause(0.3)
    }

    /// The selected tab of the first test window's group. Not "the key
    /// window": that is nil whenever the app is not active, which a person
    /// clicking elsewhere during the run would cause.
    var front: BrowserWindowController? {
        let selected = first.window?.tabGroup?.selectedWindow ?? first.window
        return app.browserControllers.first { $0.window === selected }
    }

    func tabs(of browser: BrowserWindowController) -> [NSWindow] { browser.window?.tabbedWindows ?? [browser.window].compactMap { $0 } }

    func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    /// A real click on the element, as the window server would deliver it,
    /// so WebKit sees the modifier keys a synthetic DOM event cannot carry.
    func click(_ id: String, in browser: BrowserWindowController, modifiers: NSEvent.ModifierFlags = []) async -> Bool {
        guard let rect = await js("const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.left + Math.min(10, r.width / 2), r.top + r.height / 2]", in: browser) as? [NSNumber],
              rect.count == 2, let window = browser.window else { return false }
        let webView = browser.pageWebView
        var point = NSPoint(x: rect[0].doubleValue * webView.pageZoom, y: rect[1].doubleValue * webView.pageZoom)
        if !webView.isFlipped { point.y = webView.bounds.height - point.y }
        let location = webView.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            window.sendEvent(event)
        }
        return true
    }

    // MARK: - #5 Smart address bar

    func addressBar() async {
        let browser = first
        browser.window?.makeKeyAndOrderFront(nil)
        guard let history = app.history(for: browser.profile) else { return }
        try? history.deleteVisits(since: .distantPast)
        await open("/tabs", in: browser)
        await open("/second", in: browser)
        let other = app.newTab(beside: browser, url: URL(string: site + "/long"))
        _ = await waitFor { other.currentURL?.path == "/long" && !other.pageWebView.isLoading }
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === browser }

        check("address bar: not editing, it shows the site", browser.addressText == "127.0.0.1", browser.addressText)

        browser.typeInAddressBar("127.0")
        check("address bar: typing completes the site inline", browser.addressEditorText == "127.0.0.1:8767", browser.addressEditorText)
        check("address bar: suggestions appear", !browser.suggestionTitles.isEmpty)
        check("address bar: the typed search is offered", browser.suggestionKinds.contains(.search))

        browser.typeInAddressBar("Long")
        check("address bar: an open tab is offered as Switch to Tab", browser.suggestionKinds.first.map { if case .switchToTab = $0 { return true } else { return false } } ?? false,
              browser.suggestionTitles)
        browser.pressInAddressBar(#selector(NSResponder.moveDown(_:)))
        browser.pressInAddressBar(#selector(NSResponder.insertNewline(_:)))
        check("address bar: …choosing it switches to that tab", await waitFor { self.front === other })
        check("address bar: …without reloading it", other.pageWebView.url?.path == "/long")

        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === browser }
        browser.typeInAddressBar("127.0")
        browser.pressInAddressBar(#selector(NSResponder.insertNewline(_:)))
        check("address bar: Return goes to the completed site", await waitFor { browser.currentURL?.absoluteString == self.site + "/" }, browser.currentURL as Any)
        check("address bar: …and it counts as typed", await waitFor { ((try? history.page(for: URL(string: self.site + "/")!))??.typedCount ?? 0) > 0 })

        browser.typeInAddressBar("swift concurrency")
        browser.pressInAddressBar(#selector(NSResponder.insertNewline(_:)))
        check("address bar: words are searched with the chosen engine", await waitFor { browser.currentURL?.host() == "duckduckgo.com" }, browser.currentURL as Any)
        browser.pageWebView.stopLoading()

        BrowserSettings.searchEngine = SearchEngine.all.first { $0.id == "bing" }!
        browser.typeInAddressBar("hello world")
        browser.pressInAddressBar(#selector(NSResponder.insertNewline(_:)))
        check("address bar: changing the engine changes the search", await waitFor { browser.currentURL?.host() == "www.bing.com" }, browser.currentURL as Any)
        browser.pageWebView.stopLoading()
        BrowserSettings.searchEngine = .default

        // ⇧⌫ forgets a history suggestion. An address no tab has open: a
        // page that is open is offered as its tab, not as history.
        await open("/second?forget=1", in: browser)
        await open("/tabs", in: browser)
        browser.typeInAddressBar("forget")
        let before = browser.suggestionKinds
        if let index = before.firstIndex(of: .history) {
            for _ in 0...index { browser.pressInAddressBar(#selector(NSResponder.moveDown(_:))) }
            browser.removeSelectedSuggestionForTest()
            check("address bar: ⇧⌫ removes a history suggestion", (try? history.page(for: URL(string: self.site + "/second?forget=1")!)) == nil)
            check("address bar: …and it leaves the list", !browser.suggestionKinds.contains(.history), browser.suggestionTitles)
        } else {
            check("address bar: (setup) a history suggestion to remove", false, browser.suggestionTitles)
        }
        browser.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))
        browser.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))

        // After a suggestion was chosen the list is emptied; typing again
        // must start a new one. (This crashed: a stale selected row.)
        browser.typeInAddressBar("Long")
        browser.pressInAddressBar(#selector(NSResponder.moveDown(_:)))
        browser.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))
        browser.typeInAddressBar("Lon")
        check("address bar: typing after the list was dismissed offers a new list", !browser.suggestionTitles.isEmpty)
        browser.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))
        browser.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))

        // With the scheme out of sight, the indicator is what tells http from https.
        await open("/second", in: browser)
        check("address bar: a page on this Mac says so", await waitFor { browser.securityLabel == "This page is on this Mac" }, browser.securityLabel)
        check("address bar: …without the words Not Secure", browser.securityTitle.isEmpty, browser.securityTitle)
        browser.window?.layoutIfNeeded()
        check("address bar: the address starts after the indicator, not under it",
              browser.securityIndicatorEnd > 0 && browser.addressTextStart >= browser.securityIndicatorEnd, "\(browser.addressTextStart) vs \(browser.securityIndicatorEnd)")
        browser.showPageSecurity(nil)
        check("address bar: clicking the indicator explains it", browser.securityPopover?.isShown == true)
        snapshot(browser.window, "address-bar-security")
        browser.securityPopover?.close()

        // The start page's search box.
        browser.load(StartPageSchemeHandler.url)
        _ = await waitFor { StartPageSchemeHandler.isStartPage(browser.pageWebView.url) && !browser.pageWebView.isLoading }
        check("address bar: the browser's own page shows no indicator", await waitFor { browser.securityLabel.isEmpty }, browser.securityLabel)
        check("address bar: …and leaves no gap for one", browser.addressTextStart < 12, browser.addressTextStart)
        let placeholder = await js("return document.querySelector('input[name=q]').placeholder", in: browser) as? String
        check("start page: the search box names the engine", placeholder == "Search DuckDuckGo or enter an address", placeholder as Any)
        _ = await js("const q = document.querySelector('input[name=q]'); q.value = '\(site)/second'; q.form.submit()", in: browser)
        check("start page: an address typed into the search box is opened", await waitFor { browser.currentURL?.absoluteString == self.site + "/second" }, browser.currentURL as Any)

        BrowserSettings.searchEngine = SearchEngine.all.first { $0.id == "ecosia" }!
        browser.load(StartPageSchemeHandler.url)
        _ = await waitFor { StartPageSchemeHandler.isStartPage(browser.pageWebView.url) && !browser.pageWebView.isLoading }
        let changed = await js("return document.querySelector('input[name=q]').placeholder", in: browser) as? String
        check("start page: changing the engine changes the search box", changed == "Search Ecosia or enter an address", changed as Any)
        _ = await js("const q = document.querySelector('input[name=q]'); q.value = 'two words + c++'; q.form.submit()", in: browser)
        check("start page: words are searched with that engine, spaces and pluses intact",
              await waitFor { browser.currentURL?.absoluteString == "https://www.ecosia.org/search?q=two%20words%20%2B%20c%2B%2B" }, browser.currentURL as Any)
        browser.pageWebView.stopLoading()
        BrowserSettings.searchEngine = .default

        // Only the start page may use the search address.
        await open("/second", in: browser)
        _ = await js("location.href = 'keel://search?q=http://127.0.0.1:8767/long'", in: browser)
        await pause(1)
        check("start page: a web page cannot drive the browser's search box", browser.currentURL?.path == "/second", browser.currentURL as Any)

        // Edit → Paste and Go says what it will do. On a pasteboard of the
        // test's own: what the person has copied is not touched.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        browser.pasteboard = pasteboard
        let item = NSMenuItem(title: "Paste and Go", action: #selector(BrowserWindowController.pasteAndGo(_:)), keyEquivalent: "")
        pasteboard.clearContents()
        pasteboard.setString("example.com/docs", forType: .string)
        check("paste and go: an address on the clipboard is Paste and Go", browser.validateMenuItem(item) && item.title == "Paste and Go", item.title)
        pasteboard.clearContents()
        pasteboard.setString("how tall is everest", forType: .string)
        check("paste and go: words on the clipboard are Paste and Search", browser.validateMenuItem(item) && item.title == "Paste and Search", item.title)
        pasteboard.clearContents()
        pasteboard.setString(site + "/long", forType: .string)
        browser.pasteAndGo(nil)
        check("paste and go: it goes there", await waitFor { browser.currentURL?.path == "/long" }, browser.currentURL as Any)
        pasteboard.clearContents()
        check("paste and go: nothing to paste, nothing to do", !browser.validateMenuItem(item))
        browser.pasteboard = .general

        other.window?.close()
    }

    // MARK: - #7 Bookmarks, favorites bar, start page, reading list

    func bookmarks() async {
        let browser = first
        browser.window?.makeKeyAndOrderFront(nil)
        guard let store = app.bookmarks(for: browser.profile) else { check("bookmarks: the profile has bookmarks", false); return }

        BrowserSettings.newWindowContent = .startPage
        let fresh = app.newTab(beside: browser)
        check("bookmarks: a new tab opens the start page", await waitFor { StartPageSchemeHandler.isStartPage(fresh.pageWebView.url) && !fresh.pageWebView.isLoading })
        check("bookmarks: …with the address bar empty, ready to type", fresh.addressText.isEmpty, fresh.addressText)
        check("bookmarks: …titled Start Page", (await js("return document.title", in: fresh) as? String) == "Start Page")
        fresh.window?.close()
        BrowserSettings.newWindowContent = .empty
        browser.window?.makeKeyAndOrderFront(nil)

        await open("/second", in: browser)
        browser.addBookmark(nil)
        let popover = await waitFor { browser.lastBookmarkPopover?.isViewLoaded == true }
        check("bookmarks: ⌘D opens the bookmark popover", popover)
        if let editor = browser.lastBookmarkPopover {
            check("bookmarks: …named after the page", editor.titleField.stringValue == "Second", editor.titleField.stringValue)
            check("bookmarks: …in Favorites", editor.folderPopUp.titleOfSelectedItem == "Favorites")
            editor.done(nil)
        }
        check("bookmarks: Return saves it", (try? store.bookmark(for: URL(string: site + "/second")!)) != nil)
        check("bookmarks: …the favorites bar shows it", await waitFor { browser.favoritesBar.titles == ["Second"] }, browser.favoritesBar.titles)
        check("bookmarks: …the star fills in", browser.isStarFilled)

        await open("/tabs", in: browser)
        check("bookmarks: the star is empty on a page that is not bookmarked", !browser.isStarFilled)
        await open("/tabs", in: browser)   // a second visit makes it frequent
        browser.load(StartPageSchemeHandler.url)
        _ = await waitFor { StartPageSchemeHandler.isStartPage(browser.pageWebView.url) && !browser.pageWebView.isLoading }
        let tiles = await js("return Array.from(document.querySelectorAll('.tile .label')).map(e => e.textContent)", in: browser) as? [String] ?? []
        check("bookmarks: the start page shows favorites", tiles.contains("Second"), tiles)
        check("bookmarks: …and frequently visited sites", tiles.contains("Tabs"), tiles)

        // Reading list, with its offline copy.
        await open("/long", in: browser)
        browser.addToReadingList(nil)
        check("bookmarks: Add to Reading List (⇧⌘D) saves it", await waitFor { ((try? store.readingList()) ?? []).contains { $0.url.path == "/long" } })
        let item = try? store.readingList().first { $0.url.path == "/long" }
        let archive = item.map { app.readingListArchive(for: browser.profile, $0) }
        check("bookmarks: …with a copy to read offline", await waitFor(5) { archive.map { FileManager.default.fileExists(atPath: $0.path) } ?? false })

        // Offline: a reading-list page whose server cannot be reached opens from its copy.
        // An ordinary port nothing listens on (WebKit refuses the low "restricted" ones outright).
        let deadURL = URL(string: "http://127.0.0.1:59431/article")!
        if let archive, let deadID = try? store.addToReadingList(url: deadURL, title: "Offline article"),
           let deadItem = try? store.readingList().first(where: { $0.id == deadID }) {
            let copy = app.readingListArchive(for: browser.profile, deadItem)
            try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: archive, to: copy)
            browser.load(deadURL)
            check("bookmarks: offline, a reading-list page opens from its saved copy",
                  await waitFor(10) { browser.pageWebView.url?.isFileURL == true }, browser.pageWebView.url as Any)
            check("bookmarks: …and says so", browser.lastNotice?.contains("offline") == true, browser.lastNotice as Any)
        }

        // The Bookmarks menu, the manager and hiding the bar.
        let menu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Bookmarks" }?.submenu ?? NSMenu()
        app.bookmarksMenuFiller.menuNeedsUpdate(menu)
        let favoritesMenu = menu.items.first { $0.title == "Favorites" }?.submenu?.items.map(\.title) ?? []
        check("bookmarks: the Bookmarks menu lists favorites", favoritesMenu == ["Second"], favoritesMenu)
        app.showBookmarks(nil)
        let manager = NSApp.windows.first { $0.title.hasPrefix("Bookmarks —") }?.windowController as? BookmarksWindowController
        check("bookmarks: Show Bookmarks (⌥⌘B) opens the manager", manager != nil)
        check("bookmarks: …with Favorites open", (manager?.outline.numberOfRows ?? 0) >= 3, manager?.outline.numberOfRows as Any)
        snapshot(manager?.window, "bookmarks")
        manager?.window?.close()

        browser.toggleFavoritesBar(nil)
        check("bookmarks: ⇧⌘B hides the favorites bar", await waitFor { browser.window?.titlebarAccessoryViewControllers.contains(browser.favoritesBar) == false })
        browser.toggleFavoritesBar(nil)
        check("bookmarks: …and shows it again", await waitFor { browser.window?.titlebarAccessoryViewControllers.contains(browser.favoritesBar) == true })
        snapshot(browser.window, "favorites-bar")
    }

    // MARK: - #6 History

    func history() async {
        let browser = first
        browser.window?.makeKeyAndOrderFront(nil)
        guard let store = app.history(for: browser.profile) else { check("history: the profile has a history", false); return }
        try? store.deleteVisits(since: .distantPast)

        await open("/second", in: browser)
        browser.enterAddress(site + "/tabs")
        _ = await waitFor { browser.currentURL?.path == "/tabs" && !browser.pageWebView.isLoading }
        await pause(0.5)
        let visits = (try? store.visits()) ?? []
        check("history: visited pages are recorded, newest first", visits.map { $0.url.path } .prefix(2) == ["/tabs", "/second"], visits.map { $0.url.path })
        check("history: …with their titles", visits.first?.title == "Tabs", visits.first?.title as Any)
        check("history: a typed address counts as typed", (try? store.page(for: URL(string: site + "/tabs")!))??.typedCount == 1)

        await open("/spa", in: browser)
        _ = await js("document.getElementById('route').click()", in: browser)
        check("history: a single-page app's new address is recorded too",
              await waitFor { ((try? store.visits()) ?? []).contains { $0.url.path == "/spa/settings" } })
        check("history: …with its new title",
              await waitFor { (try? store.page(for: URL(string: self.site + "/spa/settings")!))??.title == "App settings" })

        let back = browser.historyMenu(back: true).items.map(\.title)
        check("history: holding Back lists this tab's pages, nearest first", back.first == "Single page app" && back.contains("Second"), back)

        let historyMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "History" }?.submenu ?? NSMenu()
        app.historyMenuFiller.menuNeedsUpdate(historyMenu)
        let menuTitles = historyMenu.items.filter { $0.tag == HistoryMenuFiller.tag }.map(\.title)
        check("history: the History menu lists recent pages", menuTitles.contains("Tabs"), menuTitles)

        app.showHistory(nil)
        let window = NSApp.windows.first { $0.title.hasPrefix("History —") }
        let controller = window?.windowController as? HistoryWindowController
        check("history: Show All History (⌘Y) opens the history window", controller != nil)
        if let controller {
            check("history: …grouped under Today", controller.outline.numberOfRows > 1)
            controller.searchField.stringValue = "second"
            controller.reload()
            check("history: …searchable", controller.outline.numberOfRows == 2, controller.outline.numberOfRows)
            controller.searchField.stringValue = ""
            controller.reload()
            snapshot(window, "history")
            window?.close()
        }

        // Clearing the last hour takes the cookies set in it too.
        _ = await js("document.cookie = 'visited=yes; max-age=3600'", in: browser)
        check("history: (setup) a cookie is set", (await js("return document.cookie", in: browser) as? String)?.contains("visited=yes") == true)
        await app.clearHistory(of: browser.profile, since: Date().addingTimeInterval(-3600))
        check("history: Clear History (last hour) removes the visits", (try? store.visits())?.isEmpty == true)
        await open("/second", in: browser)
        check("history: …and the cookies set in that hour", (await js("return document.cookie", in: browser) as? String)?.contains("visited=yes") != true)
    }

    // MARK: - #4 Session restore

    func sessionRoundTrip() async {
        let browser = first
        browser.window?.makeKeyAndOrderFront(nil)
        await open("/second", in: browser)
        await open("/tabs", in: browser)
        let middle = app.newTab(beside: browser, url: URL(string: site + "/long"))
        let last = app.newTab(beside: middle, url: URL(string: site + "/form"))
        _ = await waitFor { !middle.pageWebView.isLoading && !last.pageWebView.isLoading && last.currentURL?.path == "/form" }
        middle.window?.makeKeyAndOrderFront(nil)
        await pause(0.5)

        let snapshot = app.currentSession()
        let saved = snapshot.windows.first { $0.tabs.contains { $0.url?.path == "/long" } }
        check("session: the window is recorded with its tabs in order", saved?.tabs.map { $0.url?.path ?? "-" } == ["/tabs", "/long", "/form"],
              saved?.tabs.map { $0.url?.path ?? "-" } as Any)
        check("session: …and which one was in front", saved?.selected == 1, saved?.selected as Any)
        check("session: …and each tab's history", saved?.tabs.first?.state != nil)

        guard let saved else { return }
        let restored = app.restore(SessionSnapshot(windows: [saved]))
        guard let front = restored.first else { check("session: restore opened a window", false); return }
        let tabs = tabs(of: front).compactMap { window in app.browserControllers.first { $0.window === window } }
        check("session: restored with the same tabs, in order", tabs.map { $0.currentURL?.path ?? "-" } == ["/tabs", "/long", "/form"],
              tabs.map { $0.currentURL?.path ?? "-" })
        check("session: the tab that was in front is in front again", front.currentURL?.path == "/long")
        check("session: …and loads", await waitFor { front.pageWebView.url?.path == "/long" })
        check("session: the others wait, asleep, until opened", tabs.count == 3 && tabs[0].isHibernated && tabs[2].isHibernated)
        if tabs.count == 3 {
            tabs[0].window?.makeKeyAndOrderFront(nil)
            check("session: opening one wakes it on its page", await waitFor { tabs[0].pageWebView.url?.path == "/tabs" })
            check("session: …with its history", await waitFor(3) { tabs[0].pageWebView.canGoBack })
        }
        for tab in tabs { tab.window?.close() }
        middle.window?.close()
        last.window?.close()
        browser.window?.makeKeyAndOrderFront(nil)
    }

    /// First half of `scripts/test-session.sh`: open two windows, let the
    /// session be written, then wait to be killed.
    func sessionSeed() async {
        let browser = first
        await open("/second", in: browser)
        await open("/tabs", in: browser)
        let tab = app.newTab(beside: browser, url: URL(string: site + "/long"))
        _ = await waitFor { !tab.pageWebView.isLoading && tab.currentURL?.path == "/long" }
        app.newWindow(nil)
        let other = app.browserControllers.first { $0.window?.tabGroup !== browser.window?.tabGroup && $0 !== browser }
        if let other { await open("/form", in: other) }
        await pause(4)   // one save at least
        check("session-seed: two windows open", app.currentSession().windows.count == 2, app.currentSession().windows.count)
    }

    /// Second half: after `kill -9`, the relaunch must bring both windows back.
    func sessionVerify() async {
        let windows = app.currentSession().windows
        check("session-verify: both windows are back", windows.count == 2, windows.count)
        let paths = windows.map { $0.tabs.map { $0.url?.path ?? "-" } }
        check("session-verify: …with their tabs in order", paths.contains(["/tabs", "/long"]) && paths.contains(["/form"]), paths)
        check("session-verify: …and a word about the crash",
              app.browserControllers.contains { $0.lastNotice?.contains("didn’t close properly") == true })
    }

    // MARK: - #3 Hibernation

    func hibernation() async {
        let browser = first
        browser.window?.makeKeyAndOrderFront(nil)
        await open("/tabs", in: browser)

        let reader = app.newTab(beside: browser, url: URL(string: site + "/second"))
        _ = await waitFor { reader.currentURL?.path == "/second" && !reader.pageWebView.isLoading }
        await pause(0.3)
        await open("/long", in: reader)
        check("hibernation: (setup) the tab has history before it sleeps", reader.pageWebView.canGoBack)
        _ = await js("window.scrollTo(0, 1500)", in: reader)
        await pause(0.3)
        let form = app.newTab(beside: browser, url: URL(string: site + "/form"))
        _ = await waitFor { form.currentURL?.path == "/form" && !form.pageWebView.isLoading }
        await pause(0.3)
        _ = await js("document.getElementById('field').value = 'half written'", in: form)
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === browser }

        let saver = app.memorySaver
        let budget = saver.policy
        saver.policy = EvictionPolicy(liveBudget: 1)
        await saver.run(pressure: .warning).value
        saver.policy = budget

        check("hibernation: a background tab over the budget sleeps", reader.isHibernated)
        check("hibernation: …its page is unloaded", reader.pageWebView.url?.scheme != "http")
        check("hibernation: …but it still says what it will wake to", reader.currentURL?.path == "/long")
        check("hibernation: …and its tab is dimmed", reader.window?.tab.attributedTitle != nil)
        check("hibernation: the tab in front never sleeps", !browser.isHibernated)
        check("hibernation: a tab with a half-filled form never sleeps", !form.isHibernated)

        reader.window?.makeKeyAndOrderFront(nil)
        check("hibernation: opening a sleeping tab wakes it", await waitFor { !reader.isHibernated })
        check("hibernation: …on its page", await waitFor { reader.pageWebView.url?.path == "/long" && !reader.pageWebView.isLoading },
              reader.pageWebView.url as Any)
        let scrolled = await waitFor { ((await self.js("return window.scrollY", in: reader) as? NSNumber)?.doubleValue ?? 0) > 1000 }
        check("hibernation: …scrolled where it was", scrolled, await js("return window.scrollY", in: reader) as Any)
        let back = await waitFor(3) { reader.pageWebView.canGoBack }
        check("hibernation: …with its history", back,
              "back=\(reader.pageWebView.backForwardList.backList.map { $0.url.path }) current=\(reader.pageWebView.backForwardList.currentItem?.url.path ?? "-")")
        check("hibernation: …and its tab no longer dimmed", reader.window?.tab.attributedTitle == nil)

        BrowserSettings.memorySaver = false
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === browser }
        saver.policy = EvictionPolicy(liveBudget: 1)
        await saver.run(pressure: .warning).value
        check("hibernation: switched off, nothing sleeps", !reader.isHibernated)
        saver.policy = budget
        BrowserSettings.memorySaver = true
        _ = await js("document.getElementById('field').value = ''", in: form)
        reader.window?.close()
        form.window?.close()
        browser.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - #2 Tabs

    func tabs() async {
        let browser = first
        QuietMode.activate()
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { browser.window?.isKeyWindow == true }
        check("tabs: the tab bar shows from the first tab", browser.window?.tabGroup?.isTabBarVisible == true)
        check("tabs: each profile has its own tab group", browser.window?.tabbingIdentifier == BrowserWindowController.tabbingIdentifier(for: browser.profile))

        send(#selector(NSResponder.newWindowForTab(_:)))
        check("tabs: New Tab (⌘T) adds a tab to this window", await waitFor { self.tabs(of: browser).count == 2 }, tabs(of: browser).count)
        check("tabs: …and selects it", await waitFor { self.front !== browser && self.front != nil })
        let second = front
        check("tabs: …in the same profile", second?.profile.id == browser.profile.id)

        let selected = browser.selectTab(number: 1)
        let firstInFront = await waitFor { self.front === browser }
        check("tabs: ⌘1 selects the first tab", selected && firstInFront)
        browser.selectTab(number: 9)
        check("tabs: ⌘9 selects the last tab", await waitFor { self.front === second })
        second?.stepTab(by: 1)
        check("tabs: next tab wraps round to the first", await waitFor { self.front === browser })

        for extra in tabs(of: browser) where extra !== browser.window { extra.close() }
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.tabs(of: browser).count == 1 }
        await open("/tabs", in: browser)
        let before = tabs(of: browser).count
        _ = await js("document.getElementById('blank').click()", in: browser)
        check("tabs: target=_blank opens a tab", await waitFor { self.tabs(of: browser).count == before + 1 }, tabs(of: browser).count)
        for extra in tabs(of: browser) where extra !== browser.window { extra.close() }
        _ = await waitFor { self.tabs(of: browser).count == before }
        browser.window?.makeKeyAndOrderFront(nil)

        // A sign-in pop-up: window.open, reports back through window.opener, closes itself.
        _ = await js("document.getElementById('signin').click()", in: browser)
        let popupOpened = await waitFor { self.tabs(of: browser).count == before + 1 }
        check("tabs: window.open opens a tab", popupOpened,
              "tabs=\(tabs(of: browser).count) before=\(before) controllers=\(app.browserControllers.map { $0.currentURL?.path ?? "-" })")
        let reached = await waitFor(8) { (await self.js("return document.title", in: browser) as? String) == "Signed in: ada" }
        let title = await js("return document.title", in: browser)
        check("tabs: the pop-up reached its opener", reached, title as Any)
        check("tabs: window.close() in the pop-up closes its tab", await waitFor(8) { self.tabs(of: browser).count == before }, tabs(of: browser).count)

        // ⌘-click: a tab behind this one.
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === browser }
        let count = tabs(of: browser).count
        check("tabs: (setup) one tab before ⌘-click", count == before, "count=\(count) before=\(before) front=\(String(describing: front?.currentURL))")
        _ = await click("background", in: browser, modifiers: .command)
        check("tabs: ⌘-click opens the link in a new tab", await waitFor { self.tabs(of: browser).count == count + 1 }, tabs(of: browser).count)
        check("tabs: …behind the current one", front === browser)
        check("tabs: …and the current page stays", browser.currentURL?.path == "/tabs")
        check("tabs: the new tab loaded the link", await waitFor { self.app.browserControllers.contains { $0 !== browser && $0.currentURL?.path == "/second" } })

        // Close a tab with history, then bring it back. Never the first tab:
        // closing the last window would quit the app under the test.
        if let tab = app.browserControllers.first(where: { $0 !== browser && $0.currentURL?.path == "/second" }) {
            tab.window?.makeKeyAndOrderFront(nil)
            // Once the link's page has loaded: a load begun while another is
            // still under way takes its place in the history, in any browser.
            _ = await waitFor { !tab.pageWebView.isLoading }
            await open("/tabs", in: tab)
            check("tabs: the tab has history to go back to", tab.pageWebView.canGoBack)
            let remaining = tabs(of: browser).count - 1
            tab.window?.performClose(nil)
            check("tabs: Close Tab (⌘W) closes only that tab", await waitFor { self.tabs(of: browser).count == remaining })
            check("tabs: Reopen Closed Tab is offered", app.canReopenClosedTab)
            send(#selector(AppDelegate.reopenClosedTab(_:)))
            check("tabs: Reopen Closed Tab (⇧⌘T) brings it back in this window", await waitFor { self.tabs(of: browser).count == remaining + 1 })
            let reopened = front
            check("tabs: …on the page it showed", await waitFor { reopened?.currentURL?.path == "/tabs" }, reopened?.currentURL as Any)
            check("tabs: …with its history", await waitFor { reopened?.pageWebView.canGoBack == true })
        }
        snapshot(browser.window, "tabs")

        // ⌘N is a window, not a tab, whatever the macOS tab preference says.
        let windowsBefore = Set(app.browserControllers.compactMap { $0.window?.tabGroup }.map(ObjectIdentifier.init))
        send(#selector(AppDelegate.newWindow(_:)))
        check("tabs: New Window (⌘N) opens a window of its own", await waitFor {
            Set(self.app.browserControllers.compactMap { $0.window?.tabGroup }.map(ObjectIdentifier.init)).count == windowsBefore.count + 1
        })
        if let lone = app.browserControllers.first(where: { $0.window?.tabGroup !== browser.window?.tabGroup }) {
            lone.closeWindowAndTabs(nil)
            check("tabs: Close Window (⇧⌘W) closes it", await waitFor { !self.app.browserControllers.contains { $0 === lone } })
        }
        // Leave one tab for the next section.
        for extra in tabs(of: browser) where extra !== browser.window { extra.close() }
        browser.window?.makeKeyAndOrderFront(nil)
    }
}
