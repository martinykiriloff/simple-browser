import Foundation

/// A key with its modifiers, as a menu item carries it: `key` is the
/// character or a named key ("\\", "[", "left", "f12"), lower case.
public struct KeyShortcut: Hashable, Codable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// The Mac way of writing it: ⌃⌥⇧⌘ then the key, "⇧⌘T".
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyNames[key, default: key.uppercased()]
    }

    static let keyNames: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space", "escape": "Esc", "return": "↩", "tab": "⇥",
        "delete": "⌫", ",": ",", ".": ".", "f12": "F12", "\\": "\\",
    ]

    /// A shortcut a person can be given: it has ⌘ or is a function key, and
    /// is not a bare letter that typing would collide with.
    public var isUsable: Bool {
        if key.hasPrefix("f"), Int(key.dropFirst()) != nil { return true }
        return modifiers.contains(.command) && !key.isEmpty
    }
}

/// One command that can be given a key, with what Safari and Chrome use for
/// it, so the audit is in one place and the README table is made from it.
public struct ShortcutCommand: Hashable, Sendable {
    /// The menu action's selector name ("newWindow:"), or a name for keys
    /// handled outside the menu ("tab.select").
    public var id: String
    public var title: String
    public var menu: String
    public var shortcut: KeyShortcut?
    public var safari: String
    public var chrome: String
    /// Handled by the window itself rather than the menu; not changeable.
    public var fixed: Bool

    public init(_ id: String, _ title: String, menu: String, _ shortcut: KeyShortcut?, safari: String, chrome: String, fixed: Bool = false) {
        self.id = id; self.title = title; self.menu = menu; self.shortcut = shortcut; self.safari = safari; self.chrome = chrome; self.fixed = fixed
    }
}

/// Every keyboard shortcut in the app, checked against each other and against
/// the Mac's own, and what a person may change them to.
public enum Shortcuts {
    public struct Conflict: Equatable, Sendable {
        public var shortcut: KeyShortcut
        public var commands: [String]
        /// "macOS: Spotlight" when the Mac has it.
        public var system: String?
    }

    /// Keys macOS keeps for itself, whatever the app. From System Settings →
    /// Keyboard → Keyboard Shortcuts, as they are on a new Mac.
    public static let systemReserved: [(KeyShortcut, String)] = [
        (KeyShortcut("space", [.command]), "Spotlight"),
        (KeyShortcut("space", [.command, .option]), "Finder search"),
        (KeyShortcut("space", [.command, .control]), "Emoji & Symbols"),
        (KeyShortcut("tab", [.command]), "switching apps"),
        (KeyShortcut("tab", [.command, .shift]), "switching apps"),
        (KeyShortcut("3", [.command, .shift]), "screenshots"),
        (KeyShortcut("4", [.command, .shift]), "screenshots"),
        (KeyShortcut("5", [.command, .shift]), "screenshots"),
        (KeyShortcut("escape", [.command, .option]), "Force Quit"),
        (KeyShortcut("q", [.command, .control]), "locking the screen"),
        (KeyShortcut("q", [.command, .shift]), "logging out"),
        (KeyShortcut("d", [.command, .option]), "the Dock"),
        (KeyShortcut("up", [.control]), "Mission Control"),
        (KeyShortcut("down", [.control]), "App Exposé"),
        (KeyShortcut("left", [.control]), "Spaces"),
        (KeyShortcut("right", [.control]), "Spaces"),
        (KeyShortcut("f", [.command, .control]), "full screen"),
        (KeyShortcut("f5", [.command]), "VoiceOver"),
        (KeyShortcut("f", [.command, .option, .control]), "fill the screen"),
        (KeyShortcut("8", [.command, .option]), "Zoom (accessibility)"),
        (KeyShortcut("=", [.command, .option]), "Zoom in (accessibility)"),
        (KeyShortcut("-", [.command, .option]), "Zoom out (accessibility)"),
        (KeyShortcut("t", [.command, .option, .control]), "Zoom (accessibility)"),
        (KeyShortcut("d", [.command, .control]), "Look Up"),
        (KeyShortcut("h", [.command]), "hiding the app"),
        (KeyShortcut("h", [.command, .option]), "hiding other apps"),
        (KeyShortcut("q", [.command]), "quitting"),
        (KeyShortcut("m", [.command]), "minimizing"),
        (KeyShortcut(",", [.command]), "Settings"),
    ]

