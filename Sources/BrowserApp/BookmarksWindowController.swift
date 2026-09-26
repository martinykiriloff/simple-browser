import AppKit
import DataKit
import BrowserKit

/// Bookmarks → Show Bookmarks (⌥⌘B): the whole tree, arranged by dragging.
@MainActor
final class BookmarksWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    private let store: BookmarkStore
    private let profile: Profile
    var open: ((URL, _ newTab: Bool) -> Void)?
    var changed: (() -> Void)?

    let outline = NSOutlineView()
    let searchField = NSSearchField()
    private static let dragType = NSPasteboard.PasteboardType("dev.simplebrowser.bookmark")

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
        window.title = "Bookmarks — \(profile.name)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 300)
        window.contentView = buildContent()
        if !window.setFrameUsingName("BookmarksWindow") { window.center() }
        window.setFrameAutosaveName("BookmarksWindow")
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildContent() -> NSView {
        searchField.placeholderString = "Search Bookmarks"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        for (identifier, title, width) in [("title", "Name", 320.0), ("address", "Address", 340.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.rowHeight = 22
        outline.target = self
        outline.doubleAction = #selector(openSelected(_:))
        outline.registerForDraggedTypes([Self.dragType, .URL, .string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel("Bookmarks")
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(openSelected(_:))), ("Open in New Tab", #selector(openInNewTabs(_:))),
                                ("Rename", #selector(rename(_:))), ("New Folder", #selector(newFolder(_:))), ("Delete", #selector(delete(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true

        let newFolder = NSButton(title: "New Folder", target: self, action: #selector(newFolder(_:)))
        let delete = NSButton(title: "Delete", target: self, action: #selector(delete(_:)))
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

    // MARK: - Data

    func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            roots = [store.favoritesID, store.menuID].compactMap { try? store.node($0) }.map(Item.init)
        } else {
            roots = ((try? store.search(query)) ?? []).map { let item = Item($0); item.children = []; return item }
        }
        let expanded = query.isEmpty ? roots : []
        outline.reloadData()
        for item in expanded { outline.expandItem(item) }
    }

    private func children(of item: Item) -> [Item] {
        if let children = item.children { return children }
        let children = ((try? store.children(of: item.node.id)) ?? []).map(Item.init)
        item.children = children
        return children
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
        (item as? Item)?.node.kind == .folder && (item as? Item)?.children != []
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = (item as? Item)?.node else { return nil }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "address" {
            field.stringValue = node.url?.absoluteString ?? ""
            field.textColor = .secondaryLabelColor
            return field
        }
        field.stringValue = node.title
        field.isEditable = node.parent != nil
        field.delegate = self
        field.tag = Int(node.id)
        let image = NSImageView(image: NSImage(systemSymbolName: node.kind == .folder ? "folder" : "bookmark", accessibilityDescription: nil) ?? NSImage())
        let stack = NSStackView(views: [image, field])
        stack.spacing = 6
        return stack
    }

    /// Inline rename, committed when editing ends.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== searchField, field.tag != 0 else { return }
        try? store.rename(Int64(field.tag), to: field.stringValue)
        changed?()
    }

    private var selected: [BookmarkStore.Node] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Item)?.node }
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
            try? store.addBookmark(url: url, title: url.host() ?? text, in: folder.id, at: at)
        } else {
            return false
        }
        changed?()
        reload()
        return true
    }

    // MARK: - Actions

    @objc func openSelected(_ sender: Any?) {
        let urls = selected.compactMap(\.url)
        for url in urls { open?(url, urls.count > 1 || NSEvent.modifierFlags.contains(.command)) }
    }

    @objc func openInNewTabs(_ sender: Any?) {
        for url in selected.compactMap(\.url) { open?(url, true) }
    }

    @objc func rename(_ sender: Any?) {
        let row = outline.selectedRow
        guard row >= 0 else { return }
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    @objc func newFolder(_ sender: Any?) {
        let parent = selected.first.map { $0.kind == .folder ? $0.id : ($0.parent ?? store.menuID) } ?? store.menuID
        _ = try? store.addFolder("New Folder", in: parent)
        changed?()
        reload()
    }

    @objc func delete(_ sender: Any?) {
        for node in selected where node.parent != nil { try? store.delete(node.id) }
        changed?()
        reload()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { delete(nil) } else { super.keyDown(with: event) }
    }
}
