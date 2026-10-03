import AppKit
import BrowserKit

/// The app has no nib, so the menu bar is built in code. Menu items with a nil
/// target resolve through the responder chain: window controller first, then
/// the app delegate.
@MainActor
enum MainMenu {
    static func install(profilesMenuDelegate: NSMenuDelegate, historyMenuDelegate: NSMenuDelegate, bookmarksMenuDelegate: NSMenuDelegate,
                        tabGroupsMenuDelegate: NSMenuDelegate) {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(historyMenuItem(delegate: historyMenuDelegate))
        mainMenu.addItem(bookmarksMenuItem(delegate: bookmarksMenuDelegate))
        mainMenu.addItem(profilesMenuItem(delegate: profilesMenuDelegate))
        mainMenu.addItem(developMenuItem())
        mainMenu.addItem(windowMenuItem(tabGroupsDelegate: tabGroupsMenuDelegate))
        NSApp.mainMenu = mainMenu
        applyShortcuts()
    }

    /// Every menu key follows the catalogue in BrowserKit, with the
    /// person's changes from Settings → Advanced; called again after a change.
    static func applyShortcuts() {
        let effective = Shortcuts.effective(overrides: BrowserSettings.shortcutOverrides)
        var done: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu); continue }
                guard let action = item.action, !item.isHidden else { continue }
                let id = NSStringFromSelector(action)
                guard let command = Shortcuts.command(id), !command.fixed, !done.contains(id) else { continue }
                done.insert(id)
                if let shortcut = effective[id] ?? nil {
                    let (key, flags) = shortcut.menuKeyEquivalent
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = flags
                } else {
                    item.keyEquivalent = ""
                }
            }
        }
        if let mainMenu = NSApp.mainMenu { walk(mainMenu) }
    }

    /// Items AppKit puts in the menus itself (Close All, Emoji & Symbols,
    /// Start Dictation): the Mac's, not the app's to audit or change.
    static let appKitOwn: Set<String> = ["closeAll:", "orderFrontCharacterPalette:", "startDictation:"]

    /// Every key the menu bar answers to, by command: the audit's other half.
    static func menuShortcuts() -> [String: KeyShortcut] {
        var result: [String: KeyShortcut] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu); continue }
                guard let action = item.action, !item.isHidden, let shortcut = KeyShortcut(menuItem: item) else { continue }
                let id = NSStringFromSelector(action)
                if appKitOwn.contains(id) { continue }
                if result[id] == nil { result[id] = shortcut }
            }
        }
        if let mainMenu = NSApp.mainMenu { walk(mainMenu) }
        return result
    }

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(withTitle: "About Keel",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(withTitle: "Passwords…", action: #selector(AppDelegate.showPasswords(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Keel",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Keel",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return wrap(menu)
    }

    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Window",
                     action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        let privateWindow = menu.addItem(withTitle: "New Private Window",
                                         action: #selector(AppDelegate.newPrivateWindow(_:)), keyEquivalent: "n")
        privateWindow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "New Tab",
                     action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        menu.addItem(withTitle: "Open Location…",
                     action: #selector(BrowserWindowController.focusAddressBar(_:)), keyEquivalent: "l")
        menu.addItem(withTitle: "Command Palette…",
                     action: #selector(BrowserWindowController.showCommandPalette(_:)), keyEquivalent: "k")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Import From…", action: #selector(AppDelegate.showImport(_:)), keyEquivalent: "")
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
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(withTitle: "Find…", action: #selector(BrowserWindowController.findInPage(_:)), keyEquivalent: "f")
        find.addItem(withTitle: "Find Next", action: #selector(BrowserWindowController.findNextInPage(_:)), keyEquivalent: "g")
        let previous = find.addItem(withTitle: "Find Previous", action: #selector(BrowserWindowController.findPreviousInPage(_:)), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        find.addItem(withTitle: "Use Selection for Find", action: #selector(BrowserWindowController.useSelectionForFind(_:)), keyEquivalent: "e")
        let findItem = menu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        return wrap(menu)
    }

    private static func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        let sidebar = menu.addItem(withTitle: "Show Sidebar", action: #selector(BrowserWindowController.toggleBrowserSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .shift]
        let overview = menu.addItem(withTitle: "Show All Tabs", action: #selector(BrowserWindowController.toggleTabOverview(_:)), keyEquivalent: "\\")
        overview.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Enter Picture in Picture", action: #selector(BrowserWindowController.togglePictureInPicture(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Split View", action: #selector(BrowserWindowController.openInSplitView(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Close Split View", action: #selector(BrowserWindowController.closeSplitView(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Page",
                     action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
        let hardReload = menu.addItem(withTitle: "Reload Page From Origin",
                                      action: #selector(BrowserWindowController.reloadFromOrigin(_:)),
                                      keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Stop",
                     action: #selector(BrowserWindowController.stopLoading(_:)), keyEquivalent: ".")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Actual Size", action: #selector(BrowserWindowController.zoomReset(_:)), keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "+")
        // ⌘= is ⌘+ without Shift, which is how it is typed on most keyboards.
        let zoomInUnshifted = menu.addItem(withTitle: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "=")
        zoomInUnshifted.isHidden = true
        zoomInUnshifted.allowsKeyEquivalentWhenHidden = true
        menu.addItem(withTitle: "Zoom Out", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(.separator())
        let reader = menu.addItem(withTitle: "Show Reader", action: #selector(BrowserWindowController.toggleReader(_:)), keyEquivalent: "r")
        reader.keyEquivalentModifierMask = [.command, .shift]
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
        // ⌥⌘L is Downloads, as in Safari.
        recorder.keyEquivalentModifierMask = [.command, .option, .control]

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
        let pick = menu.addItem(withTitle: "Pick Color…", action: #selector(AppDelegate.pickColor(_:)), keyEquivalent: "c")
        pick.keyEquivalentModifierMask = [.command, .control, .option]
        let extensions = NSMenu(title: "Developer Extensions")
        for ext in DevExtension.allCases {
            let item = extensions.addItem(withTitle: ext.title, action: #selector(AppDelegate.toggleDevExtension(_:)), keyEquivalent: "")
            item.representedObject = ext.rawValue
        }
        extensions.addItem(.separator())
        let note = extensions.addItem(withTitle: "React, dataLayer and JSON Viewer apply to new tabs", action: nil, keyEquivalent: "")
        note.isEnabled = false
        let extensionsItem = menu.addItem(withTitle: "Developer Extensions", action: nil, keyEquivalent: "")
        extensionsItem.submenu = extensions
        menu.addItem(withTitle: "AI Agent Server…", action: #selector(AppDelegate.showDeveloperSettings(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "WebKit Web Inspector",
                     action: #selector(BrowserWindowController.showWebKitInspector(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Debug in Safari…",
                     action: #selector(BrowserWindowController.explainDebugInSafari(_:)),
                     keyEquivalent: "")
        return wrap(menu)
    }

    private static func windowMenuItem(tabGroupsDelegate: NSMenuDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pin Tab", action: #selector(BrowserWindowController.togglePinTab(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New Tab Group", action: #selector(BrowserWindowController.newTabGroup(_:)), keyEquivalent: "")
        let groups = NSMenu(title: "Move Tab to Group")
        groups.delegate = tabGroupsDelegate
        let groupsItem = menu.addItem(withTitle: "Move Tab to Group", action: nil, keyEquivalent: "")
        groupsItem.submenu = groups
        menu.addItem(withTitle: "Remove Tab from Group", action: #selector(BrowserWindowController.removeTabFromGroup(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Mute Tab", action: #selector(BrowserWindowController.toggleMuteTab(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Mute Background Tabs", action: #selector(AppDelegate.muteBackgroundTabs(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let downloads = menu.addItem(withTitle: "Downloads", action: #selector(AppDelegate.showDownloadsWindow(_:)), keyEquivalent: "l")
        downloads.keyEquivalentModifierMask = [.command, .option]
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

/// Window → Move Tab to Group: the front window's groups, filled as it opens.
@MainActor
final class TabGroupsMenuFiller: NSObject, NSMenuDelegate {
    let organizer: TabOrganizer
    let front: () -> BrowserWindowController?

    init(organizer: TabOrganizer, front: @escaping () -> BrowserWindowController?) {
        self.organizer = organizer
        self.front = front
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let browser = front() else { return }
        for group in organizer.groups(besides: browser) {
            let name = group.displayName(firstTab: organizer.tabs(in: group.id).first?.window?.title)
            menu.addItem(ClosureMenuItem(name, state: browser.groupID == group.id ? .on : .off,
                                         image: TabSidebarController.dot(group.color)) { [organizer] in organizer.add([browser], to: group.id) })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("New Group") { browser.newTabGroup(nil) })
    }
}