    /// Shortcuts that are the Mac's but the app's too, in the standard menus;
    /// listed so a person cannot move them to something else.
    static let standard: Set<String> = ["hide:", "hideOtherApplications:", "terminate:", "performMiniaturize:", "toggleFullScreen:", "showSettings:"]
    public static func isStandard(_ id: String) -> Bool { standard.contains(id) }

    public static let commands: [ShortcutCommand] = [
        ShortcutCommand("showSettings:", "Settings…", menu: "SimpleBrowser", KeyShortcut(","), safari: "⌘,", chrome: "⌘,"),
        ShortcutCommand("hide:", "Hide SimpleBrowser", menu: "SimpleBrowser", KeyShortcut("h"), safari: "⌘H", chrome: "⌘H"),
        ShortcutCommand("hideOtherApplications:", "Hide Others", menu: "SimpleBrowser", KeyShortcut("h", [.command, .option]), safari: "⌥⌘H", chrome: "⌥⌘H"),
        ShortcutCommand("terminate:", "Quit SimpleBrowser", menu: "SimpleBrowser", KeyShortcut("q"), safari: "⌘Q", chrome: "⌘Q"),
        ShortcutCommand("newWindow:", "New Window", menu: "File", KeyShortcut("n"), safari: "⌘N", chrome: "⌘N"),
        ShortcutCommand("newPrivateWindow:", "New Private Window", menu: "File", KeyShortcut("n", [.command, .shift]), safari: "⇧⌘N", chrome: "⇧⌘N"),
        ShortcutCommand("newWindowForTab:", "New Tab", menu: "File", KeyShortcut("t"), safari: "⌘T", chrome: "⌘T"),
        ShortcutCommand("focusAddressBar:", "Open Location…", menu: "File", KeyShortcut("l"), safari: "⌘L", chrome: "⌘L"),
        ShortcutCommand("showCommandPalette:", "Command Palette…", menu: "File", KeyShortcut("k"), safari: "—", chrome: "—"),
        ShortcutCommand("performClose:", "Close Tab", menu: "File", KeyShortcut("w"), safari: "⌘W", chrome: "⌘W"),
        ShortcutCommand("closeWindowAndTabs:", "Close Window", menu: "File", KeyShortcut("w", [.command, .shift]), safari: "⇧⌘W", chrome: "⇧⌘W"),
        ShortcutCommand("reopenClosedTab:", "Reopen Closed Tab", menu: "File", KeyShortcut("t", [.command, .shift]), safari: "⇧⌘T", chrome: "⇧⌘T"),
        ShortcutCommand("undo:", "Undo", menu: "Edit", KeyShortcut("z"), safari: "⌘Z", chrome: "⌘Z"),
        ShortcutCommand("redo:", "Redo", menu: "Edit", KeyShortcut("z", [.command, .shift]), safari: "⇧⌘Z", chrome: "⇧⌘Z"),
        ShortcutCommand("cut:", "Cut", menu: "Edit", KeyShortcut("x"), safari: "⌘X", chrome: "⌘X"),
        ShortcutCommand("copy:", "Copy", menu: "Edit", KeyShortcut("c"), safari: "⌘C", chrome: "⌘C"),
        ShortcutCommand("paste:", "Paste", menu: "Edit", KeyShortcut("v"), safari: "⌘V", chrome: "⌘V"),
        ShortcutCommand("pasteAndGo:", "Paste and Go", menu: "Edit", KeyShortcut("v", [.command, .shift]), safari: "⇧⌘V (Paste and Match Style)", chrome: "⇧⌘V (Paste and Match Style)"),
        ShortcutCommand("selectAll:", "Select All", menu: "Edit", KeyShortcut("a"), safari: "⌘A", chrome: "⌘A"),
        ShortcutCommand("findInPage:", "Find…", menu: "Edit › Find", KeyShortcut("f"), safari: "⌘F", chrome: "⌘F"),
        ShortcutCommand("findNextInPage:", "Find Next", menu: "Edit › Find", KeyShortcut("g"), safari: "⌘G", chrome: "⌘G"),
        ShortcutCommand("findPreviousInPage:", "Find Previous", menu: "Edit › Find", KeyShortcut("g", [.command, .shift]), safari: "⇧⌘G", chrome: "⇧⌘G"),
        ShortcutCommand("useSelectionForFind:", "Use Selection for Find", menu: "Edit › Find", KeyShortcut("e"), safari: "⌘E", chrome: "⌘E"),
        ShortcutCommand("toggleBrowserSidebar:", "Show Sidebar", menu: "View", KeyShortcut("s", [.command, .shift]), safari: "⇧⌘L", chrome: "—"),
        ShortcutCommand("toggleTabOverview:", "Show All Tabs", menu: "View", KeyShortcut("\\", [.command, .shift]), safari: "⇧⌘\\", chrome: "—"),
        ShortcutCommand("reload:", "Reload Page", menu: "View", KeyShortcut("r"), safari: "⌘R", chrome: "⌘R"),
        ShortcutCommand("reloadFromOrigin:", "Reload Page From Origin", menu: "View", KeyShortcut("r", [.command, .option]), safari: "⌥⌘R", chrome: "⇧⌘R"),
        ShortcutCommand("stopLoading:", "Stop", menu: "View", KeyShortcut("."), safari: "⌘.", chrome: "⌘. / Esc"),
        ShortcutCommand("zoomReset:", "Actual Size", menu: "View", KeyShortcut("0"), safari: "⌘0", chrome: "⌘0"),
        ShortcutCommand("zoomIn:", "Zoom In", menu: "View", KeyShortcut("+"), safari: "⌘+", chrome: "⌘+"),
        ShortcutCommand("zoomOut:", "Zoom Out", menu: "View", KeyShortcut("-"), safari: "⌘-", chrome: "⌘-"),
        ShortcutCommand("toggleReader:", "Show Reader", menu: "View", KeyShortcut("r", [.command, .shift]), safari: "⇧⌘R", chrome: "—"),
        ShortcutCommand("translatePageTo:", "Translate Page", menu: "View", KeyShortcut("t", [.command, .option]), safari: "—", chrome: "—"),
        ShortcutCommand("toggleFullScreen:", "Enter Full Screen", menu: "View", KeyShortcut("f", [.command, .control]), safari: "⌃⌘F", chrome: "⌃⌘F"),
        ShortcutCommand("goBack:", "Back", menu: "History", KeyShortcut("["), safari: "⌘[", chrome: "⌘["),
        ShortcutCommand("goForward:", "Forward", menu: "History", KeyShortcut("]"), safari: "⌘]", chrome: "⌘]"),
        ShortcutCommand("goHome:", "Home", menu: "History", KeyShortcut("h", [.command, .shift]), safari: "⇧⌘H", chrome: "⇧⌘H"),
        ShortcutCommand("showHistory:", "Show All History", menu: "History", KeyShortcut("y"), safari: "⌘Y", chrome: "⌘Y"),
        ShortcutCommand("addBookmark:", "Add Bookmark…", menu: "Bookmarks", KeyShortcut("d"), safari: "⌘D", chrome: "⌘D"),
        ShortcutCommand("addToReadingList:", "Add to Reading List", menu: "Bookmarks", KeyShortcut("d", [.command, .shift]), safari: "⇧⌘D", chrome: "⇧⌘D (bookmark all tabs)"),
        ShortcutCommand("showBookmarks:", "Show Bookmarks", menu: "Bookmarks", KeyShortcut("b", [.command, .option]), safari: "⌥⌘B", chrome: "⌥⌘B"),
        ShortcutCommand("toggleFavoritesBar:", "Show Favorites Bar", menu: "Bookmarks", KeyShortcut("b", [.command, .shift]), safari: "⇧⌘B", chrome: "⇧⌘B"),
        ShortcutCommand("toggleDevTools:", "Show Developer Tools", menu: "Develop", KeyShortcut("i", [.command, .option]), safari: "⌥⌘I", chrome: "⌥⌘I"),
        ShortcutCommand("showDevToolsConsole:", "JavaScript Console", menu: "Develop", KeyShortcut("j", [.command, .option]), safari: "⌥⌘C", chrome: "⌥⌘J"),
        ShortcutCommand("inspectElementMode:", "Inspect Elements", menu: "Develop", KeyShortcut("c", [.command, .option]), safari: "—", chrome: "⌥⌘C"),
        ShortcutCommand("showRecorder:", "Show Recording Log", menu: "Develop", KeyShortcut("l", [.command, .option, .control]), safari: "—", chrome: "—"),
        ShortcutCommand("performMiniaturize:", "Minimize", menu: "Window", KeyShortcut("m"), safari: "⌘M", chrome: "⌘M"),
        ShortcutCommand("showDownloadsWindow:", "Downloads", menu: "Window", KeyShortcut("l", [.command, .option]), safari: "⌥⌘L", chrome: "⇧⌘J"),
        // Handled by the window: not in the menu, and not changeable.
        ShortcutCommand("tab.select", "Show tab 1–9", menu: "—", KeyShortcut("1–9"), safari: "⌘1–9", chrome: "⌘1–8, ⌘9 last", fixed: true),
        ShortcutCommand("tab.next", "Next tab", menu: "—", KeyShortcut("]", [.command, .shift]), safari: "⇧⌘] / ⌃⇥", chrome: "⌥⌘→ / ⌃⇥", fixed: true),
        ShortcutCommand("tab.previous", "Previous tab", menu: "—", KeyShortcut("[", [.command, .shift]), safari: "⇧⌘[ / ⌃⇧⇥", chrome: "⌥⌘← / ⌃⇧⇥", fixed: true),
        ShortcutCommand("tab.nextAlt", "Next tab (also)", menu: "—", KeyShortcut("right", [.command, .option]), safari: "—", chrome: "⌥⌘→", fixed: true),
        ShortcutCommand("tab.previousAlt", "Previous tab (also)", menu: "—", KeyShortcut("left", [.command, .option]), safari: "—", chrome: "⌥⌘←", fixed: true),
        ShortcutCommand("devtools.f12", "Developer Tools", menu: "—", KeyShortcut("f12", []), safari: "—", chrome: "F12", fixed: true),
        ShortcutCommand("openProfileWindow:", "Switch to profile 1–9", menu: "Profiles", KeyShortcut("1–9", [.command, .shift, .option]), safari: "—", chrome: "—", fixed: true),
    ]

