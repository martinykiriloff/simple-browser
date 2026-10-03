import AppKit
import BrowserKit

/// ⌘K: one box for open tabs, every menu command, saved groups, bookmarks
/// and history, searched fuzzily and worked entirely from the keyboard.
/// ↑ ↓ move, Return opens, ⌘1–⌘9 open the first nine results, ⇥ narrows
/// to one group, Esc closes. With nothing typed each tab shows a hint: its
/// letter, then ⌘ and its number, opens it.
///
/// Drawn as Design D's palette (G1-02): a flat #171B22 panel, results in
/// groups (Tabs, Actions, Agents, …) under small uppercase labels.
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

    /// The palette's sections, in the order they are offered.
    enum Group: Int, CaseIterable {
        case tabs, actions, agents, savedGroups, bookmarks, history

        var title: String {
            switch self {
            case .tabs: return "Tabs"
            case .actions: return "Actions"
            case .agents: return "Agents"
            case .savedGroups: return "Saved groups"
            case .bookmarks: return "Bookmarks"
            case .history: return "History"
            }
        }
    }

    /// The agent session a tab belongs to, by its palette id ("tab:…").
    /// Set by the app (`configureRestyle`).
    static var agentTabID: ((String) -> String?)?
    /// How many agent sessions are running, for "Pause all agents".
    static var runningAgents: (() -> Int)?

    /// Everything that can be offered for a query. Tabs and commands do not
    /// depend on it; bookmarks and history are searched with it.
    var source: ((String) -> [Entry])?
    weak var browser: BrowserWindowController?

    let field = NSTextField()
    let table = NSTableView()
    let countLabel = NSTextField(labelWithString: "")
    private(set) var results: [Entry] = []
    private(set) var hints: [String: CommandPalette.Hint] = [:]
    private var all: [Entry] = []
    /// ⇥: only this group's results.
    private(set) var filter: Group?
    /// What the table shows: a group's label, or a result by its index.
    private enum Row { case header(Group), entry(Int) }
    private var rows: [Row] = []
    private(set) var selectedIndex = 0

    static let width: CGFloat = 680
    static let height: CGFloat = 460

    init() {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                                 styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.appearance = Keel.darkAppearance
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
        let root = KeelFill(fill: Keel.raised, border: Keel.menuBorder, radius: 14)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true

        // Header: ⌘K · the box · esc.
        let placeholder = "Search tabs, actions, agents…"
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: Keel.dim, .font: Keel.font(15)])
        field.font = Keel.font(15)
        field.textColor = Keel.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Search tabs, commands, agents, bookmarks and history")
        let header = NSStackView(views: [KeelKbd("⌘K"), field, KeelKbd("esc")])
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: .init("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
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
        scroll.scrollerStyle = .overlay

        // Footer: how to drive it, and how much it found.
        let footer = KeelFill(fill: Keel.surface)
        func hint(_ key: String, _ text: String) -> NSStackView {
            let stack = NSStackView(views: [KeelKbd(key), Keel.label(text, size: 12, color: Keel.dim)])
            stack.spacing = 6
            return stack
        }
        countLabel.font = Keel.font(12)
        countLabel.textColor = Keel.dim
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footerStack = NSStackView(views: [hint("↑↓", "navigate"), hint("↵", "run"), hint("⇥", "filter group"), spacer, countLabel])
        footerStack.spacing = 16
        footerStack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerStack)

        let topLine = KeelFill(fill: Keel.hairline)
        let bottomLine = KeelFill(fill: Keel.hairline)
        for view in [header, topLine, scroll, bottomLine, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            topLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -8),
            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),
            bottomLine.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 1),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -1),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -1),
            footer.heightAnchor.constraint(equalToConstant: 35),
            footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerStack.topAnchor.constraint(equalTo: footer.topAnchor),
            footerStack.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
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
        filter = nil
        refresh()
        let frame = parent.frame
        let width = min(Self.width, frame.width - 40)
        let height = min(Self.height, max(240, frame.height - 140))
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 110 - height, width: width, height: height), display: false)
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

    static func group(of item: CommandPalette.Item) -> Group {
        switch item.kind {
        case .tab: return .tabs
        case .command: return item.detail == "Agent" || item.detail.hasPrefix("Agent ›") ? .agents : .actions
        case .savedGroup: return .savedGroups
        case .bookmark: return .bookmarks
        case .history: return .history
        }
    }

    /// Asks for everything again and ranks it for what is typed.
    func refresh() {
        let query = field.stringValue
        all = source?(query) ?? []
        hints = CommandPalette.hints(all.map(\.item))
        let byID = Dictionary(all.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var ranked: [Entry]
        if let filter, trimmed.isEmpty {
            // A group on its own, with nothing typed: all of it.
            ranked = all.filter { Self.group(of: $0.item) == filter }
        } else {
            ranked = CommandPalette.rank(query, all.map(\.item)).compactMap { byID[$0.id] }
            if let filter { ranked = ranked.filter { Self.group(of: $0.item) == filter } }
        }
        // In groups, the group of the best match first. A single letter
        // keeps the ranking's own order: it puts each tab at its hint's number.
        if trimmed.count != 1 {
            var order: [Group] = []
            for entry in ranked where !order.contains(Self.group(of: entry.item)) { order.append(Self.group(of: entry.item)) }
            ranked = order.flatMap { group in ranked.filter { Self.group(of: $0.item) == group } }
        }
        results = ranked
        rows = []
        var last: Group?
        for (index, entry) in results.enumerated() {
            let group = Self.group(of: entry.item)
            if group != last { rows.append(.header(group)); last = group }
            rows.append(.entry(index))
        }
        countLabel.stringValue = (filter.map { "\($0.title) · " } ?? "") + "\(results.count) of \(all.count) results"
        table.reloadData()
        select(results.isEmpty ? nil : 0)
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
        case #selector(NSResponder.insertNewline(_:)): open(at: selectedIndex)
        case #selector(NSResponder.cancelOperation(_:)):
            if filter != nil { filter = nil; refresh() } else { close(returningTo: browser) }
        case #selector(NSResponder.insertTab(_:)): cycleFilter(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): cycleFilter(by: -1)
        default: return false
        }
        return true
    }

    /// ⇥: the next group that has anything for what is typed; past the last, all of them.
    func cycleFilter(by step: Int) {
        let saved = filter
        filter = nil
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let candidates: [Entry] = query.isEmpty ? all : {
            let byID = Dictionary(all.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
            return CommandPalette.rank(query, all.map(\.item)).compactMap { byID[$0.id] }
        }()
        let present = Group.allCases.filter { group in candidates.contains { Self.group(of: $0.item) == group } }
        let cycle: [Group?] = [nil] + present
        let current = cycle.firstIndex { $0 == saved } ?? 0
        filter = cycle[(current + step + cycle.count) % cycle.count]
        refresh()
    }

    private func step(_ by: Int) {
        guard !results.isEmpty else { return }
        select(min(max(0, selectedIndex + by), results.count - 1))
    }

    private func select(_ index: Int?) {
        guard let index, let row = rows.firstIndex(where: { if case .entry(index) = $0 { return true } else { return false } }) else {
            selectedIndex = 0
            table.deselectAll(nil)
            return
        }
        selectedIndex = index
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        // The group's label scrolls into view with its first result.
        if row > 0, case .header = rows[row - 1] { table.scrollRowToVisible(row - 1) }
    }

    @objc private func openClicked(_ sender: Any?) {
        guard rows.indices.contains(table.clickedRow), case .entry(let index) = rows[table.clickedRow] else { return }
        open(at: index)
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

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row), case .header = rows[row] else { return 34 }
        return 30
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row), case .entry(let index) = rows[row] else { return false }
        selectedIndex = index
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = KeelRowView()
        view.inset = 8
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let group):
            let cell = NSTableCellView()
            let label = Keel.sectionLabel(group.title)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5),
            ])
            cell.setAccessibilityRole(.staticText)
            cell.setAccessibilityLabel(group.title)
            return cell
        case .entry(let index):
            return entryView(results[index], index: index)
        }
    }

    private func entryView(_ entry: Entry, index: Int) -> NSView {
        let cell = NSTableCellView()
        let group = Self.group(of: entry.item)
        let agent = entry.item.kind == .tab ? Self.agentTabID?(entry.item.id) : nil
        let color: NSColor
        switch group {
        case .tabs: color = agent != nil ? Keel.amber : Keel.idle
        case .agents: color = Keel.amber
        case .actions: color = Keel.muted
        case .savedGroups: color = Keel.dim
        case .bookmarks, .history: color = Keel.idle
        }
        let square = Keel.square(color)
        let title = Keel.label(entry.item.title, size: 13, color: Keel.text)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let detail = Keel.monoLabel(secondary(entry, agent: agent), color: Keel.dim)
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        let keys = NSStackView(views: chips(for: keyText(for: entry, row: index), shortcut: entry.shortcut))
        keys.spacing = 4
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [square, title, spacer, detail, keys])
        stack.spacing = 10
        stack.setCustomSpacing(12, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("\(entry.item.title), \(Self.describe(entry.item))" + (agent.map { ", agent \($0)" } ?? ""))
        return cell
    }

    /// The grey words after a title: a tab's address, "agent a91f", a
    /// command's menu, "2 running".
    private func secondary(_ entry: Entry, agent: String?) -> String {
        if let agent { return "agent \(agent)" }
        switch entry.item.kind {
        case .tab, .bookmark, .history:
            return CommandPalette.host(entry.item.detail)
        case .savedGroup: return "Saved group"
        case .command:
            if Self.group(of: entry.item) == .agents {
                let running = Self.runningAgents?() ?? 0
                if entry.item.title.hasSuffix("All Agents") && entry.item.title.hasPrefix("Pause") { return "\(running) running" }
                return ""
            }
            return entry.item.detail
        }
    }

    /// "G ⌘3" as two chips; a command's "⇧⌘C" as three.
    private func chips(for text: String, shortcut: String) -> [KeelKbd] {
        guard !text.isEmpty else { return [] }
        if text == shortcut { return KeelKbd.keys(text) }
        return text.split(separator: " ").map { KeelKbd(String($0)) }
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
