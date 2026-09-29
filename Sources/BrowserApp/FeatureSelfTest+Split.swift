import AppKit
import BrowserKit

/// #14 Split view: two pages side by side in one window.
extension FeatureSelfTest {

    func splitView() async {
        let organizer = app.tabOrganizer
        let left = first
        left.window?.makeKeyAndOrderFront(nil)
        await open("/page?title=Left", in: left)
        let right = app.newTab(beside: left, url: URL(string: site + "/page?title=Right")!, inFront: false)
        _ = await waitFor { right.window?.title == "Right" && !right.pageWebView.isLoading }
        let strip = { organizer.tabs(besides: left) }

        let item = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "View" }?.items.first { $0.title == "Open in Split View" }
        check("split: View → Open in Split View", item != nil)
        left.openInSplitView(nil)
        guard let split = left.split else { check("split: it opens with the next tab", false); return }
        check("split: it opens with the next tab, on the right", split.host === left && split.guest === right)
        check("split: both pages are in one window", left.pageArea.window === left.window && right.pageArea.window === left.window)
        check("split: the tab on the right leaves the tab bar", await waitFor { !strip().contains { $0 === right } }, strip().map { $0.window?.title ?? "" })
        check("split: …which shows the pair as one tab", left.window?.tab.title == "Left  |  Right", left.window?.tab.title as Any)
        check("split: each side keeps its own page", left.currentURL?.query == "title=Left" && right.currentURL?.query == "title=Right")
        check("split: the new side is in front, and its toolbar is the window's", split.focused === right && left.window?.toolbar === right.browserToolbar
              && right.window?.toolbar == nil)
        check("split: …and it is marked", split.guestPane.header.isFocused && !split.hostPane.header.isFocused)
        check("split: each side says what it shows", split.hostPane.header.label.stringValue.hasPrefix("Left") && split.guestPane.header.label.stringValue.hasPrefix("Right"),
              [split.hostPane.header.label.stringValue, split.guestPane.header.label.stringValue])
        await pause(0.3)
        snapshot(left.window, "split")

        // ⌥⌘← and ⌥⌘→ move between the sides.
        check("split: ⌥⌘← goes to the left side", press(123, in: left) && split.focused === left)
        check("split: …and the window's toolbar is that side's", left.window?.toolbar === left.browserToolbar && right.window?.toolbar === right.browserToolbar)
        check("split: ⌥⌘→ back to the right", press(124, in: left) && split.focused === right)