    public static func command(_ id: String) -> ShortcutCommand? { commands.first { $0.id == id } }

    /// What each command answers to, with a person's changes applied. A
    /// change to nil takes the key away.
    public static func effective(overrides: [String: KeyShortcut?]) -> [String: KeyShortcut?] {
        var result: [String: KeyShortcut?] = [:]
        for command in commands {
            result[command.id] = command.fixed || standard.contains(command.id) ? command.shortcut : (overrides[command.id] ?? command.shortcut)
        }
        return result
    }

    /// Every key given to two commands, or kept by the Mac.
    public static func conflicts(in assignments: [String: KeyShortcut?]) -> [Conflict] {
        var byKey: [KeyShortcut: [String]] = [:]
        for (id, shortcut) in assignments {
            guard let shortcut else { continue }
            byKey[shortcut, default: []].append(id)
        }
        var result: [Conflict] = []
        for (shortcut, ids) in byKey {
            let system = systemReserved.first { $0.0 == shortcut }?.1
            let ours = ids.filter { command($0).map { !standard.contains($0.id) } ?? true }
            if ids.count > 1 || (system != nil && !ours.isEmpty) {
                result.append(Conflict(shortcut: shortcut, commands: ids.sorted(), system: system))
            }
        }
        return result.sorted { $0.shortcut.display < $1.shortcut.display }
    }

