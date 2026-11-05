import AppKit
import DataKit
import BrowserKit

/// Bookmarks → Show Bookmarks (⌥⌘B): the whole tree, arranged by dragging.
/// Names and addresses are edited in place; a right click acts on the row
/// clicked, or on the selection when the row is part of it.
@MainActor
final class BookmarksWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate,
                                       NSTextFieldDelegate, NSMenuItemValidation {
    private let store: BookmarkStore
    private let profile: Profile
    var open: ((URL, _ newTab: Bool) -> Void)?
    var changed: (() -> Void)?

    let outline = NSOutlineView()
    let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private var deleteButton: NSButton?
    private var faviconObserver: NSObjectProtocol?
    private static let dragType = NSPasteboard.PasteboardType("dev.keel.bookmark")
    private static let nameColumn = NSUserInterfaceItemIdentifier("title")
    private static let addressColumn = NSUserInterfaceItemIdentifier("address")

    final class Item: NSObject {
        let node: BookmarkStore.Node
        var children: [Item]?
        init(_ node: BookmarkStore.Node) { self.node = node }
    }
    private(set) var roots: [Item] = []

    init(store: BookmarkStore, profile: Profile) {
        self.store = store
        self.profile = profile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        QuietMode.apply(to: window)
        window.title = "Bookmarks — \(profile.name)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 300)
        window.contentView = buildContent()
        Keel.styleListWindow(window, list: outline, scroll: scroll)
        if !window.setFrameUsingName("BookmarksWindow") { window.center() }
        window.setFrameAutosaveName("BookmarksWindow")
        reload()
        // An icon that arrives later is drawn in place, without disturbing the tree.
        faviconObserver = NotificationCenter.default.addObserver(forName: Favicons.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true, self.outline.numberOfRows > 0 else { return }
                self.outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<self.outline.numberOfRows), columnIndexes: [0])
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        MainActor.assumeIsolated { faviconObserver.map(NotificationCenter.default.removeObserver) }
    }

    private func buildContent() -> NSView {
        searchField.placeholderString = "Search Bookmarks"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        for (identifier, title, width) in [(Self.nameColumn, "Name", 320.0), (Self.addressColumn, "Address", 340.0)] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.rowHeight = 24
        outline.target = self
        outline.doubleAction = #selector(openSelected(_:))
        outline.registerForDraggedTypes([Self.dragType, .URL, .string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel("Bookmarks")
        outline.menu = contextMenu()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true

        let newFolder = Keel.listButton("New Folder", target: self, action: #selector(newFolder(_:)))
        let delete = Keel.listButton("Delete", kind: .danger, target: self, action: #selector(delete(_:)))
        delete.isEnabled = false
        deleteButton = delete
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [searchField, spacer, newFolder, delete])
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let stack = NSStackView(views: [bar, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)?] = [
            ("Open", #selector(openSelected(_:))), ("Open in New Tab", #selector(openInNewTabs(_:))), nil,
            ("Copy Address", #selector(copyAddresses(_:))), ("Rename", #selector(rename(_:))), ("Edit Address", #selector(editAddress(_:))), nil,
            ("New Folder", #selector(newFolder(_:))), nil,
            ("Delete", #selector(delete(_:))),
        ]
        for entry in items {
            guard let (title, action) = entry else { menu.addItem(.separator()); continue }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: - Data

    /// Rebuilt from the store, keeping which folders were open.
    func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let wasExpanded = Set((0..<outline.numberOfRows).compactMap { row -> Int64? in
            guard let item = outline.item(atRow: row) as? Item, outline.isItemExpanded(item) else { return nil }
            return item.node.id
        })
        if query.isEmpty {
            roots = [store.favoritesID, store.menuID].compactMap { try? store.node($0) }.map(Item.init)
        } else {
            roots = ((try? store.search(query)) ?? []).map { let item = Item($0); item.children = []; return item }
        }
        outline.reloadData()
        guard query.isEmpty else { return }
        // The two roots always open; folders under them as they were.
        func expand(_ items: [Item]) {
            for item in items where item.node.kind == .folder && (item.node.parent == nil || wasExpanded.contains(item.node.id)) {
                outline.expandItem(item)
                expand(children(of: item))
            }
        }
        expand(roots)
    }

    private func children(of item: Item) -> [Item] {
        if let children = item.children { return children }
        let children = ((try? store.children(of: item.node.id)) ?? []).map(Item.init)
        item.children = children
        return children
    }

    /// The row showing a node, opening the folders above it.
    private func reveal(_ id: Int64) -> Int? {
        var path: [Int64] = []
        var cursor = try? store.node(id)
        while let node = cursor {
            path.insert(node.id, at: 0)
            cursor = node.parent.flatMap { try? store.node($0) }
        }
        var level = roots
        var found: Item?
        for step in path {
            guard let item = level.first(where: { $0.node.id == step }) else { return nil }
            found = item
            if step != id { outline.expandItem(item); level = children(of: item) }
        }
        let row = found.map { outline.row(forItem: $0) } ?? -1
        return row >= 0 ? row : nil
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField { reload() }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return roots.count }
        return item.node.kind == .folder ? children(of: item).count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return roots[index] }
        return children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item, item.node.kind == .folder else { return false }
        return !children(of: item).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { Keel.listRowView() }

    /// Delete is for something chosen that can go: not nothing, not Favorites itself.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        deleteButton?.isEnabled = targets(nil).contains { $0.parent != nil }
    }

    /// A real cell view, so `editColumn` finds the field to edit, and both
    /// columns centre their text on the row alike.
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = (item as? Item)?.node else { return nil }
        let isAddress = tableColumn?.identifier == Self.addressColumn
        let identifier = isAddress ? Self.addressColumn : Self.nameColumn
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier, withIcon: !isAddress)
        guard let field = cell.textField else { return cell }
        field.tag = Int(node.id)
        if isAddress {
            field.stringValue = node.url?.absoluteString ?? ""
            field.isEditable = node.kind == .bookmark
        } else {
            field.stringValue = node.title
            field.isEditable = node.parent != nil
            field.font = node.parent == nil ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            cell.imageView?.image = node.kind == .folder ? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                : Favicons.shared.icon(for: node.url, title: node.title)
        }
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.identifier = identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if identifier == Self.addressColumn { field.textColor = .secondaryLabelColor }
        cell.addSubview(field)
        cell.textField = field
        var constraints = [
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        ]
        if withIcon {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentTintColor = .secondaryLabelColor
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            cell.imageView = icon
            constraints += [
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// Editing in place, committed when it ends. An address that is not one
    /// is refused and the old one comes back.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== searchField, field.tag != 0, let node = try? store.node(Int64(field.tag)) else { return }
        if field.identifier == Self.addressColumn {
            guard let url = AddressResolver.address(field.stringValue) else {
                NSSound.beep()
                field.stringValue = node.url?.absoluteString ?? ""
                return
            }
            guard url != node.url else { return }
            try? store.setURL(node.id, to: url)
        } else {
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != node.title else {
                field.stringValue = node.title
                return
            }
            try? store.rename(node.id, to: title)
        }
        changed?()
    }

    /// The nodes a command acts on: see `rowsActedOn(by:)`.
    private func targets(_ sender: Any?) -> [BookmarkStore.Node] {
        outline.rowsActedOn(by: sender).compactMap { (outline.item(atRow: $0) as? Item)?.node }
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = (item as? Item)?.node, node.parent != nil else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(node.id), forType: Self.dragType)
        if let url = node.url { pasteboardItem.setString(url.absoluteString, forType: .URL) }
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = item as? Item, target.node.kind == .folder else { return [] }
        return info.draggingPasteboard.string(forType: Self.dragType) != nil ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = (item as? Item)?.node else { return false }
        let at = index == NSOutlineViewDropOnItemIndex ? nil : index
        if let id = info.draggingPasteboard.string(forType: Self.dragType).flatMap(Int64.init) {
            guard (try? store.move(id, to: folder.id, at: at)) != nil else { return false }
        } else if let text = info.draggingPasteboard.string(forType: .URL) ?? info.draggingPasteboard.string(forType: .string),
                  let url = URL(string: text), url.scheme != nil {
            _ = try? store.addBookmark(url: url, title: url.host() ?? text, in: folder.id, at: at)
        } else {
            return false
        }
        changed?()
        reload()
        return true
    }

    // MARK: - Actions

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let nodes = targets(menuItem)
        switch menuItem.action {
        case #selector(openSelected(_:)), #selector(openInNewTabs(_:)), #selector(copyAddresses(_:)):
            return nodes.contains { $0.url != nil }
        case #selector(rename(_:)):
            return nodes.count == 1 && nodes[0].parent != nil
        case #selector(editAddress(_:)):
            return nodes.count == 1 && nodes[0].kind == .bookmark
        case #selector(delete(_:)):
            return nodes.contains { $0.parent != nil }
        default:
            return true
        }
    }

    /// Double-click or Open: a folder opens or closes, bookmarks open, several in new tabs.
    @objc func openSelected(_ sender: Any?) {
        let nodes = targets(sender)
        if nodes.count == 1, nodes[0].kind == .folder, sender as? NSOutlineView === outline {
            let item = outline.item(atRow: outline.clickedRow)
            if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
            return
        }
        let urls = nodes.compactMap(\.url)
        for url in urls { open?(url, urls.count > 1 || NSEvent.modifierFlags.contains(.command)) }
    }

    @objc func openInNewTabs(_ sender: Any?) {
        for url in targets(sender).compactMap(\.url) { open?(url, true) }
    }

    @objc func copyAddresses(_ sender: Any?) {
        BookmarkMenus.copy(targets(sender).compactMap(\.url))
    }

    @objc func rename(_ sender: Any?) {
        guard let node = targets(sender).first else { return }
        edit(node, column: 0)
    }

    @objc func editAddress(_ sender: Any?) {
        guard let node = targets(sender).first, node.kind == .bookmark else { return }
        edit(node, column: 1)
    }

    private func edit(_ node: BookmarkStore.Node, column: Int) {
        guard let row = reveal(node.id) else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        outline.editColumn(column, row: row, with: nil, select: true)
    }

    /// In the folder chosen, or beside the bookmark chosen; then its name is ready to type.
    @objc func newFolder(_ sender: Any?) {
        let parent = targets(sender).first.map { $0.kind == .folder ? $0.id : ($0.parent ?? store.menuID) } ?? store.menuID
        guard let id = try? store.addFolder("New Folder", in: parent) else { return }
        changed?()
        searchField.stringValue = ""
        reload()
        if let node = try? store.node(id) { edit(node, column: 0) }
    }

    @objc func delete(_ sender: Any?) {
        BookmarkMenus.delete(targets(sender), store: store, window: window) { [weak self] in
            self?.changed?()
            self?.reload()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { delete(nil) } else { super.keyDown(with: event) }
    }
}
