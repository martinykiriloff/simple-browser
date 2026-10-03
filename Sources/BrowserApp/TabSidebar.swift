import AppKit
import BrowserKit
import DataKit

/// The sidebar (⇧⌘S): pinned tabs as icons at the top, then the window's
/// tabs down the side with their groups, which collapse, then saved groups,
/// favorites and the reading list. Every tab of a window has one, showing
/// the same thing; they reload together when the organizer says so.
@MainActor
final class TabSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    enum Row: Equatable {
        case header(String)
        case group(TabGroupID)
        case tab(TabID, inGroup: Bool)
        case newTab
        case saved(TabGroupID)
        case bookmark(Int64)
        case reading(Int64)
    }

    weak var browser: BrowserWindowController?
    let organizer: TabOrganizer
    var bookmarks: () -> BookmarkStore? = { nil }
    /// Opens a page: in this tab, or a new one.
    var open: ((URL, Bool) -> Void)?
    var newTab: (() -> Void)?
    var editGroup: ((TabGroupID, NSView) -> Void)?

    let table = NSTableView()
    private let scroll = NSScrollView()
    let pinnedStrip = PinnedTabsView()
    private(set) var rows: [Row] = []
    private var favorites: [BookmarkStore.Node] = []
    private var readingList: [BookmarkStore.ReadingItem] = []
    private var saved: [SavedTabGroup] = []
    private var observers: [NSObjectProtocol] = []

    init(organizer: TabOrganizer) {
        self.organizer = organizer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        MainActor.assumeIsolated { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        root.setAccessibilityLabel("Sidebar")

        let column = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.registerForDraggedTypes([.sidebarTab])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Tabs")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        pinnedStrip.translatesAutoresizingMaskIntoConstraints = false
        pinnedStrip.onSelect = { [weak self] id in self?.select(id) }
        pinnedStrip.menuFor = { [weak self] id in self?.pinnedMenu(for: id) }

        root.addSubview(pinnedStrip)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            pinnedStrip.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            pinnedStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            pinnedStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: pinnedStrip.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        for name in [TabOrganizer.didChange, Favicons.didLoad] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    // MARK: - Contents

    private var tabs: [BrowserWindowController] { browser.map(organizer.tabs(besides:)) ?? [] }
    private func tab(_ id: TabID) -> BrowserWindowController? { tabs.first { $0.tab == id } }

    private var stale = false

    /// Only the sidebar on screen is filled; the others, in tabs behind, are
    /// marked and filled when their tab is shown.
    func reload() {
        guard isViewLoaded, let browser else { return }
        guard view.window?.isVisible == true else {
            stale = true
            return
        }
        stale = false
        let tabs = self.tabs
        let (pinned, tabRows) = TabArrangement.sidebar(organizer.entries(tabs), groups: organizer.groups, selected: browser.tab)
        pinnedStrip.show(pinned.compactMap { id in tabs.first { $0.tab == id } }, selected: browser.tab)

        favorites = (bookmarks()?.favorites ?? []).filter { $0.url != nil }
        readingList = ((try? bookmarks()?.readingList(includeRead: false)) ?? []) ?? []
        let open = Set(organizer.groups.keys)
        saved = browser.isPrivate ? [] : organizer.savedGroups(profile: browser.profile).filter { !open.contains($0.id) }

        var rows = tabRows.map { row -> Row in
            switch row {
            case .group(let id): return .group(id)
            case .tab(let id, let inGroup): return .tab(id, inGroup: inGroup)
            }
        }
        rows.append(.newTab)
        if !saved.isEmpty { rows += [.header("Saved Groups")] + saved.map { .saved($0.id) } }
        if !favorites.isEmpty { rows += [.header("Favorites")] + favorites.map { .bookmark($0.id) } }
        if !readingList.isEmpty { rows += [.header("Reading List")] + readingList.map { .reading($0.id) } }

        let keepSelection = table.selectedRowIndexes.count > 1 && rows == self.rows
        self.rows = rows
        let selected = table.selectedRowIndexes
        table.reloadData()
        if keepSelection {
            table.selectRowIndexes(selected, byExtendingSelection: false)
        } else if let index = rows.firstIndex(where: { if case .tab(browser.tab, _) = $0 { return true } else { return false } })
                    ?? rows.firstIndex(of: .group(browser.groupID ?? TabGroupID())) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    func reloadIfStale() {
        if stale { reload() }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 24 }
        return 28
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .tab, .group: return true
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SidebarCell()
        switch rows[row] {
        case .header(let title):
            cell.configure(icon: nil, title: title.uppercased(), header: true)
        case .group(let id):
            guard let group = organizer.groups[id] else { break }
            let members = tabs.filter { $0.groupID == id }
            cell.configure(icon: Self.dot(group.color), title: group.displayName(firstTab: members.first?.window?.title),
                           detail: "\(members.count)", disclosure: group.isCollapsed ? .collapsed : .expanded)
            cell.onDisclosure = { [weak self] in self?.organizer.setCollapsed(id, !group.isCollapsed) }
            cell.setAccessibilityLabel("Group \(cell.title), \(members.count) tabs, \(group.isCollapsed ? "collapsed" : "expanded")")
        case .tab(let id, let inGroup):
            guard let tab = tab(id) else { break }
            // A split shows as the pair, as in the tab bar.
            let title = (tab.split != nil ? tab.window?.tab.title : nil) ?? tab.window?.title ?? ""
            cell.configure(icon: Favicons.shared.icon(for: tab.currentURL, title: title), title: title.isEmpty ? "New Tab" : title,
                           indent: inGroup ? 16 : 0, dimmed: tab.isHibernated)
            cell.onClose = { [weak tab] in tab?.window?.performClose(nil) }
            cell.setAccessibilityLabel(title)
            cell.toolTip = tab.currentURL?.absoluteString
        case .newTab:
            cell.configure(icon: NSImage(systemSymbolName: "plus", accessibilityDescription: nil), title: "New Tab", dimmed: true)
        case .saved(let id):
            guard let group = saved.first(where: { $0.id == id }) else { break }
            cell.configure(icon: Self.dot(group.color, hollow: true), title: group.name.isEmpty ? (group.pages.first?.title ?? "Group") : group.name,
                           detail: "\(group.pages.count)")
            cell.toolTip = group.pages.map(\.title).joined(separator: "\n")
        case .bookmark(let id):
            guard let node = favorites.first(where: { $0.id == id }) else { break }
            cell.configure(icon: Favicons.shared.icon(for: node.url, title: node.title), title: node.title)
            cell.toolTip = node.url?.absoluteString
        case .reading(let id):
            guard let item = readingList.first(where: { $0.id == id }) else { break }
            cell.configure(icon: NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil), title: item.title.isEmpty ? item.url.absoluteString : item.title)
            cell.toolTip = item.url.absoluteString
        }
        return cell
    }

    static func dot(_ color: GroupColor, hollow: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            color.nsColor.set()
            if hollow { circle.lineWidth = 1.5; circle.stroke() } else { circle.fill() }
            return true
        }
    }

    // MARK: - Clicks

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        // ⌘- and ⇧-clicks choose several tabs, for a group.
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]) ?? []
        guard modifiers.isEmpty else { return }
        activate(row)
    }

    /// What a click, or Return, does to a row.
    func activate(_ row: Int) {
        switch rows[row] {
        case .tab(let id, _): select(id)
        case .group(let id):
            if let group = organizer.groups[id] { organizer.setCollapsed(id, !group.isCollapsed) }
        case .newTab: newTab?()
        case .saved(let id):
            if let group = saved.first(where: { $0.id == id }), let browser { organizer.openSaved(group, besides: browser) }
        case .bookmark(let id):
            if let url = favorites.first(where: { $0.id == id })?.url { open?(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
        case .reading(let id):
            if let url = readingList.first(where: { $0.id == id })?.url { open?(url, false) }
        case .header: break
        }
    }

    private func select(_ id: TabID) {
        tab(id)?.show()
    }

    // MARK: - Menus

    /// The tabs a menu acts on: those chosen, if the clicked one is among them.
    private func tabsForMenu(clicked row: Int) -> [BrowserWindowController] {
        let chosen = table.selectedRowIndexes.contains(row) ? Array(table.selectedRowIndexes) : [row]
        return chosen.compactMap { index in
            guard rows.indices.contains(index), case .tab(let id, _) = rows[index] else { return nil }
            return tab(id)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .tab:
            let chosen = tabsForMenu(clicked: row)
            TabMenus.fill(menu, for: chosen, organizer: organizer, front: browser, edit: { [weak self] id in self?.edit(id) })
        case .group(let id):
            TabMenus.fill(menu, forGroup: id, organizer: organizer, profile: browser?.isPrivate == false ? browser?.profile : nil,
                          edit: { [weak self] id in self?.edit(id) })
        case .saved(let id):
            guard let group = saved.first(where: { $0.id == id }), let browser else { return }
            menu.addItem(ClosureMenuItem("Open Group") { [weak self] in self?.organizer.openSaved(group, besides: browser) })
            menu.addItem(ClosureMenuItem("Delete Saved Group") { [weak self] in self?.organizer.forgetSaved(id, profile: browser.profile) })
        case .bookmark(let id):
            guard let url = favorites.first(where: { $0.id == id })?.url else { return }
            menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.open?(url, false) })
            menu.addItem(ClosureMenuItem("Open in New Tab") { [weak self] in self?.open?(url, true) })
        case .reading(let id):
            guard let url = readingList.first(where: { $0.id == id })?.url else { return }
            menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.open?(url, false) })
            menu.addItem(ClosureMenuItem("Open in New Tab") { [weak self] in self?.open?(url, true) })
        case .header, .newTab: break
        }
    }

    private func pinnedMenu(for id: TabID) -> NSMenu? {
        guard let tab = tab(id) else { return nil }
        let menu = NSMenu()
        TabMenus.fill(menu, for: [tab], organizer: organizer, front: browser, edit: { [weak self] id in self?.edit(id) })
        return menu
    }

    private func edit(_ group: TabGroupID) {
        let anchor: NSView
        if let index = rows.firstIndex(of: .group(group)), let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) {
            anchor = cell
        } else {
            anchor = table
        }
        editGroup?(group, anchor)
    }

    // MARK: - Dragging tabs

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .tab(let id, _) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(id.description, forType: .sidebarTab)
        return item
    }

    /// A tab dragged out of the list can be dropped on the page's right edge, for split view.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        browser?.showSplitDropZone(true)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        browser?.showSplitDropZone(false)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard draggedTab(info) != nil else { return [] }
        if operation == .on {
            if rows.indices.contains(row), case .group = rows[row] { return .move }
            return []
        }
        // Between tabs, or just after the last one.
        let lastTab = rows.lastIndex { if case .tab = $0 { return true } else { return false } } ?? -1
        return row <= lastTab + 1 ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let dragged = draggedTab(info) else { return false }
        if dropOperation == .on, case .group(let id) = rows[row] {
            organizer.add([dragged], to: id)
            return true
        }
        // Dropped above a tab: before it, in its group. Above a group's
        // name: before the group, in none.
        var before: BrowserWindowController?
        var group: TabGroupID?
        if rows.indices.contains(row) {
            switch rows[row] {
            case .tab(let id, let inGroup):
                before = tab(id)
                group = inGroup ? before?.groupID : nil
            case .group(let id):
                before = tabs.first { $0.groupID == id }
            default: break
            }
        }
        if before == nil, row > 0, case .tab(let id, true) = rows[row - 1] { group = tab(id)?.groupID }
        organizer.move(dragged, before: before === dragged ? nil : before, group: group)
        return true
    }

    private func draggedTab(_ info: any NSDraggingInfo) -> BrowserWindowController? {
        guard let text = info.draggingPasteboard.string(forType: .sidebarTab) else { return nil }
        return tabs.first { $0.tab.description == text }
    }
}

