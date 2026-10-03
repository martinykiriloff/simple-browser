import AppKit
import BrowserKit

/// #13 The sidebar, tab groups, pinned tabs and the command palette.
extension FeatureSelfTest {

    func sidebar() async {
        let browser = first
        let organizer = app.tabOrganizer
        browser.window?.makeKeyAndOrderFront(nil)
        await open("/page?title=Home%20base", in: browser)
        func page(_ title: String) -> URL { URL(string: site + "/page?title=" + title.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)! }
        let alpha = app.newTab(beside: browser, url: page("Alpha"), inFront: false)
        let beta = app.newTab(beside: alpha, url: page("Beta"), inFront: false)
        let gamma = app.newTab(beside: beta, url: page("Gamma"), inFront: false)
        let delta = app.newTab(beside: gamma, url: page("Delta"), inFront: false)
        _ = await waitFor { [alpha, beta, gamma, delta].allSatisfy { $0.window?.title.count ?? 0 > 1 && !$0.pageWebView.isLoading } }
        func strip() -> [BrowserWindowController] { organizer.tabs(besides: browser) }
        func titles() -> [String] { strip().map { $0.window?.title ?? "" } }

        // Pinned tabs.
        gamma.togglePinTab(nil)
        check("sidebar: a pinned tab goes first in the strip", await waitFor { strip().first === gamma }, titles())
        check("sidebar: …and carries a pin", await waitFor { gamma.tabAccessory == "pin" }, gamma.tabAccessory)
        check("sidebar: Window → Unpin Tab says so", menuTitle(for: #selector(BrowserWindowController.togglePinTab(_:)), in: gamma) == "Unpin Tab")

        // Groups.
        alpha.newTabGroup(nil)
        guard let groupID = alpha.groupID else { check("sidebar: New Tab Group makes a group", false); return }
        check("sidebar: New Tab Group asks for its name at once", await waitFor { alpha.lastGroupEditor?.view.window?.isVisible == true })
        if let editor = alpha.lastGroupEditor {
            editor.nameField.stringValue = "Research"
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.nameField))
            editor.swatches[GroupColor.allCases.firstIndex(of: .green)!].performClick(nil)
            editor.view.window?.performClose(nil)
        }
        check("sidebar: …and it is named and coloured there", organizer.groups[groupID]?.name == "Research" && organizer.groups[groupID]?.color == .green,
              organizer.groups[groupID] as Any)
        check("sidebar: the group's tabs carry its colour in the strip", await waitFor { alpha.tabAccessory == "group.green" }, alpha.tabAccessory)
        // Delta is two tabs away from Alpha, so joining moves it.
        organizer.add([delta], to: groupID)
        check("sidebar: a tab joining a group moves beside its tabs", await waitFor {
            let order = strip()
            guard let a = order.firstIndex(where: { $0 === alpha }), let d = order.firstIndex(where: { $0 === delta }) else { return false }
            return d == a + 1
        }, titles())
        check("sidebar: pinned tabs stay first", strip().first === gamma, titles())
        let link = app.newTab(beside: alpha, url: page("From a link"), inFront: false)
        check("sidebar: a page opened from a grouped tab joins the group", link.groupID == groupID)
        link.window?.performClose(nil)
        _ = await waitFor { !self.app.browserControllers.contains { $0 === link } }

        // The sidebar.
        BrowserSettings.sidebarShown = false
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === browser }
        let showSidebar = menuItem(#selector(BrowserWindowController.toggleBrowserSidebar(_:)))
        check("sidebar: View → Show Sidebar is ⇧⌘S", showSidebar?.keyEquivalent == "s" && showSidebar?.keyEquivalentModifierMask == [.command, .shift])
        browser.toggleBrowserSidebar(nil)
        check("sidebar: ⇧⌘S shows the sidebar", await waitFor { browser.isSidebarShown }, BrowserSettings.sidebarShown)
        check("sidebar: …on every tab of the window", await waitFor { [alpha, beta, gamma].allSatisfy(\.isSidebarShown) })
        check("sidebar: …and the tab bar stays, with tabs in the bar", browser.isTabBarShown)
        guard let bar = browser.sidebar else { return }
        _ = await waitFor { bar.pinnedStrip.buttons.count == 1 }
        check("sidebar: pinned tabs are icons at the top", bar.pinnedStrip.buttons.count == 1 && bar.pinnedStrip.buttons[0].toolTip == "Gamma",
              bar.pinnedStrip.buttons.map(\.toolTip))
        let groupRow = bar.rows.firstIndex(of: .group(groupID)) ?? 0
        check("sidebar: the group is a row with its tabs under it",
              bar.rows[groupRow...].prefix(3) == [.group(groupID), .tab(alpha.tab, inGroup: true), .tab(delta.tab, inGroup: true)], bar.rows)
        check("sidebar: then the tabs in no group, and New Tab", bar.rows.contains(.tab(beta.tab, inGroup: false)) && bar.rows.contains(.newTab))
        check("sidebar: the tab in front is the one chosen", bar.table.selectedRowIndexes == [bar.rows.firstIndex(of: .tab(browser.tab, inGroup: false)) ?? -1])
        check("sidebar: sites show their icons", await waitFor {
            (bar.table.view(atColumn: 0, row: bar.rows.firstIndex(of: .tab(beta.tab, inGroup: false)) ?? 0, makeIfNecessary: true) as? SidebarCell)?
                .imageView?.image?.size.width == 16
        })
        bar.activate(bar.rows.firstIndex(of: .group(groupID))!)
        check("sidebar: clicking the group collapses it", await waitFor { organizer.groups[groupID]?.isCollapsed == true })
        check("sidebar: …leaving its name in sight", await waitFor { bar.rows.contains(.group(groupID)) && !bar.rows.contains(.tab(alpha.tab, inGroup: true)) }, bar.rows)
        delta.window?.makeKeyAndOrderFront(nil)
        check("sidebar: …and the tab in front, if it is in the group", await waitFor {
            delta.sidebar?.rows.contains(.tab(delta.tab, inGroup: true)) == true && delta.sidebar?.rows.contains(.tab(alpha.tab, inGroup: true)) == false
        }, delta.sidebar?.rows as Any)
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === browser }
        bar.activate(bar.rows.firstIndex(of: .group(groupID))!)
        _ = await waitFor { organizer.groups[groupID]?.isCollapsed == false }
        bar.activate(bar.rows.firstIndex(of: .tab(beta.tab, inGroup: false))!)
        check("sidebar: clicking a tab shows it", await waitFor { self.front === beta })
        check("sidebar: …and its sidebar shows the same", await waitFor { beta.sidebar?.rows == bar.rows }, beta.sidebar?.rows as Any)
        snapshot(beta.window, "sidebar")

