import AppKit
import BrowserKit

/// ⌘K: one box for open tabs, every menu command, saved groups, bookmarks
/// and history, searched fuzzily and worked entirely from the keyboard.
/// ↑ ↓ move, Return opens, ⌘1–⌘9 open the first nine results, Esc closes.
/// With nothing typed each tab shows a hint: its letter, then ⌘ and its
/// number, opens it.
@MainActor
final class CommandPaletteController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    /// One result: what it is, and what choosing it does.
    struct Entry {
        let item: CommandPalette.Item
        let icon: NSImage?
        /// A key equivalent, for commands.
        let shortcut: String
        let run: () -> Void
    }

    /// Everything that can be offered for a query. Tabs and commands do not
    /// depend on it; bookmarks and history are searched with it.
    var source: ((String) -> [Entry])?
    weak var browser: BrowserWindowController?

    let field = NSTextField()
    let table = NSTableView()
    private(set) var results: [Entry] = []
    private(set) var hints: [String: CommandPalette.Hint] = [:]
    private var all: [Entry] = []

    init() {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.setAccessibilityLabel("Command palette")
        super.init(window: panel)
        QuietMode.apply(to: panel)
        panel.delegate = self
        panel.onNumber = { [weak self] number in self?.open(at: number - 1) }
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let root = NSVisualEffectView()
        root.material = .menu
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12

        field.placeholderString = "Search tabs, commands, bookmarks and history"
        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Search tabs, commands, bookmarks and history")

        let column = NSTableColumn(identifier: .init("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked(_:))
        table.action = #selector(openClicked(_:))
        table.setAccessibilityLabel("Results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let divider = NSBox()
        divider.boxType = .separator
        for view in [field, divider, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        window?.contentView = root
        window?.backgroundColor = .clear
        window?.isOpaque = false
    }

    // MARK: - Showing

    /// Over the top of `browser`'s window, with nothing typed.
    func show(over browser: BrowserWindowController) {
        self.browser = browser
        guard let panel = window, let parent = browser.window else { return }
        field.stringValue = ""
        refresh()
        let frame = parent.frame
        let width = min(620, frame.width - 40)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 110 - 400, width: width, height: 400), display: false)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    var isShown: Bool { window?.isVisible == true }

    func close(returningTo browser: BrowserWindowController?) {
        guard let panel = window else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        browser?.window?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else puts it away, as Spotlight does.
        if isShown { close(returningTo: nil) }
    }

    // MARK: - Searching

    /// Asks for everything again and ranks it for what is typed.
    func refresh() {
        let query = field.stringValue
        all = source?(query) ?? []
        hints = CommandPalette.hints(all.map(\.item))
        let byID = Dictionary(all.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = CommandPalette.rank(query, all.map(\.item)).compactMap { byID[$0.id] }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    /// Types into the box, as a person would: for the self-test.
    func type(_ text: String) {
        field.stringValue = text
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): step(1)
        case #selector(NSResponder.moveUp(_:)): step(-1)
        case #selector(NSResponder.insertNewline(_:)): open(at: max(0, table.selectedRow))
        case #selector(NSResponder.cancelOperation(_:)): close(returningTo: browser)
        default: return false
        }
        return true
    }

    private func step(_ by: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(0, table.selectedRow + by), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func openClicked(_ sender: Any?) {
        if table.clickedRow >= 0 { open(at: table.clickedRow) }
    }

    /// Runs a result, after the palette is gone and the browser window is key
    /// again, so a command acts on the tab it was asked from.
    func open(at index: Int) {
        guard results.indices.contains(index) else { return }
        let entry = results[index]
        close(returningTo: browser)
        DispatchQueue.main.async { entry.run() }
    }

    // MARK: - Rows

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = results[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: entry.icon ?? NSImage())
        let title = NSTextField(labelWithString: entry.item.title)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: Self.describe(entry.item))
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let key = NSTextField(labelWithString: keyText(for: entry, row: row))
        key.textColor = .tertiaryLabelColor
        key.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, title, detail, NSView(), key])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("\(entry.item.title), \(Self.describe(entry.item))")
        return cell
    }

    /// With nothing typed, a tab's hint; otherwise ⌘1–⌘9 for the first nine,
    /// then a command's own shortcut.
    func keyText(for entry: Entry, row: Int) -> String {
        if field.stringValue.isEmpty, let hint = hints[entry.item.id] {
            return "\(String(hint.letter).uppercased()) ⌘\(hint.number)"
        }
        if row < CommandPalette.numberedResults { return "⌘\(row + 1)" }
        return entry.shortcut
    }

    static func describe(_ item: CommandPalette.Item) -> String {
        switch item.kind {
        case .tab: return "Tab · " + CommandPalette.host(item.detail)
        case .command: return item.detail
        case .savedGroup: return "Saved group"
        case .bookmark: return "Bookmark · " + CommandPalette.host(item.detail)
        case .history: return "History · " + CommandPalette.host(item.detail)
        }
    }
}