extension NSPasteboard.PasteboardType {
    static let sidebarTab = NSPasteboard.PasteboardType("com.keel.sidebar-tab")
}

/// A chosen row: a rounded fill in the system's selection colour, and the
/// row's text in the colour that goes on it.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected && isEmphasized ? .emphasized : .normal }
}

/// A sidebar row: an icon, a title, and a close button that shows on hover.
@MainActor
final class SidebarCell: NSTableCellView {
    enum Disclosure { case none, collapsed, expanded }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let disclosureButton = NSButton()
    private var leading: NSLayoutConstraint?
    var onClose: (() -> Void)?
    var onDisclosure: (() -> Void)?
    var title: String { label.stringValue }
    private var isHeader = false
    private var dimmed = false

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.isHidden = true
        closeButton.setAccessibilityLabel("Close Tab")
        disclosureButton.isBordered = false
        disclosureButton.target = self
        disclosureButton.action = #selector(toggle(_:))
        disclosureButton.isHidden = true
        for view in [disclosureButton, icon, label, detailLabel, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = label
        let leading = disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 12),
            icon.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: detailLabel.trailingAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(icon image: NSImage?, title: String, detail: String = "", indent: CGFloat = 0, dimmed: Bool = false,
                   header: Bool = false, disclosure: Disclosure = .none) {
        icon.image = image
        icon.isHidden = image == nil
        label.stringValue = title
        label.font = header ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = header ? .secondaryLabelColor : dimmed ? .secondaryLabelColor : .labelColor
        isHeader = header
        self.dimmed = dimmed
        detailLabel.stringValue = detail
        leading?.constant = 4 + indent
        disclosureButton.isHidden = disclosure == .none
        disclosureButton.image = NSImage(systemSymbolName: disclosure == .collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        disclosureButton.setAccessibilityLabel(disclosure == .collapsed ? "Expand" : "Collapse")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard !isHeader else { return }
            label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : dimmed ? .secondaryLabelColor : .labelColor
            closeButton.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : nil
        }
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = onClose == nil }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
    @objc private func close(_ sender: Any?) { onClose?() }
    @objc private func toggle(_ sender: Any?) { onDisclosure?() }
}

