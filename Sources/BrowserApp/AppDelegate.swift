import AppKit
import WebKit
import BrowserKit
import InspectKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []
    let profiles = ProfileStore()
    let updater = Updater()
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
    private lazy var scratchPasswords: PasswordService? = launch.passwordsSelfTestOutput == nil ? nil
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
        let controller = SettingsWindowController(passwords: passwords)
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
        MainMenu.install(profilesMenuDelegate: profilesMenuFiller)
        NotificationCenter.default.addObserver(forName: ProfileStore.didChange, object: profiles, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.profilesDidChange() }
        }
        if let url = launch.url {
            let controller = makeWindow()
            controller.showWindow(nil)
            controller.load(url)
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
        } else {
            newWindow(nil)
        }
        startUpdater()
        if let path = launch.dumpRecordingPath {
            startDumping(to: URL(fileURLWithPath: path))
        }
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileHandle.standardError.write(Data(("TERMINATE-PROBE\n" + Thread.callStackSymbols.prefix(25).joined(separator: "\n") + "\n").utf8))
        return .terminateNow
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

    // MARK: - Tabs

    /// ⌘T with no browser window open: a window.
    @objc func newWindowForTab(_ sender: Any?) {
        if let browser = frontmostBrowser { browser.newWindowForTab(sender) } else { newWindow(sender) }
    }

    private struct ClosedTab {
        let profileID: ProfileID
        let url: URL?
        let state: Data?
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
        let tab = makeWindow(profile: profile, configuration: configuration)
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
            if BrowserSettings.newWindowContent == .homepage { tab.load(BrowserSettings.homepageURL) }
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
        menuItem.action == #selector(reopenClosedTab(_:)) ? canReopenClosedTab : true
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
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

    private func openWindow(in profile: Profile) {
        let controller = makeWindow(profile: profile)
        controller.showWindowAndFocusAddress()
        // Loaded rather than sent Home: Home hands the keyboard to the page,
        // and a new window should leave it in the address bar, so typing a
        // destination straight after ⌘N works with a page loading behind it.
        if BrowserSettings.newWindowContent == .homepage { controller.load(BrowserSettings.homepageURL) }
    }

    @discardableResult
    private func makeWindow(profile: Profile? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserWindowController {
        let profile = profile ?? currentProfile
        profiles.markUsed(profile.id)
        let controller = BrowserWindowController(profile: profile, recorder: recorder, passwords: passwords(for: profile),
                                                 configuration: configuration)
        controller.profilesMenuFiller = ProfilesMenuFiller(store: profiles) { [weak controller] in
            controller?.profile ?? profile
        }
        // Links opened from a page stay in the page's profile: a link from a
        // work account's mail opens signed in to work, not to Default.
        controller.openInNewWindow = { [weak self, weak controller] url in
            guard let self, let controller else { return }
            let window = self.makeWindow(profile: controller.profile)
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
        controller.onTabClosed = { [weak self, weak controller] url, state, _ in
            guard let self, let controller, !self.terminating, url != nil || state != nil else { return }
            self.closedTabs.append(ClosedTab(profileID: controller.profile.id, url: url, state: state))
            if self.closedTabs.count > 25 { self.closedTabs.removeFirst() }
        }
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
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
            case "--feature-selftest":
                options.featureSelfTestOutput = iterator.next()
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
