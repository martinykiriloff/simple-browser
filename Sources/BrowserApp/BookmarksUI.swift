import AppKit
import DataKit
import BrowserKit

extension Notification.Name {
    /// Posted with the profile's ID as the object whenever its bookmarks or reading list change.
    static let bookmarksDidChange = Notification.Name("Keel.bookmarksDidChange")
}

/// ⌘D, ⌘B, or the star in the address bar: name it, pick a folder, Return. A
/// page already bookmarked opens the same popover to rename, move or remove.
/// Edit… on a bookmark's menu opens it too, with the address to change.
@MainActor
final class AddBookmarkController: NSViewController, NSTextFieldDelegate {
    let titleField = NSTextField()
    let addressField = NSTextField()
    let folderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let store: BookmarkStore
    /// The page being bookmarked; nil when editing a folder.
    private let url: URL?
    private let existing: BookmarkStore.Node?
    /// A bookmark already saved: its address can change too.
    private let editsAddress: Bool
    private let changed: () -> Void

    /// ⌘D, ⌘B or the star: the page's bookmark, new or already there.
    init(store: BookmarkStore, url: URL, title: String, changed: @escaping () -> Void) {
        self.store = store
        self.url = url
        let existing = try? store.bookmark(for: url)
        self.existing = existing
        // Editing from the star shows what Edit… on its menu does.
        self.editsAddress = existing != nil
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
        titleField.stringValue = existing?.title ?? title
        addressField.stringValue = existing?.url?.absoluteString ?? ""
    }