/// Pinned tabs, as a row of icons that wraps.
@MainActor
final class PinnedTabsView: NSView {
    var onSelect: ((TabID) -> Void)?
    var menuFor: ((TabID) -> NSMenu?)?
    private(set) var buttons: [NSButton] = []
    private var ids: [TabID] = []
    private var height: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    func show(_ tabs: [BrowserWindowController], selected: TabID) {
        buttons.forEach { $0.removeFromSuperview() }
        ids = tabs.map(\.tab)
        buttons = tabs.map { tab in
            let title = tab.window?.title ?? ""
            let button = NSButton(image: Favicons.shared.icon(for: tab.currentURL, title: title), target: self, action: #selector(pick(_:)))
            button.bezelStyle = .smallSquare
            button.setButtonType(.pushOnPushOff)
            button.state = tab.tab == selected ? .on : .off
            button.toolTip = title
            button.setAccessibilityLabel("Pinned tab: \(title)")
            addSubview(button)
            return button
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: 40, height: 32), gap: CGFloat = 6
        let perRow = max(1, Int((bounds.width + gap) / (size.width + gap)))
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index % perRow) * (size.width + gap), y: CGFloat(index / perRow) * (size.height + gap),
                                  width: size.width, height: size.height)
        }
        let rowCount = buttons.isEmpty ? 0 : (buttons.count + perRow - 1) / perRow
        let wanted = rowCount == 0 ? 0 : CGFloat(rowCount) * (size.height + gap) - gap
        if height == nil {
            height = heightAnchor.constraint(equalToConstant: wanted)
            height?.isActive = true
        } else if height?.constant != wanted {
            height?.constant = wanted
        }
    }

    @objc private func pick(_ sender: NSButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        onSelect?(ids[index])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = buttons.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
        return menuFor?(ids[index])
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, state: NSControl.StateValue = .off, image: NSImage? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
        self.state = state
        self.image = image
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }
    @objc private func fire(_ sender: Any?) { run() }
}