        // Dragging a tab in the sidebar: into the group, and out of it.
        organizer.move(beta, before: delta, group: groupID)
        check("sidebar: a tab dropped among a group's tabs joins it, there", await waitFor {
            let order = strip()
            return beta.groupID == groupID && order.firstIndex { $0 === beta }! + 1 == order.firstIndex { $0 === delta }!
        }, titles())
        organizer.move(beta, before: nil, group: nil)
        check("sidebar: …and dropped after them it leaves", await waitFor { beta.groupID == nil && strip().last === beta }, titles())

        // Tabs in the sidebar, as a setting.
        let settings = app.settingsWindow
        let roomBefore = beta.window?.contentLayoutRect.height ?? 0
        settings.show(.general)
        settings.tabsPopUp.selectItem(at: 1)
        _ = settings.tabsPopUp.target?.perform(settings.tabsPopUp.action, with: settings.tabsPopUp)
        check("sidebar: with tabs in the sidebar, the tab bar goes", await waitFor { !beta.isTabBarShown && beta.isSidebarShown })
        check("sidebar: …from every tab", await waitFor { [browser, alpha, gamma].allSatisfy { !$0.isTabBarShown } })
        check("sidebar: …giving the page its room", await waitFor { (beta.window?.contentLayoutRect.height ?? 0) >= roomBefore + 20 },
              "\(roomBefore) → \(beta.window?.contentLayoutRect.height ?? 0)")
        snapshot(beta.window, "sidebar-tabs")
        check("sidebar: …and every title in Settings is shown whole", settings.window?.contentView.map { root in
            Self.labels(in: root).allSatisfy { $0.frame.width >= $0.intrinsicContentSize.width - 0.5 } } ?? false)
        browser.toggleBrowserSidebar(nil)
        check("sidebar: hiding the sidebar then brings the tab bar back", await waitFor { beta.isTabBarShown && browser.isTabBarShown && !beta.isSidebarShown },
              [beta, browser].map { tab in "\(tab.window?.title ?? "") group=\(tab.window?.tabGroup?.isTabBarVisible as Any) accessories=\(tab.window?.titlebarAccessoryViewControllers.map { "\(type(of: $0)):\($0.isHidden)" } ?? []) sidebar=\(tab.isSidebarShown)" })
        settings.tabsPopUp.selectItem(at: 0)
        _ = settings.tabsPopUp.target?.perform(settings.tabsPopUp.action, with: settings.tabsPopUp)
        settings.window?.close()
        check("sidebar: back in the bar, the sidebar is hidden", !BrowserSettings.tabsInSidebar && !BrowserSettings.sidebarShown)

