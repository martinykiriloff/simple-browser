import AppKit
import WebKit
import BrowserKit
import BlockKit
import DataKit
import InspectKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []
    let profiles = ProfileStore()
    let updater = Updater()
    private(set) lazy var session = SessionController(directory: launch.sessionDirectory.map { URL(fileURLWithPath: $0) })
    private var closedWindows: [SessionSnapshot.Window] = []
    private var histories: [ProfileID: HistoryStore] = [:]
    private var bookmarkStores: [ProfileID: BookmarkStore] = [:]
    private var bookmarkWindows: [ProfileID: BookmarksWindowController] = [:]
    private var startPages: [ProfileID: StartPageSchemeHandler] = [:]
    private(set) lazy var bookmarksMenuFiller = BookmarksMenuFiller { [weak self] in
        guard let self else { return nil }
        return self.bookmarks(for: self.currentProfile)
    }
    private var historyWindows: [ProfileID: HistoryWindowController] = [:]
    /// Fills the History menu's recent pages each time it opens.
    private(set) lazy var historyMenuFiller = HistoryMenuFiller { [weak self] in
        guard let self else { return [] }
        return (try? self.history(for: self.currentProfile)?.visits(limit: 15)) ?? []
    }
    private(set) lazy var memorySaver = MemorySaver { [weak self] in self?.controllers ?? [] }
    /// The app's Profiles menu follows whichever browser window is in front.
    private(set) lazy var profilesMenuFiller = ProfilesMenuFiller(store: profiles) { [weak self] in
        self?.currentProfile ?? Profile(name: "Default")
    }
    /// One recorder for the app: every window's events land on one timeline,
    /// tagged by tab, which is what makes cross-tab correlation possible later.
    private let recorder = InspectorRecorder()
    private var dumpTimer: Timer?
    private lazy var launch = LaunchOptions.parse(CommandLine.arguments)
    /// Each profile's saved passwords, opened on first use. Never shared: a
    /// profile's sign-ins are as private to it as its cookies.
    private var passwordServices: [ProfileID: PasswordService] = [:]
    /// A self-test run gets a scratch vault with its own key, so it can never
    /// touch, or prompt for, the real one.
    private lazy var scratchPasswords: PasswordService? = !usesScratchData ? nil
        : PasswordService.scratch(in: FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleBrowser-passwords-selftest-\(UUID().uuidString)"))

    func passwords(for profile: Profile) -> PasswordService {
        if let scratchPasswords { return scratchPasswords }
        if let service = passwordServices[profile.id] { return service }
        let service = PasswordService.forProfile(profile)
        passwordServices[profile.id] = service
        return service
    }

    /// The frontmost window's profile's passwords.
    var passwords: PasswordService { passwords(for: currentProfile) }

    private(set) lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController(passwords: passwords, blocker: blocker)
        controller.privacyPane.currentProfile = { [weak self] in
            let profile = self?.frontmostBrowser?.profile ?? self?.currentProfile
            return (profile?.id.description ?? "", profile?.name ?? "")
        }
        controller.currentPageURL = { [weak self] in self?.frontmostBrowser?.currentURL }
        controller.willShow = { [weak self] in self?.syncSettingsProfile() }
        return controller
    }()

    /// The profile of the browser window in front, or the one used last.
    var currentProfile: Profile { frontmostBrowser?.profile ?? profiles.lastUsed }

    /// The browser window the user was last in (Settings itself may be key).
    private var frontmostBrowser: BrowserWindowController? {
        let ordered = NSApp.orderedWindows.compactMap { window in controllers.first { $0.window === window } }
        return ordered.first ?? controllers.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window: the rule lists compiled last time are looked
        // up while the first tab is being made.
        blocker.start()
        MainMenu.install(profilesMenuDelegate: profilesMenuFiller, historyMenuDelegate: historyMenuFiller,
                         bookmarksMenuDelegate: bookmarksMenuFiller)
        NotificationCenter.default.addObserver(forName: .bookmarksDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for controller in self.controllers { controller.syncFavoritesBar() }
                for window in self.bookmarkWindows.values { window.reload() }
            }
        }
        NotificationCenter.default.addObserver(forName: ProfileStore.didChange, object: profiles, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.profilesDidChange() }
        }
        // A run driven by a URL or a self-test never reads or writes the
        // person's session.
        session.isEnabled = launch.url == nil || launch.sessionDirectory != nil
        session.begin()
        session.startSaving { [weak self] in self?.currentSession() ?? SessionSnapshot(windows: []) }
        updater.onWillRestart = { [weak self] in self?.session.markRestartForUpdate() }
        if let url = launch.url {
            let controller: BrowserWindowController
            if launch.sessionDirectory != nil, session.shouldRestore(choice: BrowserSettings.startup), let previous = session.previous,
               let front = restore(previous, announceCrash: session.uncleanExit && !session.restartForUpdate).last {
                // Developer aid: a session test relaunching into its own session.
                controller = front
            } else {
                controller = makeWindow()
                controller.showWindow(nil)
                controller.load(url)
            }
            if launch.showRecorder { controller.showRecorder(nil) }
            if launch.goHome {
                // Developer aid: the same action the Home button performs.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { controller.goHome(nil) }
            }
            if launch.showSettings { showSettings(nil) }
            if launch.showPasswords { showPasswords(nil) }
            if let out = launch.passwordsSelfTestOutput {
                PasswordSelfTest.run(app: self, browser: controller, output: out, snapshots: launch.snapshotDirectory)
            }
            if let out = launch.uiSelfTestOutput { UISelfTest.run(browser: controller, output: out) }
            if let out = launch.blockingProbeOutput {
                runBlockingProbe(output: out, lists: launch.blockingProbeLists, sites: launch.blockingProbeSites, browser: controller)
            }
            if let out = launch.featureSelfTestOutput {
                FeatureSelfTest.run(app: self, browser: controller, output: out, snapshots: launch.snapshotDirectory,
                                    only: Set(launch.featureSections))
            }
            if let out = launch.pageSelfTestOutput {
                PageSelfTest.run(app: self, browser: controller, output: out, snapshots: launch.snapshotDirectory)
            }
            if let directory = launch.snapshotDirectory, launch.passwordsSelfTestOutput == nil, launch.pageSelfTestOutput == nil,
               launch.featureSelfTestOutput == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + launch.snapshotDelay) { [weak self] in
                    guard let self else { return }
                    Self.snapshot(controller.window, to: directory + "/browser.png")
                    Self.snapshot(self.settingsWindow.window, to: directory + "/settings.png")
                }
            }
            if let panel = launch.devToolsPanel { controller.showDevTools(panel: panel == "" ? nil : panel) }
            if let script = launch.devToolsScript, let out = launch.devToolsOutput {
                runDevToolsScript(script, output: out, in: controller, delay: launch.devToolsDelay)
            }
            if let out = launch.protocolProbeOutput {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(launch.devToolsDelay))
                    let report = await controller.protocolProbe()
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: out), options: .atomic)
                    }
                }
            }
        } else if session.isEnabled, session.shouldRestore(choice: BrowserSettings.startup), let previous = session.previous {
            restore(previous, announceCrash: session.uncleanExit && !session.restartForUpdate)
        } else {
            newWindow(nil)
        }
        startUpdater()
        memorySaver.start()
        if let path = launch.dumpRecordingPath {
            startDumping(to: URL(fileURLWithPath: path))
        }
        if !QuietMode.isOn { NSApp.activate() }
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    /// Links handed over by Finder, `open -a`, or another app once the user
    /// picks SimpleBrowser as a handler for http/https.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let controller = makeWindow()
            controller.showWindow(nil)
            controller.load(url)
        }
    }

    /// Opens a page in the browser window in front, or a new one in the
    /// current profile: Settings acts for that profile, so its links do too.
    func openInBrowser(_ url: URL) {
        let browser = frontmostBrowser ?? makeWindow()
        browser.showWindow(nil)
        browser.load(url)
    }

    // MARK: - Updates

    private func startUpdater() {
        if let feed = launch.updateFeed {
            // Only a local feed may stand in for GitHub; the signature check
            // applies to whatever it serves either way.
            guard let host = feed.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else { return }
            updater.feedURL = feed
        }
        if let output = launch.updateSelfTestOutput {
            updater.autoAnswer = .alertFirstButtonReturn
            let report = { (error: String) in
                let body = ["installed": false, "error": error] as [String: Any]
                if let data = try? JSONSerialization.data(withJSONObject: body) { try? data.write(to: URL(fileURLWithPath: output)) }
                NSApp.terminate(nil)
            }
            updater.onFailure = report
            updater.check(userInitiated: true)
            // Reached only if nothing was installed and nothing failed either.
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { report("no update was installed") }
            return
        }
        // Self-test runs never go looking for real updates.
        guard launch.passwordsSelfTestOutput == nil, launch.pageSelfTestOutput == nil, launch.uiSelfTestOutput == nil,
              launch.featureSelfTestOutput == nil else { return }
        updater.start()
    }

    /// App menu → Check for Updates…
    @objc func checkForUpdates(_ sender: Any?) {
        updater.check(userInitiated: true)
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow.showWindow(sender)
    }

    /// App menu → Passwords…, and "Manage Passwords…" wherever it appears.
    @objc func showPasswords(_ sender: Any?) {
        settingsWindow.show(.passwords, sender: sender)
    }

    /// Home when no browser window is key, which is the usual state right
    /// after setting a homepage: Settings is in front. A browser window that
    /// is key handles this itself, earlier in the responder chain.
    @objc func goHome(_ sender: Any?) {
        guard let browser = frontmostBrowser else {
            let controller = makeWindow()
            controller.showWindow(sender)
            controller.goHome(sender)
            return
        }
        browser.goHome(sender)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(in: currentProfile)
    }

    // MARK: - Private windows

    private var privateSessions: [ProfileID: PrivateSession] = [:]

    /// File → New Private Window (⇧⌘N), in the profile of the window in front.
    @objc func newPrivateWindow(_ sender: Any?) {
        openWindow(in: frontmostBrowser?.profile ?? currentProfile, isPrivate: true)
    }

    /// The profile's private session, begun by its first private tab.
    private func privateSession(for profile: Profile) -> PrivateSession {
        if let session = privateSessions[profile.id] { return session }
        let session = PrivateSession()
        privateSessions[profile.id] = session
        return session
    }

    /// A private tab closed. After the last one the session is let go: its
    /// data store, which was only ever in memory, goes with it.
    private func privateTabClosed(_ controller: BrowserWindowController) {
        guard let session = controller.privateSession else { return }
        session.tabs -= 1
        guard session.tabs <= 0 else { return }
        privateSessions = privateSessions.filter { $0.value !== session }
        // Let go of what it held now, not whenever WebKit gets round to it.
        session.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// For the self-test.
    var hasPrivateSession: Bool { !privateSessions.isEmpty }

    // MARK: - Tabs

    /// ⌘T with no browser window open: a window.
    @objc func newWindowForTab(_ sender: Any?) {
        if let browser = frontmostBrowser { browser.newWindowForTab(sender) } else { newWindow(sender) }
    }

    private struct ClosedTab {
        let profileID: ProfileID
        let url: URL?
        let state: Data?
        var title = ""
    }
    /// Most recent last. Tabs of a window closed at quit are not "closed tabs".
    private var closedTabs: [ClosedTab] = []
    private var terminating = false

    /// A new tab beside `browser`, in its window and profile. With no URL it
    /// opens what a new window opens, with the keyboard in the address bar.
    @discardableResult
    func newTab(beside browser: BrowserWindowController?, url: URL? = nil, inFront: Bool = true,
                state: Data? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserWindowController {
        let profile = browser?.profile ?? currentProfile
        // A tab opened from a private window is private, whatever opened it:
        // ⌘T, a link, a page's pop-up.
        let tab = makeWindow(profile: profile, configuration: configuration, isPrivate: browser?.isPrivate ?? false)
        if let window = browser?.window, let tabWindow = tab.window {
            tabWindow.tabbingMode = .automatic
            window.addTabbedWindow(tabWindow, ordered: .above)
            tab.acceptTabs()
            if inFront { tabWindow.makeKeyAndOrderFront(nil) } else { window.makeKeyAndOrderFront(nil) }
        } else {
            tab.showWindow(nil)
        }
        if let state {
            tab.interactionState = state
        } else if let url {
            tab.load(url)
        } else if configuration == nil {
            if inFront { tab.focusAddressBar(nil) }
            loadNewTabContent(in: tab)
        }
        return tab
    }

    /// File → Reopen Closed Tab (⇧⌘T): back where it was, with its history.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = closedTabs.popLast(), let profile = profiles.profile(closed.profileID) else { return }
        let beside = frontmostBrowser?.profile.id == profile.id ? frontmostBrowser
            : controllers.last { $0.profile.id == profile.id }
        if let beside {
            newTab(beside: beside, url: closed.url, state: closed.state)
        } else {
            let window = makeWindow(profile: profile)
            window.showWindow(nil)
            if let state = closed.state { window.interactionState = state } else if let url = closed.url { window.load(url) }
        }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Every open tab, for the self-tests.
    var browserControllers: [BrowserWindowController] { controllers }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reopenClosedTab(_:)): return canReopenClosedTab
        case #selector(reopenLastClosedWindow(_:)): return !closedWindows.isEmpty
        case #selector(reopenLastSession(_:)): return !restoredPrevious && !(session.previous?.isEmpty ?? true)
        default: return true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Before the windows close, or the session saved would be empty.
        session.end(currentSession())
        terminating = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session.end(currentSession())
        terminating = true
        return .terminateNow
    }

    // MARK: - Content blocking

    /// One for the app: the filter lists are the same for every profile.
    /// A run driven by a test gets one with no lists and a folder of its
    /// own, so it never asks the lists' servers for anything.
    private(set) lazy var blocker: ContentBlocker = {
        if usesScratchData || launch.devToolsScript != nil || launch.protocolProbeOutput != nil || launch.blockingProbeOutput != nil {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBrowser-blocking-\(UUID().uuidString)", isDirectory: true)
            return ContentBlocker(directory: scratch, sources: [])
        }
        return ContentBlocker.standard()
    }()

    /// Developer aid (`--blocking-probe <file>`): downloads the real filter
    /// lists into a scratch folder, converts and compiles them, and writes
    /// down what that took and what was left out.
    func runBlockingProbe(output: String, lists: [String], sites: [String], browser: BrowserWindowController) {
        Task { @MainActor in
            let suite = "SimpleBrowser.blocking-probe"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let scratchSettings = UserDefaults(suiteName: suite) { BrowserSettings.store = scratchSettings }
            let chosen = FilterList.all.filter { lists.isEmpty ? $0.onByDefault : lists.contains($0.id) }
            // The app's own blocker, which in a probe run has a scratch folder.
            let probe = blocker
            let scratch = probe.directory
            probe.sources = chosen.map { FilterList(id: $0.id, name: $0.name, about: $0.about, url: $0.url, onByDefault: true) }
            let report = await probe.update(force: true)

            // The same pages with and without, counted by the page itself.
            var pages: [[String: Any]] = []
            @MainActor func visit(_ address: String) async -> [String: Any] {
                guard let url = URL(string: address) else { return [:] }
                browser.load(url)
                try? await Task.sleep(for: .seconds(12))
                let counted = try? await browser.evaluateInPage("return { requests: performance.getEntriesByType('resource').length, hosts: new Set(performance.getEntriesByType('resource').map(e => new URL(e.name).host)).size, frames: document.querySelectorAll('iframe').length }") as? [String: Any]
                return ["requests": counted?["requests"] ?? -1, "hosts": counted?["hosts"] ?? -1, "frames": counted?["frames"] ?? -1,
                        "blocked": browser.blocking.blockedCount, "blockedHosts": browser.blocking.blockedHosts.count]
            }
            for site in sites {
                BrowserSettings.contentBlocking = true
                probe.settingsChanged()
                let with = await visit(site)
                BrowserSettings.contentBlocking = false
                probe.settingsChanged()
                let without = await visit(site)
                pages.append(["site": site, "blocking": with, "noBlocking": without])
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            var skipped: [String: Int] = [:]
            let texts = chosen.compactMap { try? String(contentsOf: scratch.appendingPathComponent($0.id + ".txt"), encoding: .utf8) }
            let built = RuleSetBuilder.build(texts: texts, rejecting: [])
            for (reason, count) in built.skipped { skipped[reason.rawValue] = count }
            let result: [String: Any] = [
                "lists": chosen.map(\.id), "downloaded": report.downloaded, "failed": report.failed,
                "bytes": probe.state.lists.mapValues(\.bytes), "filters": probe.state.filters,
                "rules": probe.state.rules, "compiledLists": report.lists, "rejectedByWebKit": report.rejected,
                "refusedSelectors": probe.state.refusedSelectors ?? -1, "skipped": probe.state.skipped, "skippedByReason": skipped,
                "seconds": report.seconds, "status": probe.statusLine, "pages": pages,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    /// Developer aid: the addresses the recorder has as blocked, for a tab.
    func blockedRequestsRecorded(for browser: BrowserWindowController) -> [String] {
        recorder.events.compactMap { recorded -> String? in
            guard recorded.tab == browser.tab, case .network(let event) = recorded.event, event.failure == "Blocked by content blocking" else { return nil }
            return event.url.absoluteString
        }
    }

    /// Settings → Privacy, from the shield's popover.
    @objc func showPrivacySettings(_ sender: Any?) {
        settingsWindow.show(.privacy, sender: sender)
    }

    // MARK: - History

    /// The profile's history, opened on first use, in the profile's folder,
    /// so deleting the profile deletes its history. Nil for a run that must
    /// not write the person's data (self-tests keep theirs in memory).
    func history(for profile: Profile) -> HistoryStore? {
        if let store = histories[profile.id] { return store }
        let store: HistoryStore?
        if launch.featureSelfTestOutput != nil || launch.pageSelfTestOutput != nil || launch.passwordsSelfTestOutput != nil
            || launch.uiSelfTestOutput != nil {
            store = try? HistoryStore(path: nil)
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SimpleBrowser/Profiles/\(profile.id)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try? HistoryStore(path: directory.appendingPathComponent("History.sqlite").path)
            // A year, as Safari keeps by default.
            try? store?.prune(olderThan: Date().addingTimeInterval(-365 * 86_400))
        }
        histories[profile.id] = store
        return store
    }

    /// History → Show All History (⌘Y), for the profile in front.
    @objc func showHistory(_ sender: Any?) {
        let profile = currentProfile
        guard let store = history(for: profile) else { return }
        let controller = historyWindows[profile.id] ?? {
            let controller = HistoryWindowController(store: store, profile: profile)
            controller.open = { [weak self] url, newTab in
                guard let self else { return }
                let browser = self.controllers.last { $0.profile.id == profile.id && $0.window?.tabGroup?.selectedWindow === $0.window }
                    ?? self.controllers.last { $0.profile.id == profile.id }
                if newTab || browser == nil { self.newTab(beside: browser, url: url) } else { browser?.load(url); browser?.showWindow(nil) }
            }
            controller.clear = { [weak self] since in await self?.clearHistory(of: profile, since: since) }
            historyWindows[profile.id] = controller
            return controller
        }()
        controller.reload()
        controller.showWindow(sender)
    }

    /// History → Clear History…, for the profile in front.
    @objc func clearHistoryAction(_ sender: Any?) {
        let profile = currentProfile
        guard let window = frontmostBrowser?.window ?? NSApp.keyWindow else { return }
        ClearHistorySheet.ask(in: window) { [weak self] since in
            Task { @MainActor in await self?.clearHistory(of: profile, since: since) }
        }
    }

    /// History, and the cookies, caches and storage sites wrote in the same
    /// period, as Safari clears them.
    func clearHistory(of profile: Profile, since: Date) async {
        try? history(for: profile)?.deleteVisits(since: since)
        let store = WKWebsiteDataStore(forIdentifier: profile.dataStoreIdentifier)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: since)
        historyWindows[profile.id]?.reload()
    }

    /// History menu → a recent page: it opens in the tab in front.
    @objc func openHistoryItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        if let browser = frontmostBrowser { browser.load(url) } else { newTab(beside: nil, url: url) }
    }

    // MARK: - Bookmarks

    /// Whether this run keeps its data in memory (self-tests), never in the person's files.
    private var usesScratchData: Bool {
        launch.featureSelfTestOutput != nil || launch.pageSelfTestOutput != nil || launch.passwordsSelfTestOutput != nil
            || launch.uiSelfTestOutput != nil
    }

    private func profileDirectory(_ profile: Profile) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimpleBrowser/Profiles/\(profile.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func bookmarks(for profile: Profile) -> BookmarkStore? {
        if let store = bookmarkStores[profile.id] { return store }
        let store = usesScratchData ? try? BookmarkStore(path: nil)
            : try? BookmarkStore(path: profileDirectory(profile).appendingPathComponent("Bookmarks.sqlite").path)
        bookmarkStores[profile.id] = store
        return store
    }

    func readingListArchive(for profile: Profile, _ item: BookmarkStore.ReadingItem) -> URL {
        let base = usesScratchData ? FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBrowser-selftest-\(profile.id)")
            : profileDirectory(profile)
        return base.appendingPathComponent("ReadingList/\(item.id).webarchive")
    }

    /// The start page, built from this profile's data each time it loads.
    private func startPage(for profile: Profile) -> StartPageSchemeHandler {
        if let handler = startPages[profile.id] { return handler }
        let handler = StartPageSchemeHandler { [weak self] in
            guard let self else { return .init() }
            var content = StartPageSchemeHandler.Content()
            content.searchEngine = BrowserSettings.searchEngine.name
            if let store = self.bookmarks(for: profile) {
                content.favorites = store.favorites.compactMap { node in node.url.map { (node.title, $0) } }
                content.reading = ((try? store.readingList(includeRead: false)) ?? []).map { ($0.title, $0.url) }
            }
            let favoriteURLs = Set(content.favorites.map(\.url))
            content.frequent = ((try? self.history(for: profile)?.topPages(limit: 16)) ?? [])
                .filter { !favoriteURLs.contains($0.url) }.prefix(12).map { ($0.title, $0.url) }
            content.closed = self.closedTabs.reversed().filter { $0.profileID == profile.id }
                .compactMap { tab in tab.url.map { (tab.title, $0) } }
            return content
        }
        startPages[profile.id] = handler
        return handler
    }

    /// A private window's start page. One for the app: it draws on nothing
    /// but the favorites of the profile asking, and the search engine.
    private lazy var privateStartPage = StartPageSchemeHandler { [weak self] in
        var content = StartPageSchemeHandler.Content()
        content.isPrivate = true
        content.searchEngine = BrowserSettings.searchEngine.name
        if let self, let profile = self.frontmostBrowser?.profile, let store = self.bookmarks(for: profile) {
            content.favorites = store.favorites.compactMap { node in node.url.map { (node.title, $0) } }
        }
        return content
    }

    /// What a new tab or window shows: the start page, the homepage, or nothing.
    func loadNewTabContent(in tab: BrowserWindowController) {
        switch BrowserSettings.newWindowContent {
        case .startPage: tab.load(StartPageSchemeHandler.url)
        case .homepage: tab.load(BrowserSettings.homepageURL)
        case .empty: break
        }
    }

    private func bookmarksChanged() {
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
    }

    /// Bookmarks → Show Bookmarks (⌥⌘B), for the profile in front.
    @objc func showBookmarks(_ sender: Any?) {
        let profile = currentProfile
        guard let store = bookmarks(for: profile) else { return }
        let controller = bookmarkWindows[profile.id] ?? {
            let controller = BookmarksWindowController(store: store, profile: profile)
            controller.open = { [weak self] url, newTab in self?.openInProfile(profile, url: url, newTab: newTab) }
            controller.changed = { [weak self] in self?.bookmarksChanged() }
            bookmarkWindows[profile.id] = controller
            return controller
        }()
        controller.reload()
        controller.showWindow(sender)
    }

    /// A bookmark or reading-list item from a menu: this tab, or with ⌘ a new one.
    @objc func openBookmarkItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        openInProfile(currentProfile, url: url, newTab: NSEvent.modifierFlags.contains(.command))
    }

    private func openInProfile(_ profile: Profile, url: URL, newTab: Bool) {
        let browser = frontmostBrowser?.profile.id == profile.id ? frontmostBrowser : controllers.last { $0.profile.id == profile.id }
        if newTab || browser == nil { self.newTab(beside: browser, url: url) } else { browser?.load(url); browser?.showWindow(nil) }
    }

    // MARK: - Session

    /// Every window and its tabs, in tab-bar order.
    func currentSession() -> SessionSnapshot {
        var seen: Set<ObjectIdentifier> = []
        var windows: [SessionSnapshot.Window] = []
        let ordered = NSApp.orderedWindows.compactMap { window in controllers.first { $0.window === window } }
        // Private windows are never part of a session: not saved, not restored.
        for controller in ordered + controllers where !controller.isPrivate {
            guard let window = controller.window else { continue }
            let key = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            windows.append(windowSnapshot(of: controller))
        }
        return SessionSnapshot(windows: windows)
    }

    private func windowSnapshot(of controller: BrowserWindowController) -> SessionSnapshot.Window {
        let window = controller.window
        let tabWindows = window?.tabbedWindows ?? [window].compactMap { $0 }
        let tabs = tabWindows.compactMap { tabWindow in controllers.first { $0.window === tabWindow } }
        let selectedWindow = window?.tabGroup?.selectedWindow ?? window
        let frame = window?.frame ?? .zero
        return SessionSnapshot.Window(
            profileID: controller.profile.id,
            frame: CodableRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            tabs: tabs.map(\.sessionTab),
            selected: tabs.firstIndex { $0.window === selectedWindow } ?? 0)
    }

    /// Brings windows back as they were: same profile, same frame, same tabs
    /// in the same order. Only each window's front tab loads; the rest wake
    /// when opened.
    @discardableResult
    func restore(_ snapshot: SessionSnapshot, announceCrash: Bool = false) -> [BrowserWindowController] {
        let windows = snapshot.restorable(profiles: Set(profiles.profiles.map(\.id)))
        guard !windows.isEmpty else {
            newWindow(nil)
            return []
        }
        var fronts: [BrowserWindowController] = []
        for saved in windows {
            guard let profile = profiles.profile(saved.profileID) else { continue }
            var created: [BrowserWindowController] = []
            for (index, tab) in saved.tabs.enumerated() {
                let controller: BrowserWindowController
                if let previous = created.last {
                    controller = makeWindow(profile: profile)
                    // After the previous tab, not the first: "above the first"
                    // each time would put them back in reverse.
                    if let window = previous.window, let tabWindow = controller.window {
                        tabWindow.tabbingMode = .automatic
                        window.addTabbedWindow(tabWindow, ordered: .above)
                    }
                } else {
                    controller = makeWindow(profile: profile)
                    controller.window?.setFrame(NSRect(x: saved.frame.x, y: saved.frame.y, width: saved.frame.width, height: saved.frame.height),
                                                display: false)
                    controller.showWindow(nil)
                }
                if index == saved.selected {
                    if let state = tab.state { controller.interactionState = state } else if let url = tab.url { controller.load(url) }
                } else {
                    controller.restoreAsleep(url: tab.url, title: tab.title, state: tab.state)
                }
                created.append(controller)
            }
            if created.indices.contains(saved.selected) {
                created[saved.selected].window?.makeKeyAndOrderFront(nil)
                fronts.append(created[saved.selected])
            }
        }
        if announceCrash, let front = fronts.last {
            front.showNotice("SimpleBrowser didn’t close properly. Your tabs are back.")
        }
        return fronts
    }

    /// History → Reopen Last Closed Window.
    @objc func reopenLastClosedWindow(_ sender: Any?) {
        guard let window = closedWindows.popLast() else { return }
        restore(SessionSnapshot(windows: [window]))
    }

    /// History → Reopen All Windows from Last Session, when the launch did not.
    @objc func reopenLastSession(_ sender: Any?) {
        guard let previous = session.previous else { return }
        restore(previous)
        restoredPrevious = true
    }
    private var restoredPrevious = false

    private func rememberClosedWindow(_ controller: BrowserWindowController) {
        guard !controller.isPrivate else { return }
        closedWindows.append(windowSnapshot(of: controller))
        if closedWindows.count > 10 { closedWindows.removeFirst() }
    }

    // MARK: - Profiles

    /// Profiles menu → a profile: a new window browsing as it.
    @objc func openProfileWindow(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? ProfileID,
              let profile = profiles.profile(id) else { return }
        openWindow(in: profile)
    }

    @objc func newProfile(_ sender: Any?) {
        guard let name = askForName(title: "New Profile",
                                    message: "A profile has its own cookies, sign-ins, storage, cache and saved passwords. Nothing is shared with your other profiles.",
                                    initial: "", confirm: "Create") else { return }
        openWindow(in: profiles.add(name: name))
    }

    @objc func renameProfile(_ sender: Any?) {
        let id = (sender as? NSMenuItem)?.representedObject as? ProfileID ?? currentProfile.id
        guard let profile = profiles.profile(id),
              let name = askForName(title: "Rename Profile", message: "", initial: profile.name, confirm: "Rename") else { return }
        profiles.rename(id, to: name)
    }

    @objc func deleteProfile(_ sender: Any?) {
        let id = (sender as? NSMenuItem)?.representedObject as? ProfileID ?? currentProfile.id
        guard profiles.profiles.count > 1, let profile = profiles.profile(id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the profile “\(profile.name)”?"
        alert.informativeText = "Its windows close, and its cookies, website data and saved passwords are deleted from this Mac. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // WebKit will not remove a data store a web view is still using.
        for controller in controllers where controller.profile.id == id { controller.close() }
        passwordServices[id] = nil
        histories[id] = nil
        bookmarkStores[id] = nil
        startPages[id] = nil
        bookmarkWindows[id]?.close()
        bookmarkWindows[id] = nil
        historyWindows[id]?.close()
        historyWindows[id] = nil
        Task { @MainActor in
            await profiles.remove(id)
            if controllers.isEmpty { newWindow(nil) }
        }
    }

    private func askForName(title: String, message: String, initial: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name (optional)"
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func profilesDidChange() {
        for controller in controllers {
            if let updated = profiles.profile(controller.profile.id) { controller.profile = updated }
        }
        syncSettingsProfile()
    }

    /// Settings shows the passwords of the profile whose window is in front.
    private func syncSettingsProfile() {
        let profile = currentProfile
        let pane = settingsWindow.passwordsPane
        pane.service = passwords(for: profile)
        pane.profileLabel.stringValue = "Passwords saved in the profile “\(profile.name)”"
        pane.profileLabel.isHidden = profiles.profiles.count == 1
    }

    private func openWindow(in profile: Profile, isPrivate: Bool = false) {
        let controller = makeWindow(profile: profile, isPrivate: isPrivate)
        controller.showWindowAndFocusAddress()
        // Loaded rather than sent Home: Home hands the keyboard to the page,
        // and a new window should leave it in the address bar, so typing a
        // destination straight after ⌘N works with a page loading behind it.
        loadNewTabContent(in: controller)
    }

    @discardableResult
    private func makeWindow(profile: Profile? = nil, configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false) -> BrowserWindowController {
        let profile = profile ?? currentProfile
        profiles.markUsed(profile.id)
        let session = isPrivate ? privateSession(for: profile) : nil
        session?.tabs += 1
        let controller = BrowserWindowController(profile: profile, recorder: recorder, passwords: passwords(for: profile),
                                                 configuration: configuration, startPage: isPrivate ? privateStartPage : startPage(for: profile),
                                                 blocker: blocker, privateSession: session)
        controller.bookmarks = { [weak self] in self?.bookmarks(for: profile) }
        controller.onBookmarksChanged = { [weak self] in self?.bookmarksChanged() }
        controller.readingListArchive = { [weak self] item in
            self?.readingListArchive(for: profile, item) ?? FileManager.default.temporaryDirectory
        }
        controller.addressSources = { [weak self] text in
            guard let self else { return .init() }
            var sources = BrowserWindowController.AddressSources()
            // A private tab is offered to private windows only, and a normal one to normal windows.
            sources.tabs = self.controllers.filter { $0.profile.id == profile.id && $0.isPrivate == isPrivate }.compactMap { tab in
                tab.currentURL.flatMap { StartPageSchemeHandler.isStartPage($0) ? nil : (tab.tab.description, tab.window?.title ?? "", $0) }
            }
            let query = text.trimmingCharacters(in: .whitespaces)
            // Search the typed words, and for completion the first word as an address prefix.
            let now = Date()
            let pages = ((try? self.history(for: profile)?.pages(matching: query, limit: 12)) ?? [])
            sources.history = pages.map { .init(title: $0.title, url: $0.url, score: $0.score(now: now)) }
            sources.bookmarks = ((try? self.bookmarks(for: profile)?.search(query, limit: 12)) ?? []).compactMap { node in
                node.url.map { url in .init(title: node.title, url: url, score: (try? self.history(for: profile)?.page(for: url))??.score(now: now) ?? 1) }
            }
            return sources
        }
        controller.switchToTab = { [weak self] id in
            self?.controllers.first { $0.tab.description == id }?.window?.makeKeyAndOrderFront(nil)
        }
        controller.removeFromHistory = { [weak self] url in try? self?.history(for: profile)?.deletePage(url) }
        controller.onZoomChanged = { [weak self, weak controller] site, level in
            for tab in self?.controllers ?? [] where tab !== controller && tab.profile.id == profile.id && tab.isPrivate == isPrivate {
                tab.zoomChanged(for: site, to: level)
            }
        }
        controller.favoritesBar.items = { [weak self] in self?.bookmarks(for: profile)?.favorites ?? [] }
        controller.favoritesBar.childrenOf = { [weak self] id in (try? self?.bookmarks(for: profile)?.children(of: id)) ?? [] }
        controller.favoritesBar.open = { [weak self, weak controller] url, newTab in
            if newTab { self?.newTab(beside: controller, url: url, inFront: false) } else { controller?.load(url) }
        }
        controller.syncFavoritesBar()
        controller.profilesMenuFiller = ProfilesMenuFiller(store: profiles) { [weak controller] in
            controller?.profile ?? profile
        }
        // Links opened from a page stay in the page's profile: a link from a
        // work account's mail opens signed in to work, not to Default.
        controller.openInNewWindow = { [weak self, weak controller] url in
            guard let self, let controller else { return }
            let window = self.makeWindow(profile: controller.profile, isPrivate: controller.isPrivate)
            window.showWindow(nil)
            window.load(url)
        }
        controller.openInNewTab = { [weak self, weak controller] url, inFront in
            self?.newTab(beside: controller, url: url, inFront: inFront)
        }
        controller.onNewTab = { [weak self, weak controller] in
            self?.newTab(beside: controller)
        }
        controller.onPopup = { [weak self, weak controller] configuration, _ in
            guard let self, let controller else { return nil }
            return self.newTab(beside: controller, configuration: configuration).pageWebView
        }
        controller.onWindowClosing = { [weak self] controller in self?.rememberClosedWindow(controller) }
        // A private window writes no history, and its closed tabs and
        // windows cannot be reopened: they are gone.
        if !isPrivate {
            controller.onVisit = { [weak self] url, title, typed in
                try? self?.history(for: profile)?.recordVisit(url, title: title, typed: typed)
            }
            controller.onTitleChange = { [weak self] url, title in
                try? self?.history(for: profile)?.updateTitle(title, for: url)
            }
        }
        controller.onTabClosed = { [weak self, weak controller] url, state, title in
            guard let self, let controller, !controller.isPrivate, !self.terminating, url != nil || state != nil else { return }
            // The last tab of a window closing is the window closing.
            if (controller.window?.tabbedWindows?.count ?? 1) <= 1 { self.rememberClosedWindow(controller) }
            self.closedTabs.append(ClosedTab(profileID: controller.profile.id, url: url, state: state, title: title))
            if self.closedTabs.count > 25 { self.closedTabs.removeFirst() }
        }
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
            if let controller { self?.privateTabClosed(controller) }
        }
        controller.onBecomeKey = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.profiles.markUsed(controller.profile.id)
        }
        return controller
    }

    /// Developer aid: renders a whole window, title bar and toolbar included,
    /// to a PNG. Works with the display asleep, when `screencapture` cannot.
    static func snapshot(_ window: NSWindow?, to path: String) {
        guard let frameView = window?.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Developer aid: keeps a JSON copy of the recording on disk, rewritten
    /// once a second, so the browser can be driven from a script and its
    /// observations checked without a UI.
    private func startDumping(to url: URL) {
        dumpTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [recorder] _ in
            MainActor.assumeIsolated {
                if let data = try? recorder.exportJSON() {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    /// Developer aid: evaluates a script inside the DevTools UI once the page
    /// has had time to load, and writes the JSON result to a file.
    private func runDevToolsScript(_ path: String, output: String, in controller: BrowserWindowController, delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard let tools = controller.devTools else { return }
            var result: [String: Any]
            do {
                let script = try String(contentsOfFile: path, encoding: .utf8)
                let value = try await tools.evaluateInUI(script)
                result = ["ok": true, "value": value ?? NSNull()]
            } catch {
                result = ["ok": false, "error": (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription]
            }
            if !JSONSerialization.isValidJSONObject(result) { result = ["ok": true, "value": String(describing: result["value"] ?? "")] }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }
}

/// `SimpleBrowser [--passwords-selftest <file>] [--show-passwords] [--ui-selftest <file>] [--go-home] [--show-settings] [--snapshot-windows <dir>] [--dump-recording <path>] [--show-recorder] [--show-devtools [panel]]
///                [--devtools-script <file> --devtools-out <file> [--devtools-delay <s>]] [<url>]`
struct LaunchOptions {
    var url: URL?
    var dumpRecordingPath: String?
    var showRecorder = false
    var devToolsPanel: String?
    var devToolsScript: String?
    var devToolsOutput: String?
    var devToolsDelay: Double = 4
    var protocolProbeOutput: String?
    var goHome = false
    var showSettings = false
    var snapshotDirectory: String?
    var snapshotDelay: Double = 3
    var uiSelfTestOutput: String?
    var passwordsSelfTestOutput: String?
    var pageSelfTestOutput: String?
    var featureSelfTestOutput: String?
    var blockingProbeOutput: String?
    var blockingProbeLists: [String] = []
    var blockingProbeSites: [String] = []
    var sessionDirectory: String?
    var featureSections: [String] = []
    var updateFeed: URL?
    var updateSelfTestOutput: String?
    var showPasswords = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--dump-recording":
                options.dumpRecordingPath = iterator.next()
            case "--show-recorder":
                options.showRecorder = true
            case "--show-devtools":
                options.devToolsPanel = ""
            case "--devtools-panel":
                options.devToolsPanel = iterator.next() ?? ""
            case "--devtools-script":
                options.devToolsScript = iterator.next()
            case "--devtools-out":
                options.devToolsOutput = iterator.next()
            case "--go-home":
                options.goHome = true
            case "--show-settings":
                options.showSettings = true
            case "--passwords-selftest":
                options.passwordsSelfTestOutput = iterator.next()
            case "--update-feed":
                options.updateFeed = iterator.next().flatMap(URL.init(string:))
            case "--update-selftest":
                options.updateSelfTestOutput = iterator.next()
            case "--blocking-probe":
                options.blockingProbeOutput = iterator.next()
            case "--blocking-sites":
                options.blockingProbeSites = (iterator.next() ?? "").split(separator: ",").map(String.init)
            case "--blocking-lists":
                options.blockingProbeLists = (iterator.next() ?? "").split(separator: ",").map(String.init)
            case "--feature-selftest":
                options.featureSelfTestOutput = iterator.next()
            case "--session-dir":
                options.sessionDirectory = iterator.next()
            case "--only":
                options.featureSections = (iterator.next() ?? "").split(separator: ",").map(String.init)
            case "--page-selftest":
                options.pageSelfTestOutput = iterator.next()
            case "--show-passwords":
                options.showPasswords = true
            case "--ui-selftest":
                options.uiSelfTestOutput = iterator.next()
            case "--snapshot-delay":
                options.snapshotDelay = iterator.next().flatMap(Double.init) ?? 3
            case "--snapshot-windows":
                options.snapshotDirectory = iterator.next()
            case "--protocol-probe":
                options.protocolProbeOutput = iterator.next()
            case "--devtools-delay":
                options.devToolsDelay = iterator.next().flatMap(Double.init) ?? 4
            case let value where value.hasPrefix("-"):
                continue   // Unknown flag (or an AppKit one like -NSDocumentRevisionsDebugMode).
            default:
                if options.url == nil { options.url = AddressResolver.resolve(argument) }
            }
        }
        return options
    }
}