/// The menus for tabs and groups, shared by the sidebar, the pinned icons
/// and the Window menu.
@MainActor
enum TabMenus {
    static func fill(_ menu: NSMenu, for tabs: [BrowserWindowController], organizer: TabOrganizer, front: BrowserWindowController? = nil,
                     edit: @escaping (TabGroupID) -> Void) {
        guard let first = tabs.first else { return }
        let count = tabs.count
        let plural = count == 1 ? "Tab" : "\(count) Tabs"
        // Beside the tab in front: the one clicked, or the two chosen.
        let pair: (BrowserWindowController, BrowserWindowController)? = count == 2 ? (tabs[0], tabs[1])
            : count == 1 ? front.flatMap { $0 === first ? nil : ($0, first) } : nil
        if let (left, right) = pair, !left.isInSplit, !right.isInSplit {
            menu.addItem(ClosureMenuItem("Open in Split View") { left.openInSplitView(with: right) })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("New Tab Group from \(plural)") {
            if let id = organizer.newGroup(with: tabs) { edit(id) }
        })
        let groups = organizer.groups(besides: first)
        if !groups.isEmpty {
            let submenu = NSMenu()
            for group in groups {
                let name = group.displayName(firstTab: organizer.tabs(in: group.id).first?.window?.title)
                submenu.addItem(ClosureMenuItem(name, state: tabs.allSatisfy { $0.groupID == group.id } ? .on : .off,
                                                image: TabSidebarController.dot(group.color)) { organizer.add(tabs, to: group.id) })
            }
            let item = NSMenuItem(title: "Move \(plural) to Group", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if tabs.contains(where: { $0.groupID != nil }) {
            menu.addItem(ClosureMenuItem("Remove \(plural) from Group") { organizer.removeFromGroup(tabs) })
        }
        menu.addItem(.separator())
        let pinned = tabs.allSatisfy(\.isPinned)
        menu.addItem(ClosureMenuItem(pinned ? "Unpin \(plural)" : "Pin \(plural)") { organizer.setPinned(tabs, !pinned) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(count == 1 ? "Close Tab" : "Close \(count) Tabs") {
            for tab in tabs { tab.window?.performClose(nil) }
        })
    }

    static func fill(_ menu: NSMenu, forGroup id: TabGroupID, organizer: TabOrganizer, profile: Profile?, edit: @escaping (TabGroupID) -> Void) {
        guard let group = organizer.groups[id] else { return }
        menu.addItem(ClosureMenuItem("Edit Group…") { edit(id) })
        let colors = NSMenu()
        for color in GroupColor.allCases {
            colors.addItem(ClosureMenuItem(color.title, state: group.color == color ? .on : .off,
                                           image: TabSidebarController.dot(color)) { organizer.setColor(id, color) })
        }
        let colorItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(ClosureMenuItem(group.isCollapsed ? "Expand Group" : "Collapse Group") { organizer.setCollapsed(id, !group.isCollapsed) })
        menu.addItem(ClosureMenuItem("New Tab in Group") {
            guard let last = organizer.tabs(in: id).last, let tab = organizer.openTabs?(last, []).first else { return }
            organizer.add([tab], to: id)
        })
        if let profile {
            let saved = organizer.isSaved(id, profile: profile)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(saved ? "Don’t Keep Group" : "Save Group", state: saved ? .on : .off) {
                if saved { organizer.forgetSaved(id, profile: profile) } else { organizer.save(id, profile: profile) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Ungroup") { organizer.ungroup(id) })
        menu.addItem(ClosureMenuItem("Close Group") { organizer.closeGroup(id) })
    }
}

/// Names a group and picks its colour: shown when a group is made, and by Edit Group….
@MainActor
final class GroupEditorController: NSViewController, NSTextFieldDelegate {
    let organizer: TabOrganizer
    let group: TabGroupID
    let nameField = NSTextField()
    private(set) var swatches: [NSButton] = []

    init(organizer: TabOrganizer, group: TabGroupID) {
        self.organizer = organizer
        self.group = group
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let current = organizer.groups[group]
        nameField.stringValue = current?.name ?? ""
        nameField.placeholderString = "Name this group"
        nameField.delegate = self
        nameField.setAccessibilityLabel("Group name")
        swatches = GroupColor.allCases.map { color in
            let button = NSButton(image: TabSidebarController.dot(color), target: self, action: #selector(pick(_:)))
            button.bezelStyle = .smallSquare
            button.setButtonType(.pushOnPushOff)
            button.state = current?.color == color ? .on : .off
            button.setAccessibilityLabel(color.title)
            button.toolTip = color.title
            return button
        }
        let colors = NSStackView(views: swatches)
        colors.spacing = 2
        let stack = NSStackView(views: [nameField, colors])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        nameField.widthAnchor.constraint(equalTo: colors.widthAnchor).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    func controlTextDidChange(_ notification: Notification) {
        organizer.rename(group, to: nameField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        view.window?.performClose(nil)
        return true
    }

    @objc private func pick(_ sender: NSButton) {
        guard let index = swatches.firstIndex(of: sender) else { return }
        for button in swatches { button.state = button === sender ? .on : .off }
        organizer.setColor(group, GroupColor.allCases[index])
    }
}