        // Groups and pins are part of the session.
        let saved = app.currentSession().windows.first { $0.tabs.contains { $0.title == "Alpha" } }
        check("sidebar: the session keeps groups and pins", saved?.groups.map(\.name) == ["Research"]
              && saved?.tabs.filter { $0.groupID == groupID }.count == 2 && saved?.tabs.first?.isPinned == true, saved?.tabs.map(\.title) as Any)
        let restoredFront = app.restore(SessionSnapshot(windows: saved.map { [$0] } ?? [])).first
        let restored = restoredFront.map(organizer.tabs(besides:)) ?? []
        check("sidebar: …and a restored window has them back", restored.first?.isPinned == true
              && restored.filter { $0.groupID == groupID }.map { $0.window?.title ?? "" } == ["Alpha", "Delta"], restored.map { $0.window?.title ?? "" })
        restoredFront?.closeWindowAndTabs(nil)
        _ = await waitFor { restored.allSatisfy { tab in !self.app.browserControllers.contains { $0 === tab } } }

        // Saved groups.
        organizer.save(groupID, profile: browser.profile)
        organizer.closeGroup(groupID)
        check("sidebar: closing a saved group closes its tabs", await waitFor { organizer.tabs(in: groupID).isEmpty && organizer.groups[groupID] == nil })
        guard let still = front else { return }
        still.toggleBrowserSidebar(nil)
        _ = await waitFor { still.isSidebarShown }
        guard let side = still.sidebar else { return }
        check("sidebar: …and it waits under Saved Groups", await waitFor { side.rows.contains(.saved(groupID)) }, side.rows)
        side.activate(side.rows.firstIndex(of: .saved(groupID))!)
        check("sidebar: opening it brings its tabs back, grouped", await waitFor { organizer.tabs(in: groupID).count == 2 && organizer.groups[groupID]?.name == "Research" })
        let reopened = organizer.tabs(in: groupID)
        _ = await waitFor { reopened.allSatisfy { !$0.pageWebView.isLoading && $0.currentURL != nil } }
        check("sidebar: …with the pages it had", Set(reopened.compactMap { $0.currentURL?.query }) == ["title=Alpha", "title=Delta"],
              reopened.map { $0.currentURL as Any })
        organizer.forgetSaved(groupID, profile: browser.profile)
        still.toggleBrowserSidebar(nil)

        await commandPalette(besides: gamma)