        // Menus act on the side in front.
        let location = NSMenuItem(title: "Open Location…", action: #selector(BrowserWindowController.focusAddressBar(_:)), keyEquivalent: "l")
        left.window?.makeFirstResponder(right.pageWebView)
        let target = MenuCommands.target(of: location, action: location.action!, browser: left)
        check("split: the menus reach the side in front", target === right, target.map { String(describing: type(of: $0)) } as Any)
        if let target { NSApp.sendAction(location.action!, to: target, from: location) }
        check("split: …so File → Open Location edits that side's address", right.isEditingAddress && !left.isEditingAddress)
        left.window?.makeFirstResponder(right.pageWebView)
        check("split: the page beside never sleeps", await right.mustStayLive())

        // The divider is remembered.
        split.setFraction(0.3)
        check("split: the divider moves", await waitFor { abs(split.fraction - 0.3) < 0.02 }, split.fraction)
        check("split: …and where it was left is remembered", abs(BrowserSettings.splitFraction - 0.3) < 0.02, BrowserSettings.splitFraction)

        // Groups of the session.
        let saved = app.currentSession().windows.first { $0.tabs.contains { $0.title == "Right" } }
        check("split: the session keeps the pair, as one window", saved?.tabs.map(\.title).suffix(2) == ["Left", "Right"] && saved?.tabs.last?.besidePrevious == true
              && app.currentSession().windows.filter { $0.tabs.contains { $0.title == "Right" } }.count == 1, saved?.tabs.map(\.title) as Any)

        // Closing a side leaves the other.
        split.close(right)
        check("split: closing a side closes that tab", await waitFor { !self.app.browserControllers.contains { $0 === right } })
        check("split: …and the other is a whole tab again", left.split == nil && left.pageArea.superview != nil && left.pageArea.window === left.window
              && left.window?.tab.title == left.window?.title && left.window?.toolbar === left.browserToolbar,
              "split \(left.split as Any), tab \(left.window?.tab.title ?? "") toolbar \(left.window?.toolbar === left.browserToolbar)")
        check("split: …whose page fills the window", await waitFor { abs(left.pageArea.frame.width - (left.window?.contentView?.frame.width ?? 0)) < 2 },
              "\(left.pageArea.frame.width) of \(left.window?.contentView?.frame.width ?? 0)")

        // A link, beside; then Close Split View gives two tabs.
        left.openLinkInSplitView(URL(string: site + "/page?title=Linked")!)
        guard let linked = left.split?.guest else { check("split: Open Link in Split View", false); return }
        check("split: Open Link in Split View opens it beside", await waitFor { linked.window?.title == "Linked" })
        check("split: …at the width last left", await waitFor { abs((left.split?.fraction ?? 0) - 0.3) < 0.03 }, left.split?.fraction as Any)
        left.closeSplitView(nil)
        check("split: Close Split View leaves two tabs, side by side in the bar", await waitFor {
            let tabs = strip()
            guard let l = tabs.firstIndex(where: { $0 === left }), let r = tabs.firstIndex(where: { $0 === linked }) else { return false }
            return r == l + 1 && !left.isInSplit && !linked.isInSplit
        }, strip().map { $0.window?.title ?? "" })
        check("split: …each in its own window", linked.pageArea.window === linked.window)

        // ⌘W on the side in front closes that side.
        left.openInSplitView(with: linked)
        _ = await waitFor { left.split != nil }
        left.split?.focus(linked)
        check("split: ⌘W with the right side in front", left.window.map { left.windowShouldClose($0) } == false)
        check("split: …closes the right tab and keeps the left", await waitFor { !self.app.browserControllers.contains { $0 === linked } && !left.isInSplit },
              app.browserControllers.map { $0.window?.title ?? "" })

        // A tab dragged from the sidebar to the page's edge.
        let dragged = app.newTab(beside: left, url: URL(string: site + "/page?title=Dragged")!, inFront: false)
        _ = await waitFor { dragged.window?.title == "Dragged" }
        left.showSplitDropZone(true)
        check("split: while a tab is dragged, the page's edge takes it", left.splitDropZone?.superview === left.pageArea)
        let dropped = left.splitDropZone?.drop(dragged.tab.description) ?? false
        left.showSplitDropZone(false)
        check("split: …and dropping it there opens the split", dropped && left.split?.guest === dragged && left.splitDropZone == nil,
              "dropped \(dropped) guest \(left.split?.guest?.window?.title ?? "none") zone \(left.splitDropZone as Any) dragged in strip \(strip().contains { $0 === dragged }) split \(left.isInSplit)/\(dragged.isInSplit)")

        // The session brings a split back.
        if let window = app.currentSession().windows.first(where: { $0.tabs.contains { $0.title == "Dragged" } }),
           let restored = app.restore(SessionSnapshot(windows: [window])).first {
            let host = organizer.tabs(besides: restored).first { $0.split != nil }
            check("split: a restored window has its split back", host?.split?.guest?.currentURL?.query == "title=Dragged", host?.window?.title as Any)
            restored.closeWindowAndTabs(nil)
            host?.split?.guest?.window?.performClose(nil)
        }
        left.split?.end()
        dragged.window?.performClose(nil)
        _ = await waitFor { self.tabs(of: left).count == 1 && !left.isInSplit }
        BrowserSettings.splitFraction = 0.5
    }

    /// ⌥⌘ and an arrow, through the app, as the keyboard would.
    private func press(_ keyCode: UInt16, in tab: BrowserWindowController) -> Bool {
        guard let window = tab.window, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option, .function, .numericPad],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: String(UnicodeScalar(keyCode == 123 ? 0xF702 : 0xF703)!), charactersIgnoringModifiers: String(UnicodeScalar(keyCode == 123 ? 0xF702 : 0xF703)!),
            isARepeat: false, keyCode: keyCode) else { return false }
        NSApp.sendEvent(event)
        return true
    }
}
