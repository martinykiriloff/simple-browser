import AppKit
import WebKit
import BrowserKit

/// #19 Shortcuts, the tab overview, accessibility, Settings, Handoff, the error page.
extension FeatureSelfTest {

    private func menuItem(_ action: String) -> NSMenuItem? {
        func walk(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu, let found = walk(submenu) { return found }
                if let selector = item.action, NSStringFromSelector(selector) == action, !item.isHidden { return item }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(walk)
    }

    func polish() async {
        let browser = first
        browser.window?.makeKeyAndOrderFront(nil)
        await open("/second", in: browser)

        // The shortcut audit: the menu bar and the catalogue agree, and nothing clashes.
        let menu = MainMenu.menuShortcuts()
        let catalogue = Shortcuts.effective(overrides: [:])
        let unlisted = menu.keys.filter { Shortcuts.command($0) == nil }.sorted()
        check("polish: every key in the menu bar is in the audit", unlisted.isEmpty, unlisted)
        let differing = Shortcuts.commands.filter { !$0.fixed && !Shortcuts.isStandard($0.id) && menu[$0.id] != nil && menu[$0.id] != (catalogue[$0.id] ?? nil) }.map { "\($0.id): menu \(menu[$0.id]?.display ?? "—") audit \((catalogue[$0.id] ?? nil)?.display ?? "—")" }
        check("polish: …with the same keys", differing.isEmpty, differing)
        let missing = Shortcuts.commands.filter { !$0.fixed && menu[$0.id] == nil }.map(\.id)
        check("polish: …and every command in the audit is in a menu", missing.isEmpty, missing)
        let ours = menu.filter { !Shortcuts.isStandard($0.key) }.mapValues { Optional($0) }
        check("polish: no key is given twice, and none is the Mac's own", Shortcuts.conflicts(in: ours).isEmpty, Shortcuts.conflicts(in: ours))
        check("polish: View → Show All Tabs, ⇧⌘\\", menuItem("toggleTabOverview:")?.keyEquivalent == "\\" && menuItem("toggleTabOverview:")?.keyEquivalentModifierMask == [.command, .shift])

        // Changing a key in Settings → Advanced.
        let settings = app.settingsWindow
        settings.show(.advanced)
        let pane = settings.shortcutsPane
        check("polish: Settings has General, Tabs, Passwords, AutoFill, Privacy, Websites, Extensions and Advanced",
              settings.paneTitles == ["General", "Tabs", "Passwords", "AutoFill", "Privacy", "Websites", "Extensions", "Developer", "Advanced"], settings.paneTitles)
        check("polish: Advanced lists every shortcut beside Safari's and Chrome's", pane.table.numberOfRows == pane.commands.count && pane.table.tableColumns.map(\.title) == ["Command", "SimpleBrowser", "Safari", "Chrome"])
        if let row = pane.commands.firstIndex(where: { $0.id == "reload:" }) {
            pane.table.selectRowIndexes([row], byExtendingSelection: false)
            pane.recorder.take(KeyShortcut("j"))
            check("polish: pressing keys in the box gives the command that key", menuItem("reload:")?.keyEquivalent == "j" && menuItem("reload:")?.keyEquivalentModifierMask == .command, menuItem("reload:")?.keyEquivalent)
            check("polish: …and it says so", pane.statusLabel.stringValue == "“Reload Page” is now ⌘J.", pane.statusLabel.stringValue)
            check("polish: …and keeps it", BrowserSettings.shortcutOverrides["reload:"] == KeyShortcut("j"))
            pane.recorder.take(KeyShortcut("space", [.command]))
            check("polish: the Mac's own keys are refused, saying whose", pane.statusLabel.stringValue == "⌘Space is the Mac's own, for Spotlight." && menuItem("reload:")?.keyEquivalent == "j", pane.statusLabel.stringValue)
            pane.recorder.take(KeyShortcut("t"))
            check("polish: a key another command has is refused, naming it", pane.statusLabel.stringValue == "⌘T is “New Tab”.", pane.statusLabel.stringValue)
            pane.recorder.take(KeyShortcut("r", [.shift]))
            check("polish: a key without ⌘ is refused", pane.statusLabel.stringValue == "A shortcut needs ⌘, or a function key.", pane.statusLabel.stringValue)
            pane.resetButton.performClick(nil)
            check("polish: Reset gives the key back", menuItem("reload:")?.keyEquivalent == "r" && BrowserSettings.shortcutOverrides["reload:"] == nil)
        }
        if let row = pane.commands.firstIndex(where: { $0.id == "terminate:" }) {
            pane.table.selectRowIndexes([row], byExtendingSelection: false)
            check("polish: the keys every Mac app has cannot be moved", !pane.recorder.isEnabled && pane.statusLabel.stringValue.contains("keeps its key"), pane.statusLabel.stringValue)
        }
        await pause(0.3)
        snapshot(settings.window, "polish-shortcuts")
        settings.show(.tabs)
        check("polish: Settings → Tabs holds where tabs go and Memory Saver", settings.tabsPopUp.window === settings.window && settings.memorySaverCheckbox.window === settings.window
              && settings.autoPictureInPictureCheckbox.window === settings.window)
        await pause(0.3)
        snapshot(settings.window, "polish-tabs-settings")

        // Every control VoiceOver reads has a name, in every pane and the browser window.
        var unnamed: [String] = []
        for pane in [SettingsWindowController.Pane.general, .tabs, .passwords, .autofill, .privacy, .websites, .extensions, .developer, .advanced] {
            settings.show(pane)
            await pause(0.1)
            if let view = settings.window?.contentView { unnamed += Accessibility.unnamedControls(in: view).map { "Settings \(pane): \($0)" } }
        }
        settings.window?.close()
        if let view = browser.window?.contentView { unnamed += Accessibility.unnamedControls(in: view).map { "browser: \($0)" } }
        unnamed += Accessibility.unnamedToolbarItems(in: browser.window?.toolbar).map { "toolbar: \($0)" }
        check("polish: every control has a name for VoiceOver", unnamed.isEmpty, unnamed)

        // Trackpad.
        check("polish: pages zoom with a pinch, and two-finger double-tap zooms in on a part", browser.pageWebView.allowsMagnification && browser.pageWebView.allowsBackForwardNavigationGestures)

        // The tab overview.
        func page(_ title: String) -> URL { URL(string: site + "/page?title=" + title)! }
        let alpha = app.newTab(beside: browser, url: page("Alpha"), inFront: false)
        let beta = app.newTab(beside: alpha, url: page("Beta"), inFront: false)
        _ = await waitFor { alpha.window?.title == "Alpha" && beta.window?.title == "Beta" && !beta.pageWebView.isLoading }
        browser.toggleTabOverview(nil)
        check("polish: Show All Tabs shows every tab of the window as a picture", await waitFor { browser.tabOverview?.tiles.count == 3 }, browser.tabOverview?.tiles.count as Any)
        let overview = browser.tabOverview
        check("polish: …the tab in front pictured as it is", overview?.entries.first { $0.controller === browser }?.image != nil)
        check("polish: …and the tab in front chosen", overview?.shown.indices.contains(overview?.selectedIndex ?? -1) == true && overview?.shown[overview!.selectedIndex].controller === browser)
        check("polish: …each tile named for VoiceOver", overview?.tiles.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty } == true)
        await pause(0.4)
        check("polish: …over the page, fully shown", overview?.view.alphaValue == 1 && overview?.view.superview === browser.pageOverlayHost
              && overview?.view.frame == browser.pageOverlayHost.bounds && overview?.view.isHidden == false && (overview?.view.frame.width ?? 0) > 600,
              "alpha \(overview?.view.alphaValue as Any) frame \(overview?.view.frame as Any) bounds \(browser.pageOverlayHost.bounds)")
        snapshot(browser.window, "polish-tab-overview")
        overview?.searchField.stringValue = "bet"
        overview?.apply(filter: "bet")
        check("polish: typing narrows it to matching tabs", overview?.tiles.count == 1 && overview?.shown.first?.controller === beta)
        overview?.openSelected()
        check("polish: Return opens the chosen tab", await waitFor { self.front === beta && browser.tabOverview == nil })
        beta.toggleTabOverview(nil)
        _ = await waitFor { beta.tabOverview?.tiles.count == 3 }
        if let tile = beta.tabOverview?.tiles.first(where: { $0.titleLabel.stringValue == "Alpha" }) {
            tile.closeButton.performClick(nil)
            check("polish: ✕ on a tile closes that tab", await waitFor { self.tabs(of: browser).count == 2 && beta.tabOverview?.tiles.count == 2 }, self.tabs(of: browser).count)
        }
        beta.tabOverview?.close()
        check("polish: Esc leaves the overview", beta.tabOverview == nil)
        Accessibility.reduceMotionOverride = true
        beta.toggleTabOverview(nil)
        check("polish: with Reduce Motion on, the overview is simply there", beta.tabOverview?.view.alphaValue == 1)
        beta.tabOverview?.close()
        Accessibility.reduceMotionOverride = nil
        browser.show()
        _ = await waitFor { self.front === browser }

        // Handoff.
        check("polish: the page is offered to the person's other devices", browser.userActivity?.activityType == NSUserActivityTypeBrowsingWeb && browser.userActivity?.webpageURL?.absoluteString == site + "/second",
              browser.userActivity?.webpageURL as Any)
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = page("Handed")
        let taken = app.application(NSApp, continue: activity, restorationHandler: { _ in })
        let handed = await waitFor { self.front?.currentURL == page("Handed") }
        check("polish: a page from another device opens in a new tab", taken && handed, self.front?.currentURL as Any)
        app.newPrivateWindow(nil)
        _ = await waitFor { self.app.browserControllers.contains { $0.isPrivate } }
        if let secret = app.browserControllers.last(where: \.isPrivate) {
            secret.load(URL(string: site + "/second")!)
            _ = await waitFor { !secret.pageWebView.isLoading && secret.currentURL?.path == "/second" }
            check("polish: a private window offers nothing", secret.userActivity == nil)
            secret.window?.close()
        }

        // The error page.
        browser.show()
        browser.load(URL(string: "http://127.0.0.1:8799/nothing")!)
        check("polish: a site that refuses says so, in plain words", await waitFor { (await self.js("return document.title", in: browser)) as? String == "“127.0.0.1” refused the connection" },
              await js("return document.title + ' / ' + (document.querySelector('details p') || {}).textContent", in: browser))
        check("polish: …in light or dark, with Try Again going back to the address", (await js("return document.querySelector('meta[name=color-scheme]').content + ' ' + document.querySelector('a.try').getAttribute('href')", in: browser)) as? String == "light dark http://127.0.0.1:8799/nothing")
        check("polish: …and the address bar keeps the address, not about:blank", await waitFor { browser.currentURL?.absoluteString == "http://127.0.0.1:8799/nothing" && browser.addressText == "127.0.0.1" },
              "\(browser.currentURL as Any) \(browser.addressText)")
        browser.load(URL(string: "http://127.0.0.1:1/nothing")!)
        check("polish: a port WebKit keeps closed is explained", await waitFor { (await self.js("return document.title", in: browser)) as? String == "That address uses a port that is kept closed" })
        await pause(0.3)
        snapshot(browser.window, "polish-error-page")
        for tab in self.tabs(of: browser) where tab !== browser.window { tab.performClose(nil) }
    }
}
