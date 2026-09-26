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
    private var passed = 0
    private let snapshots: String?

    init(app: AppDelegate, browser: BrowserWindowController, snapshots: String?) {
        self.app = app
        self.first = browser
        self.snapshots = snapshots
    }

    static func run(app: AppDelegate, browser: BrowserWindowController, output: String, snapshots: String?, only: Set<String>) {
        let test = FeatureSelfTest(app: app, browser: browser, snapshots: snapshots)
        Task { @MainActor in
            let suite = "SimpleBrowser.feature-selftest"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let scratch = UserDefaults(suiteName: suite) { BrowserSettings.store = scratch }
            BrowserSettings.newWindowContent = .empty
            await test.pause(1)
            for (name, section) in test.sections where only.isEmpty || only.contains(name) {
                await section()
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let report: [String: Any] = [
                "passed": test.failures.isEmpty && test.environment.isEmpty,
                "checksPassed": test.passed,
                "failures": test.failures,
                "environment": test.environment,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }

    /// One entry per ticket, in the order they were built.
    var sections: [(String, () async -> Void)] {
        [("tabs", tabs), ("hibernation", hibernation)]
    }

    // MARK: - Helpers

    func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
        if ok { passed += 1 } else { failures.append(detail.map { "\(name): \($0)" } ?? name) }
        FileHandle.standardError.write(Data("[selftest] \(ok ? "ok" : "FAIL") \(name)\(ok ? "" : detail.map { ": \($0)" } ?? "")\n".utf8))
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
        NSApp.activate()
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