/// A panel that takes the keyboard although it has no title bar to click,
/// and hands ⌘1–⌘9 to the palette.
final class PalettePanel: NSPanel {
    var onNumber: ((Int) -> Void)?
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
            onNumber?(digit)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Every command in the menu bar, as the palette offers them: enabled for
/// the tab they would act on, with the menu they are in.
@MainActor
enum MenuCommands {
    struct Command {
        let title: String
        let path: String
        let shortcut: String
        let menu: NSMenu
        let index: Int
    }

    /// Items that are pages rather than commands (history, bookmarks, the
    /// Window menu's list of windows) are left to the palette's own searches.
    static let skipped: Set<Selector> = [
        #selector(AppDelegate.openHistoryItem(_:)), #selector(AppDelegate.openBookmarkItem(_:)),
        #selector(NSWindow.makeKeyAndOrderFront(_:)),
    ]

    static func all(in menu: NSMenu? = NSApp.mainMenu, validatingFor browser: BrowserWindowController?) -> [Command] {
        guard let menu else { return [] }
        var commands: [Command] = []
        func walk(_ menu: NSMenu, path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for (index, item) in menu.items.enumerated() {
                if item.isSeparatorItem || item.isHidden { continue }
                if let submenu = item.submenu {
                    let title = submenu.title.isEmpty ? item.title : submenu.title
                    walk(submenu, path: title.isEmpty ? path : path + [title])
                    continue
                }
                guard let action = item.action, !skipped.contains(action), !item.title.isEmpty,
                      isEnabled(item, action: action, browser: browser) else { continue }
                // The Profiles menu lists profiles by name: offered as what choosing one does.
                let title = action == #selector(AppDelegate.openProfileWindow(_:)) ? "Switch to Profile “\(item.title)”" : item.title
                commands.append(Command(title: title, path: path.joined(separator: " › "), shortcut: shortcut(item), menu: menu, index: index))
            }
        }
        walk(menu, path: [])
        return commands
    }

    /// The object the menu bar would send the item's action to from the
    /// tab's window: the item's own target, else the first in the tab's
    /// responder chain, its window, the tab, the app, the app delegate.
    static func target(of item: NSMenuItem, action: Selector, browser: BrowserWindowController?) -> AnyObject? {
        if let target = item.target { return target.responds(to: action) ? target : nil }
        var candidates: [AnyObject] = []
        var responder = browser?.window?.firstResponder
        while let current = responder { candidates.append(current); responder = current.nextResponder }
        if let window = browser?.window { candidates.append(window) }
        if let browser { candidates.append(browser) }
        candidates.append(NSApp)
        if let delegate = NSApp.delegate { candidates.append(delegate) }
        return candidates.first { $0.responds(to: action) }
    }

    /// Whether the item would work for the tab, as its target says.
    static func isEnabled(_ item: NSMenuItem, action: Selector, browser: BrowserWindowController?) -> Bool {
        if !item.isEnabled && menuAutoenablesOff(item) { return false }
        guard let target = target(of: item, action: action, browser: browser) else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    private static func menuAutoenablesOff(_ item: NSMenuItem) -> Bool { item.menu?.autoenablesItems == false }

    /// "⇧⌘T", as the menu shows it.
    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var text = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }

    /// Runs it as the menu bar would, on the tab it was asked from, whether
    /// or not that tab's window is the key one.
    static func run(_ command: Command, for browser: BrowserWindowController?) {
        guard command.menu.items.indices.contains(command.index) else { return }
        let item = command.menu.items[command.index]
        guard let action = item.action, isEnabled(item, action: action, browser: browser),
              let target = target(of: item, action: action, browser: browser) else { return }
        NSApp.sendAction(action, to: target, from: item)
    }
}