    /// Why a key cannot be given to a command, or nil when it can.
    public static func refusal(giving shortcut: KeyShortcut, to id: String, overrides: [String: KeyShortcut?]) -> String? {
        guard let target = command(id) else { return "There is no such command." }
        if target.fixed || standard.contains(id) { return "“\(target.title)” keeps its key." }
        guard shortcut.isUsable else { return "A shortcut needs ⌘, or a function key." }
        if let system = systemReserved.first(where: { $0.0 == shortcut }) { return "\(shortcut.display) is the Mac's own, for \(system.1)." }
        var trial = overrides
        trial[id] = shortcut
        let taken = effective(overrides: trial).first { $0.key != id && $0.value == shortcut }
        if let taken, let other = command(taken.key) { return "\(shortcut.display) is “\(other.title)”." }
        return nil
    }

    /// The README's table, so the two cannot drift apart.
    public static func readmeTable() -> String {
        var lines = ["| Command | SimpleBrowser | Safari | Chrome |", "|---|---|---|---|"]
        for command in commands where !standard.contains(command.id) {
            let ours = command.id == "tab.select" ? "⌘1–⌘9" : command.id == "openProfileWindow:" ? "⌥⇧⌘1–9" : (command.shortcut?.display ?? "—")
            lines.append("| \(command.title) | \(ours) | \(command.safari) | \(command.chrome) |")
        }
        return lines.joined(separator: "\n")
    }
}
