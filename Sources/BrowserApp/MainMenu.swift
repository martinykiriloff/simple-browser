import AppKit

/// The app has no nib, so the menu bar is built in code. Menu items with a nil
/// target resolve through the responder chain: window controller first, then
/// the app delegate.
@MainActor
enum MainMenu {
    static func install(profilesMenuDelegate: NSMenuDelegate, historyMenuDelegate: NSMenuDelegate, bookmarksMenuDelegate: NSMenuDelegate) {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(historyMenuItem(delegate: historyMenuDelegate))
        mainMenu.addItem(bookmarksMenuItem(delegate: bookmarksMenuDelegate))
        mainMenu.addItem(profilesMenuItem(delegate: profilesMenuDelegate))
        mainMenu.addItem(developMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(withTitle: "About SimpleBrowser",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(withTitle: "Passwords…", action: #selector(AppDelegate.showPasswords(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide SimpleBrowser",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SimpleBrowser",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return wrap(menu)
    }

    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Window",
                     action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "New Tab",
                     action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        menu.addItem(withTitle: "Open Location…",
                     action: #selector(BrowserWindowController.focusAddressBar(_:)), keyEquivalent: "l")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab",
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let closeWindow = menu.addItem(withTitle: "Close Window",
                                       action: #selector(BrowserWindowController.closeWindowAndTabs(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        let reopen = menu.addItem(withTitle: "Reopen Closed Tab",
                                  action: #selector(AppDelegate.reopenClosedTab(_:)), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        return wrap(menu)
    }

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteAndGo = menu.addItem(withTitle: "Paste and Go", action: #selector(BrowserWindowController.pasteAndGo(_:)), keyEquivalent: "v")
        pasteAndGo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return wrap(menu)
    }

    private static func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Reload Page",
                     action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
        let hardReload = menu.addItem(withTitle: "Reload Page From Origin",
                                      action: #selector(BrowserWindowController.reloadFromOrigin(_:)),
                                      keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Stop",
                     action: #selector(BrowserWindowController.stopLoading(_:)), keyEquivalent: ".")
        menu.addItem(.separator())
        let translate = menu.addItem(withTitle: "Translate Page",
                                     action: #selector(BrowserWindowController.translatePageTo(_:)), keyEquivalent: "t")
        translate.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show Original",
                     action: #selector(BrowserWindowController.showOriginalPage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let fullScreen = menu.addItem(withTitle: "Enter Full Screen",
                                      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        return wrap(menu)
    }

    private static func historyMenuItem(delegate: NSMenuDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "History")
        menu.delegate = delegate
        menu.addItem(withTitle: "Back",
                     action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        menu.addItem(withTitle: "Forward",
                     action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        let home = menu.addItem(withTitle: "Home",
                                action: #selector(BrowserWindowController.goHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reopen Last Closed Window",
                     action: #selector(AppDelegate.reopenLastClosedWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Reopen All Windows from Last Session",
                     action: #selector(AppDelegate.reopenLastSession(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show All History", action: #selector(AppDelegate.showHistory(_:)), keyEquivalent: "y")
        menu.addItem(withTitle: "Clear History…", action: #selector(AppDelegate.clearHistoryAction(_:)), keyEquivalent: "")
        return wrap(menu)
    }

    /// Add, show and the bookmarks themselves, filled when it opens.
    private static func bookmarksMenuItem(delegate: NSMenuDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "Bookmarks")
        menu.delegate = delegate
        menu.addItem(withTitle: "Add Bookmark…", action: #selector(BrowserWindowController.addBookmark(_:)), keyEquivalent: "d")
        let reading = menu.addItem(withTitle: "Add to Reading List",
                                   action: #selector(BrowserWindowController.addToReadingList(_:)), keyEquivalent: "d")
        reading.keyEquivalentModifierMask = [.command, .shift]
        let show = menu.addItem(withTitle: "Show Bookmarks", action: #selector(AppDelegate.showBookmarks(_:)), keyEquivalent: "b")
        show.keyEquivalentModifierMask = [.command, .option]
        let bar = menu.addItem(withTitle: "Hide Favorites Bar",
                               action: #selector(BrowserWindowController.toggleFavoritesBar(_:)), keyEquivalent: "b")
        bar.keyEquivalentModifierMask = [.command, .shift]
        return wrap(menu)
    }

    /// Filled each time it opens, by the delegate: see `ProfilesMenuFiller`.
    private static func profilesMenuItem(delegate: NSMenuDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "Profiles")
        menu.delegate = delegate
        return wrap(menu)
    }

    /// Shortcuts match Chrome: ⌥⌘I toggles, ⌥⌘J opens the console, ⌥⌘C
    /// starts picking an element. F12 is handled by the window controller.
    private static func developMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Develop")

        let toggle = menu.addItem(withTitle: "Show Developer Tools",
                                  action: #selector(BrowserWindowController.toggleDevTools(_:)),
                                  keyEquivalent: "i")
        toggle.keyEquivalentModifierMask = [.command, .option]

        let console = menu.addItem(withTitle: "JavaScript Console",
                                   action: #selector(BrowserWindowController.showDevToolsConsole(_:)),
                                   keyEquivalent: "j")
        console.keyEquivalentModifierMask = [.command, .option]

        let inspect = menu.addItem(withTitle: "Inspect Elements",
                                   action: #selector(BrowserWindowController.inspectElementMode(_:)),
                                   keyEquivalent: "c")
        inspect.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(withTitle: "Network",
                     action: #selector(BrowserWindowController.showDevToolsNetwork(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Sources",
                     action: #selector(BrowserWindowController.showDevToolsSources(_:)), keyEquivalent: "")

        menu.addItem(.separator())

        let dock = NSMenu(title: "Dock Side")
        for (title, side) in [("Dock to Bottom", "bottom"), ("Dock to Right", "right"), ("Separate Window", "undocked")] {
            let item = dock.addItem(withTitle: title,
                                    action: #selector(BrowserWindowController.dockDevTools(_:)),
                                    keyEquivalent: "")
            item.representedObject = side
        }
        let dockItem = menu.addItem(withTitle: "Dock Side", action: nil, keyEquivalent: "")
        dockItem.submenu = dock

        menu.addItem(.separator())

        let recorder = menu.addItem(withTitle: "Show Recording Log",
                                    action: #selector(BrowserWindowController.showRecorder(_:)),
                                    keyEquivalent: "l")
        recorder.keyEquivalentModifierMask = [.command, .option]

        let userAgents = NSMenu(title: "User Agent")
        for (index, preset) in UserAgentPreset.all.enumerated() {
            let item = userAgents.addItem(withTitle: preset.title,
                                          action: #selector(BrowserWindowController.selectUserAgent(_:)),
                                          keyEquivalent: "")
            item.tag = index
        }
        let userAgentItem = menu.addItem(withTitle: "User Agent", action: nil, keyEquivalent: "")
        userAgentItem.submenu = userAgents

        menu.addItem(.separator())
        menu.addItem(withTitle: "WebKit Web Inspector",
                     action: #selector(BrowserWindowController.showWebKitInspector(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Debug in Safari…",
                     action: #selector(BrowserWindowController.explainDebugInSafari(_:)),
                     keyEquivalent: "")
        return wrap(menu)
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return wrap(menu)
    }

    private static func wrap(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}

/// User-agent override presets. Google properties sniff for WebKit and serve
/// degraded paths, so this is a permanent fixture rather than a debug toy.
struct UserAgentPreset {
    let title: String
    /// Nil means WebKit's default.
    let value: String?

    static let all: [UserAgentPreset] = [
        UserAgentPreset(title: "Default (Safari)", value: nil),
        UserAgentPreset(title: "Chrome — macOS",
                        value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"),
        UserAgentPreset(title: "Firefox — macOS",
                        value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.6; rv:130.0) Gecko/20100101 Firefox/130.0"),
        UserAgentPreset(title: "Safari — iPhone",
                        value: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
        UserAgentPreset(title: "Safari — iPad",
                        value: "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
    ]
}