        for tab in organizer.tabs(besides: gamma) where tab !== first { tab.window?.performClose(nil) }
        first.isPinned = false
        first.groupID = nil
        organizer.changed()
        _ = await waitFor { self.tabs(of: self.first).count == 1 }
    }

    // MARK: - ⌘K

    private func commandPalette(besides anchor: BrowserWindowController) async {
        let palette = app.commandPalette
        anchor.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === anchor }
        let item = menuItem(#selector(BrowserWindowController.showCommandPalette(_:)))
        check("palette: File → Command Palette is ⌘K", item?.keyEquivalent == "k" && item?.keyEquivalentModifierMask == [.command])
        anchor.showCommandPalette(nil)
        check("palette: ⌘K opens it", await waitFor { palette.isShown })
        check("palette: with nothing typed it lists the open tabs", palette.results.allSatisfy { $0.item.kind == .tab } && palette.results.count >= 3,
              palette.results.map(\.item.title))
        check("palette: …each with its key", palette.results.allSatisfy { palette.keyText(for: $0, row: 0).contains("⌘") })
        palette.type("gamm")
        check("palette: typing finds a tab", palette.results.first?.item.title == "Gamma", palette.results.map(\.item.title))
        palette.type("alph")
        palette.open(at: 0)
        check("palette: Return shows it", await waitFor { self.front?.window?.title == "Alpha" && !palette.isShown })

        // Every command of the menu bar is there, and found by its name.
        let browser = front ?? anchor
        browser.showCommandPalette(nil)
        _ = await waitFor { palette.isShown }
        let offered = app.paletteEntries("", for: browser).filter { $0.item.kind == .command }
        var missing: [String] = []
        var unfound: [String] = []
        func walk(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let submenu = item.submenu { walk(submenu); continue }
                guard let action = item.action, !MenuCommands.skipped.contains(action), !item.title.isEmpty,
                      MenuCommands.isEnabled(item, action: action, browser: browser) else { continue }
                let title = action == #selector(AppDelegate.openProfileWindow(_:)) ? "Switch to Profile “\(item.title)”" : item.title
                guard let entry = offered.first(where: { $0.item.title == title }) else { missing.append(title); continue }
                if !CommandPalette.rank(title, offered.map(\.item), limit: CommandPalette.numberedResults).contains(entry.item) { unfound.append(title) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
        check("palette: every command in the menu bar is in it", missing.isEmpty && offered.count > 40, missing)
        check("palette: …and typing its name finds it among the first nine", unfound.isEmpty, unfound)
        check("palette: switching profile is a command", offered.contains { $0.item.title.hasPrefix("Switch to Profile “") })

        palette.type("reload page")
        check("palette: a command's shortcut is shown", palette.results.first.map { $0.shortcut == "⌘R" } ?? false, palette.results.first?.item.title as Any)
        palette.type("show sidebar")
        palette.open(at: 0)
        check("palette: a command runs on the tab it was asked from", await waitFor { browser.isSidebarShown }, palette.results.first?.item.title as Any)
        browser.toggleBrowserSidebar(nil)

        // With a hundred tabs open, every one is two keys away: its letter, then ⌘ and its number.
        let pages = (0..<100).map { index in
            SessionSnapshot.Tab(url: URL(string: site + "/page?title=\(index)")!, title: Self.hundredTitles[index], state: nil)
        }
        let window = SessionSnapshot.Window(profileID: browser.profile.id, frame: .init(x: 80, y: 80, width: 1100, height: 700), tabs: pages, selected: 0)
        guard let many = app.restore(SessionSnapshot(windows: [window])).first else { check("palette: (setup) a hundred tabs", false); return }
        let hundred = organizer(for: many)
        check("palette: (setup) a hundred tabs", hundred.count == 100, hundred.count)
        let items = app.paletteEntries("", for: many).map(\.item)
        var farthest = 0
        var far: [String] = []
        for tab in hundred {
            let keys = CommandPalette.keystrokes(toReach: "tab:\(tab.tab)", in: items, maxLength: 1) ?? 99
            farthest = max(farthest, keys)
            if keys > 2 { far.append(tab.window?.title ?? "") }
        }
        check("palette: with 100 tabs, every tab is under three keys away after ⌘K", farthest <= 2, far)
        let target = hundred[57]
        many.showCommandPalette(nil)
        _ = await waitFor { palette.isShown }
        if let hint = palette.hints["tab:\(target.tab)"] {
            palette.type(String(hint.letter))
            let pressed = keyDown(String(hint.number), modifiers: .command, in: palette.window)
            let shown = await waitFor { target.window?.tabGroup?.selectedWindow === target.window }
            check("palette: its letter and ⌘\(hint.number) show it", pressed && shown, target.window?.title as Any)
        } else {
            check("palette: every tab has a hint", false)
        }
        if palette.isShown { palette.close(returningTo: nil) }
        many.closeWindowAndTabs(nil)
        _ = await waitFor { !self.app.browserControllers.contains { $0 === many } }
    }

    private func organizer(for browser: BrowserWindowController) -> [BrowserWindowController] {
        app.tabOrganizer.tabs(besides: browser)
    }

    private func menuItem(_ action: Selector, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }

    private func menuTitle(for action: Selector, in browser: BrowserWindowController) -> String? {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        _ = browser.validateMenuItem(item)
        return item.title
    }

    /// A key press, as the window server would deliver it.
    private func keyDown(_ key: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow?) -> Bool {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, characters: key, charactersIgnoringModifiers: key,
                                                       isARepeat: false, keyCode: 0) else { return false }
        return window.performKeyEquivalent(with: event)
    }

    static func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub in
            [sub as? NSTextField].compactMap { $0 }.filter { !$0.isEditable && $0.stringValue.hasSuffix(":") } + labels(in: sub)
        }
    }

    /// A hundred tabs as people have them: many from the same few sites.
    static let hundredTitles: [String] = {
        let sites: [[String]] = [
            ["Pull requests", "Issues · keel", "Actions · keel", "swift-nio: Event-driven network framework", "apple/swift: The Swift Programming Language",
             "Notifications", "Release v1.4 · keel", "Settings · Branches", "Compare changes", "Insights · Contributors"],
            ["Inbox (12) - Gmail", "Starred - Gmail", "Sent Mail - Gmail", "Drafts (2) - Gmail", "Invoice for September - Gmail"],
            ["Q4 planning - Google Docs", "Roadmap 2027 - Google Sheets", "Team offsite notes - Google Docs", "Budget - Google Sheets", "Hiring plan - Google Docs"],
            ["WKWebView | Apple Developer Documentation", "NSWindowTab | Apple Developer Documentation", "WKWebExtension | Apple Developer Documentation",
             "Human Interface Guidelines: Sidebars", "WWDC25 videos", "Notarizing macOS software", "App Sandbox", "NSSplitViewController"],
            ["swift - How to reorder NSWindow tabs", "macos - NSOutlineView drag and drop", "javascript - fetch with credentials", "css - flexbox gap not working in Safari",
             "git - undo last commit", "python - list comprehension with two loops"],
            ["Tasmanian tiger - Wikipedia", "Byzantine Empire - Wikipedia", "Fourier transform - Wikipedia", "Great Barrier Reef - Wikipedia", "Ada Lovelace - Wikipedia",
             "Quantum entanglement - Wikipedia", "Mount Kilimanjaro - Wikipedia"],
            ["Lo-fi beats to code to - YouTube", "How WebKit renders a page - YouTube", "Sourdough for beginners - YouTube", "F1 Monza highlights - YouTube", "Home - YouTube"],
            ["Hacker News", "Show HN: A native macOS browser | Hacker News", "Ask HN: Who is hiring? | Hacker News"],
            ["SB-120 Sidebar with vertical tabs", "SB-121 Split view", "SB-130 Passkeys", "My issues", "Cycle 14"],
            ["Browser chrome – Figma", "Icons – Figma", "Onboarding flow – Figma", "Design system – Figma", "Marketing site – Figma"],
            ["Amazon.com: USB-C hub", "Your Orders", "Amazon.com: mechanical keyboard", "Shopping Cart"],
            ["Coffee near me - Maps", "Sofia Airport - Maps"],
            ["The Morning: Election results", "Wordle — The New York Times", "Cooking: Weeknight pasta"],
            ["#general - Acme - Slack", "#browser-team - Acme - Slack", "Threads - Acme - Slack"],
            ["Engineering wiki", "Meeting notes 29 Sep", "Reading list", "OKRs"],
            ["r/macapps", "r/swift", "r/MechanicalKeyboards", "r/AskHistorians"],
            ["Google Calendar - Week of 28 September", "Hotels in Lisbon", "Your booking: Porto", "Discover Weekly - Spotify", "Sofia 10-day forecast"],
            ["Array.prototype.flatMap() - MDN", "Fetch API - MDN", "CSS Grid Layout - MDN", "IntersectionObserver - MDN", "Swift Evolution", "Swift 6 migration guide"],
            ["Deployments – Vercel", "Retro board", "Zoom Meeting", "Google Translate", "best trackpad gestures at DuckDuckGo", "MacBook Pro - Apple", "Apple Support",
             "Dashboard – Local", "Login – Local", "Storybook"],
        ]
        return sites.flatMap { $0 }
    }()
}