    /// Edit… on a bookmark's or a folder's menu.
    init(store: BookmarkStore, editing node: BookmarkStore.Node, changed: @escaping () -> Void) {
        self.store = store
        self.url = node.url
        self.existing = node
        self.editsAddress = node.kind == .bookmark
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
        titleField.stringValue = node.title
        addressField.stringValue = node.url?.absoluteString ?? ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private var isFolder: Bool { existing?.kind == .folder }

    override func loadView() {
        // In Keel's chrome the popover is Design D's: a flat raised panel, a
        // small caps heading, flat buttons. In the system chrome, AppKit's own.
        let keel = Keel.chromeEnabled
        let headingText = existing == nil ? "Add Bookmark" : isFolder ? "Edit Folder" : "Edit Bookmark"
        let heading = keel ? Keel.sectionLabel(headingText) : NSTextField(labelWithString: headingText)
        if !keel { heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        titleField.setAccessibilityLabel(isFolder ? "Folder name" : "Bookmark name")
        titleField.delegate = self
        addressField.setAccessibilityLabel("Address")
        addressField.placeholderString = "https://"
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.cell?.usesSingleLineMode = true
        addressField.delegate = self
        fillFolders()
        folderPopUp.setAccessibilityLabel("Folder")

        func button(_ title: String, kind: KeelButton.Kind, action: Selector) -> NSButton {
            keel ? KeelButton(title, kind: kind, target: self, action: action) : NSButton(title: title, target: self, action: action)
        }
        let done = button(existing == nil ? "Add" : "Done", kind: .primary, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        var buttons: [NSView] = [NSView(), done]
        if existing != nil, !isFolder {
            buttons.insert(button("Remove", kind: .danger, action: #selector(remove(_:))), at: 0)
        }
        let row = NSStackView(views: buttons)
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            if keel { label.textColor = Keel.muted }
            return label
        }
        var rows: [[NSView]] = [[label("Name:"), titleField]]
        if editsAddress { rows.append([label("Address:"), addressField]) }
        rows.append([label(isFolder ? "Inside:" : "Folder:"), folderPopUp])
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        // One right edge for the name, the address and the folder, however long the address.
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        let stack = NSStackView(views: [heading, grid, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        titleField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        if editsAddress { addressField.widthAnchor.constraint(equalTo: titleField.widthAnchor).isActive = true }
        row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        guard keel else {
            view = stack
            return
        }
        let root = KeelFill(fill: Keel.raised)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.appearance = Keel.darkAppearance
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Every folder, indented, with its ID as the tag. Items are added to the
    /// menu directly: `addItem(withTitle:)` drops a second item with the same
    /// title, and two folders may well share a name. A folder being edited
    /// cannot go inside itself, so it and everything under it are left out.
    private func fillFolders() {
        let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        var skippingBelow: Int?
        for (folder, depth) in (try? store.folders()) ?? [] {
            if let limit = skippingBelow {
                if depth > limit { continue }
                skippingBelow = nil
            }
            if isFolder, folder.id == existing?.id {
                skippingBelow = depth
                continue
            }
            let item = NSMenuItem(title: folder.title, action: nil, keyEquivalent: "")
            item.tag = Int(folder.id)
            item.indentationLevel = depth
            item.image = folderIcon
            folderPopUp.menu?.addItem(item)
        }
        folderPopUp.selectItem(withTag: Int(existing?.parent ?? store.favoritesID))
        if folderPopUp.selectedItem == nil { folderPopUp.selectItem(at: 0) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    /// Return in a field saves: ⌘D, Return.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        done(nil)
        return true
    }

    /// Set once saved or removed: a second Return while the popover closes,
    /// or a second call, must not add the bookmark twice.
    private var isFinished = false

    @objc func done(_ sender: Any?) {
        guard !isFinished else { return }
        let folder = folderPopUp.selectedItem.map { Int64($0.tag) } ?? store.favoritesID
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            var address = existing.url
            if editsAddress {
                // Anything the address bar would go to, bookmarklets included.
                guard let typed = AddressResolver.address(addressField.stringValue) else {
                    NSSound.beep()
                    view.window?.makeFirstResponder(addressField)
                    return
                }
                if typed != existing.url { try? store.setURL(existing.id, to: typed) }
                address = typed
            }
            // An emptied name falls back as a new bookmark's does; a folder keeps its own.
            let name = !title.isEmpty ? title : isFolder ? existing.title : Self.fallbackTitle(for: address)
            if name != existing.title { try? store.rename(existing.id, to: name) }
            if existing.parent != folder { try? store.move(existing.id, to: folder) }
        } else if let url {
            _ = try? store.addBookmark(url: url, title: title.isEmpty ? Self.fallbackTitle(for: url) : title, in: folder)
        }
        isFinished = true
        changed()
        close()
    }

    @objc func remove(_ sender: Any?) {
        guard !isFinished else { return }
        if let existing { try? store.delete(existing.id) }
        isFinished = true
        changed()
        close()
    }

    private func close() {
        dismiss(nil)
        view.window?.close()
    }

    static func fallbackTitle(for url: URL?) -> String {
        url.map { $0.host() ?? $0.absoluteString } ?? ""
    }
}

// MARK: - Bookmark menus

/// What a bookmark's menu needs from the place it is shown in.
@MainActor
struct BookmarkMenuContext {
    let store: BookmarkStore
    /// In this tab, or a new one.
    var open: (URL, _ newTab: Bool) -> Void
    var openInNewWindow: ((URL) -> Void)?
    /// Shows the editor for the node, next to where it was clicked.
    var edit: (BookmarkStore.Node) -> Void
    /// The window a confirmation goes on.
    var window: () -> NSWindow?
    var changed: () -> Void
}

/// The right-click menu for a bookmark or a folder: the same in the
/// favorites bar and the sidebar.
@MainActor
enum BookmarkMenus {
    static func menu(for node: BookmarkStore.Node, _ context: BookmarkMenuContext) -> NSMenu {
        let menu = NSMenu()
        fill(menu, for: node, context)
        return menu
    }

    static func fill(_ menu: NSMenu, for node: BookmarkStore.Node, _ context: BookmarkMenuContext) {
        if let url = node.url {
            menu.addItem(ClosureMenuItem("Open") { context.open(url, false) })
            menu.addItem(ClosureMenuItem("Open in New Tab") { context.open(url, true) })
            if let openInNewWindow = context.openInNewWindow {
                menu.addItem(ClosureMenuItem("Open in New Window") { openInNewWindow(url) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Copy Address") { copy([url]) })
            menu.addItem(ClosureMenuItem("Edit…") { context.edit(node) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete") { delete([node], context) })
        } else {
            let urls = ((try? context.store.children(of: node.id)) ?? []).compactMap(\.url)
            let openAll = ClosureMenuItem(urls.isEmpty ? "Open All in Tabs" : "Open All \(urls.count) in Tabs") {
                for url in urls { context.open(url, true) }
            }
            openAll.isAvailable = !urls.isEmpty
            menu.addItem(openAll)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Rename…") { context.edit(node) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Folder") { delete([node], context) })
        }
    }

    /// One address per line as text, and the first as a URL for apps that take one.
    static func copy(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .URL], owner: nil)
        pasteboard.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        pasteboard.setString(first.absoluteString, forType: .URL)
    }

    static func delete(_ nodes: [BookmarkStore.Node], _ context: BookmarkMenuContext) {
        delete(nodes, store: context.store, window: context.window(), then: context.changed)
    }

    /// Deletes bookmarks and folders. A folder with bookmarks in it is asked
    /// about first: that is the one delete here that loses more than it shows.
    static func delete(_ nodes: [BookmarkStore.Node], store: BookmarkStore, window: NSWindow?, then changed: @escaping () -> Void) {
        let nodes = nodes.filter { $0.parent != nil }
        guard !nodes.isEmpty else { return }
        let perform = {
            for node in nodes { try? store.delete(node.id) }
            changed()
        }
        let inside = nodes.filter { $0.kind == .folder }.reduce(0) { $0 + bookmarkCount(in: $1.id, store) }
        guard inside > 0 else { return perform() }
        let alert = NSAlert()
        alert.messageText = nodes.count == 1 ? "Delete “\(nodes[0].title)”?" : "Delete \(nodes.count) items?"
        alert.informativeText = inside == 1 ? "The bookmark inside will be deleted too." : "The \(inside) bookmarks inside will be deleted too."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let answer = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { perform() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }

    /// Bookmarks in a folder and every folder under it.
    static func bookmarkCount(in folder: Int64, _ store: BookmarkStore) -> Int {
        ((try? store.children(of: folder)) ?? []).reduce(0) { total, child in
            total + (child.kind == .folder ? bookmarkCount(in: child.id, store) : 1)
        }
    }

    /// The editor in a popover beside `rect` in `view`, closed by a click elsewhere or Esc.
    @discardableResult
    static func showEditor(for node: BookmarkStore.Node, store: BookmarkStore, relativeTo rect: NSRect, of view: NSView,
                           preferredEdge: NSRectEdge, changed: @escaping () -> Void) -> AddBookmarkController {
        let editor = AddBookmarkController(store: store, editing: node, changed: changed)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        return editor
    }
}

// MARK: - The favorites bar

/// The favorites bar under the toolbar (⇧⌘B): favorites as buttons with
/// their sites' icons, folders as menus. A click opens in this tab, ⌘-click
/// or a middle click in a new one; a right click has the bookmark's menu.
/// Favorites that do not fit go in a » menu at the end.
@MainActor
final class FavoritesBarController: NSTitlebarAccessoryViewController {
    private let stack = NSStackView()
    private let overflowButton = NSButton()
    var store: () -> BookmarkStore? = { nil }
    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }
    var openInNewWindow: ((URL) -> Void)?
    var changed: () -> Void = {}
    private var faviconObserver: NSObjectProtocol?

    private static let maxButtonWidth: CGFloat = 180
    private static let overflowWidth: CGFloat = 24
    private static let iconSize = NSSize(width: 14, height: 14)

    deinit {
        MainActor.assumeIsolated { faviconObserver.map(NotificationCenter.default.removeObserver) }
    }

    override func loadView() {
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 4, right: 10)
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        let container = FavoritesBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        overflowButton.bezelStyle = .recessed
        overflowButton.showsBorderOnlyWhileMouseInside = true
        overflowButton.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: "More favorites")
        overflowButton.imagePosition = .imageOnly
        overflowButton.toolTip = "More favorites"
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow(_:))
        overflowButton.isHidden = true
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overflowButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overflowButton.leadingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overflowButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            overflowButton.centerYAnchor.constraint(equalTo: stack.centerYAnchor, constant: -1),
            overflowButton.widthAnchor.constraint(equalToConstant: Self.overflowWidth),
            container.heightAnchor.constraint(equalToConstant: 28),
        ])
        view = container
        layoutAttribute = .bottom
        // Icons arrive after the bar is built: they are put on the buttons in place.
        faviconObserver = NotificationCenter.default.addObserver(forName: Favicons.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcons() }
        }
        reload()
    }

    /// For the self-test.
    private(set) var titles: [String] = []
    /// For the self-test: the bar's buttons, shown or in the » menu, and the editor last opened from one.
    private(set) var buttons: [FavoriteButton] = []
    private(set) weak var lastEditor: AddBookmarkController?
    /// For the self-test: the favorites in the » menu, because the bar is too narrow for them.
    var overflowTitles: [String] { buttons.filter(\.isHidden).map(\.title) }

    private var favorites: [BookmarkStore.Node] { store()?.favorites ?? [] }

    func reload() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = []
        let favorites = self.favorites
        titles = favorites.map(\.title)
        if favorites.isEmpty {
            let hint = NSTextField(labelWithString: "Add favorites with ⌘D to see them here.")
            // Readable on the dark chrome: tertiary label colour is not.
            hint.textColor = Keel.chromeEnabled ? Keel.dim : .secondaryLabelColor
            hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            // Where a favorite's title would start, inside its button.
            stack.edgeInsets.left = 16
            stack.addArrangedSubview(hint)
            overflowButton.isHidden = true
            return
        }
        stack.edgeInsets.left = 10
        for node in favorites {
            let button = FavoriteButton(title: node.title, target: self, action: #selector(clicked(_:)))
            button.nodeID = node.id
            button.isFolder = node.kind == .folder
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = node.url?.absoluteString ?? node.title
            button.setAccessibilityLabel(node.kind == .folder ? "\(node.title) folder" : node.title)
            button.image = icon(for: node)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.menuProvider = { [weak self] button in self?.menu(for: button) }
            button.onMiddleClick = { [weak self] button in self?.openInNewTab(button) }
            button.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxButtonWidth).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        view.needsLayout = true
    }

    /// The site's icon, small, or a folder. A copy, sized for the bar: the
    /// cache's own image is shared with the sidebar and the tab bar.
    private func icon(for node: BookmarkStore.Node) -> NSImage? {
        guard node.kind == .bookmark else { return NSImage(systemSymbolName: "folder", accessibilityDescription: nil) }
        let icon = Favicons.shared.icon(for: node.url, title: node.title).copy() as? NSImage
        icon?.size = Self.iconSize
        return icon
    }

    private func refreshIcons() {
        let nodes = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for button in buttons {
            if let node = nodes[button.nodeID], node.kind == .bookmark { button.image = icon(for: node) }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitButtons()
    }

    /// Shows the favorites that fit, in order, and puts the rest in the »
    /// menu. Widths come from the buttons' own sizes, which do not depend on
    /// what is shown, so a second layout pass gives the same answer.
    private func fitButtons() {
        guard !buttons.isEmpty else { return }
        let available = view.bounds.width - stack.edgeInsets.left - stack.edgeInsets.right - Self.overflowWidth - 10
        var used: CGFloat = 0
        var overflowing = false
        for button in buttons {
            let width = min(button.intrinsicContentSize.width, Self.maxButtonWidth)
            let next = used + (used > 0 ? stack.spacing : 0) + width
            overflowing = overflowing || next > available
            if !overflowing { used = next }
            if button.isHidden != overflowing { button.isHidden = overflowing }
        }
        if overflowButton.isHidden != !overflowing { overflowButton.isHidden = !overflowing }
    }

    @objc private func showOverflow(_ sender: NSButton) {
        guard let store = store() else { return }
        let hidden = Set(buttons.filter(\.isHidden).map(\.nodeID))
        let menu = NSMenu()
        BookmarksMenuFiller.fill(menu, with: favorites.filter { hidden.contains($0.id) }) { (try? store.children(of: $0)) ?? [] }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func node(for button: FavoriteButton) -> BookmarkStore.Node? {
        favorites.first { $0.id == button.nodeID }
    }

    @objc private func clicked(_ sender: FavoriteButton) {
        guard let node = node(for: sender), let store = store() else { return }
        if let url = node.url {
            open(url, NSEvent.modifierFlags.contains(.command))
            return
        }
        let menu = NSMenu()
        let children = (try? store.children(of: node.id)) ?? []
        BookmarksMenuFiller.fill(menu, with: children) { (try? store.children(of: $0)) ?? [] }
        let urls = children.compactMap(\.url)
        if urls.isEmpty {
            if menu.items.isEmpty { menu.addItem(withTitle: "Empty", action: nil, keyEquivalent: "") }
        } else {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Open All in Tabs") { [weak self] in
                for url in urls { self?.open(url, true) }
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func openInNewTab(_ button: FavoriteButton) {
        if let url = node(for: button)?.url { open(url, true) }
    }

    func menu(for button: FavoriteButton) -> NSMenu? {
        guard let node = node(for: button), let store = store() else { return nil }
        let context = BookmarkMenuContext(
            store: store, open: open, openInNewWindow: openInNewWindow,
            edit: { [weak self, weak button] node in
                guard let self, let button else { return }
                self.edit(node, from: button)
            },
            window: { [weak self] in self?.view.window }, changed: changed)
        return BookmarkMenus.menu(for: node, context)
    }

    /// Opens the editor under a button. It is anchored to the bar rather than
    /// the button, which a change of favorites replaces.
    func edit(_ node: BookmarkStore.Node, from button: NSView) {
        guard let store = store() else { return }
        lastEditor = BookmarkMenus.showEditor(for: node, store: store, relativeTo: button.convert(button.bounds, to: view), of: view,
                                              preferredEdge: .minY, changed: changed)
    }
}

/// A favorite in the bar: its bookmark's menu on a right click, and a new
/// tab on a middle click, which a plain button ignores. A folder opens its
/// menu as the mouse goes down, as menus do, not when it comes up.
@MainActor
final class FavoriteButton: NSButton {
    var nodeID: Int64 = 0
    var isFolder = false
    var menuProvider: ((FavoriteButton) -> NSMenu?)?
    var onMiddleClick: ((FavoriteButton) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(self) }

    override func mouseDown(with event: NSEvent) {
        // ⌃-click is a right click, which has the folder's own menu.
        guard isFolder, isEnabled, !event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        highlight(true)
        sendAction(action, to: target)
        highlight(false)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.otherMouseUp(with: event)
        }
        onMiddleClick?(self)
    }
}

/// The bar itself: a right click between favorites offers the bar's own commands.
@MainActor
final class FavoritesBarView: NSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show All Bookmarks", action: #selector(AppDelegate.showBookmarks(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Favorites Bar", action: #selector(BrowserWindowController.toggleFavoritesBar(_:)), keyEquivalent: "")
        return menu
    }
}

/// The Bookmarks menu's lower half: Favorites, the Bookmarks Menu folder,
/// and the reading list, rebuilt each time it opens.
@MainActor
final class BookmarksMenuFiller: NSObject, NSMenuDelegate {
    static let tag = 7_002
    private let store: () -> BookmarkStore?

    init(store: @escaping () -> BookmarkStore?) {
        self.store = store
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.tag { menu.removeItem(item) }
        guard let store = store() else { return }
        func add(_ item: NSMenuItem) { item.tag = Self.tag; menu.addItem(item) }
        add(.separator())
        let favorites = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
        favorites.submenu = NSMenu(title: "Favorites")
        Self.fill(favorites.submenu!, with: store.favorites) { (try? store.children(of: $0)) ?? [] }
        add(favorites)
        let reading = NSMenuItem(title: "Reading List", action: nil, keyEquivalent: "")
        reading.submenu = NSMenu(title: "Reading List")
        for item in (try? store.readingList(includeRead: false)) ?? [] {
            let entry = NSMenuItem(title: item.title.isEmpty ? item.url.absoluteString : item.title,
                                   action: #selector(AppDelegate.openBookmarkItem(_:)), keyEquivalent: "")
            entry.representedObject = item.url
            reading.submenu?.addItem(entry)
        }
        if reading.submenu?.items.isEmpty == true { reading.submenu?.addItem(withTitle: "Nothing to read", action: nil, keyEquivalent: "") }
        add(reading)
        let menuItems = (try? store.children(of: store.menuID)) ?? []
        if !menuItems.isEmpty {
            add(.separator())
            let holder = NSMenu()
            Self.fill(holder, with: menuItems) { (try? store.children(of: $0)) ?? [] }
            for item in holder.items {
                holder.removeItem(item)
                add(item)
            }
        }
    }

    static func fill(_ menu: NSMenu, with nodes: [BookmarkStore.Node], children: (Int64) -> [BookmarkStore.Node]) {
        for node in nodes {
            let item = NSMenuItem(title: node.title, action: node.url == nil ? nil : #selector(AppDelegate.openBookmarkItem(_:)), keyEquivalent: "")
            item.representedObject = node.url
            item.toolTip = node.url?.absoluteString
            if node.kind == .folder {
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu(title: node.title)
                fill(submenu, with: children(node.id), children: children)
                if submenu.items.isEmpty { submenu.addItem(withTitle: "Empty", action: nil, keyEquivalent: "") }
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }
}
