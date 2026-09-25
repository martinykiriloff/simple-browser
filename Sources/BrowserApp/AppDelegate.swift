import AppKit
import BrowserKit
import InspectKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []
    private lazy var profile: Profile = ProfileStore.defaultProfile()
    /// One recorder for the app: every window's events land on one timeline,
    /// tagged by tab, which is what makes cross-tab correlation possible later.
    private let recorder = InspectorRecorder()
    private var dumpTimer: Timer?
    private lazy var launch = LaunchOptions.parse(CommandLine.arguments)
    /// The profile's saved passwords. A self-test run gets a scratch vault
    /// with its own key, so it can never touch, or prompt for, the real one.
    private(set) lazy var passwords: PasswordService = {
        if launch.passwordsSelfTestOutput != nil {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBrowser-passwords-selftest-\(UUID().uuidString)")
            return PasswordService.scratch(in: scratch)
        }
        return PasswordService.forProfile(profile)
    }()
    private(set) lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController(passwords: passwords)
        controller.currentPageURL = { [weak self] in self?.frontmostBrowser?.currentURL }
        return controller
    }()

    /// The browser window the user was last in (Settings itself may be key).
    private var frontmostBrowser: BrowserWindowController? {
        let ordered = NSApp.orderedWindows.compactMap { window in controllers.first { $0.window === window } }
        return ordered.first ?? controllers.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
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
            if let directory = launch.snapshotDirectory, launch.passwordsSelfTestOutput == nil {
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
        let controller = makeWindow()
        controller.showWindowAndFocusAddress()
        // Loaded rather than sent Home: Home hands the keyboard to the page,
        // and a new window should leave it in the address bar, so typing a
        // destination straight after ⌘N works with a page loading behind it.
        if BrowserSettings.newWindowContent == .homepage { controller.load(BrowserSettings.homepageURL) }
    }

    @discardableResult
    private func makeWindow() -> BrowserWindowController {
        let controller = BrowserWindowController(profile: profile, recorder: recorder, passwords: passwords)
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
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
