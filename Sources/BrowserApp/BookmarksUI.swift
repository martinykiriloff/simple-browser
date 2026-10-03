import AppKit
import DataKit
import BrowserKit

extension Notification.Name {
    /// Posted with the profile's ID as the object whenever its bookmarks or reading list change.
    static let bookmarksDidChange = Notification.Name("Keel.bookmarksDidChange")
}

/// ⌘D, or the star in the address bar: name it, pick a folder, Return. A
/// page already bookmarked opens the same popover to rename, move or remove.
@MainActor
final class AddBookmarkController: NSViewController, NSTextFieldDelegate {
    let titleField = NSTextField()
    let folderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let store: BookmarkStore
    private let url: URL
    private let existing: BookmarkStore.Node?
    private let changed: () -> Void
    private var folderIDs: [Int64] = []

    init(store: BookmarkStore, url: URL, title: String, changed: @escaping () -> Void) {
        self.store = store
        self.url = url
        self.existing = try? store.bookmark(for: url)
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
        titleField.stringValue = existing?.title ?? title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let heading = NSTextField(labelWithString: existing == nil ? "Add Bookmark" : "Edit Bookmark")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleField.setAccessibilityLabel("Bookmark name")
        titleField.delegate = self
        for (folder, depth) in (try? store.folders()) ?? [] {
            folderPopUp.addItem(withTitle: String(repeating: "    ", count: depth) + folder.title)
            folderIDs.append(folder.id)
        }
        let selected = existing?.parent ?? store.favoritesID
        folderPopUp.selectItem(at: folderIDs.firstIndex(of: selected) ?? 0)
        folderPopUp.setAccessibilityLabel("Folder")

        let done = NSButton(title: existing == nil ? "Add" : "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        var buttons: [NSView] = [NSView(), done]
        if existing != nil {
            let remove = NSButton(title: "Remove", target: self, action: #selector(remove(_:)))
            buttons.insert(remove, at: 0)
        }
        let row = NSStackView(views: buttons)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name:"), titleField], [NSTextField(labelWithString: "Folder:"), folderPopUp]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let stack = NSStackView(views: [heading, grid, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        titleField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    /// Return in the name field adds it: ⌘D, Return.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        done(nil)
        return true
    }

    @objc func done(_ sender: Any?) {
        let folder = folderIDs.indices.contains(folderPopUp.indexOfSelectedItem) ? folderIDs[folderPopUp.indexOfSelectedItem] : store.favoritesID
        let title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        if let existing {
            try? store.rename(existing.id, to: title)
            if existing.parent != folder { try? store.move(existing.id, to: folder) }
        } else {
            try? store.addBookmark(url: url, title: title.isEmpty ? (url.host() ?? url.absoluteString) : title, in: folder)
        }
        changed()
        dismiss(nil)
        view.window?.close()
    }

    @objc func remove(_ sender: Any?) {
        if let existing { try? store.delete(existing.id) }
        changed()
        dismiss(nil)
        view.window?.close()
    }
}

/// The favorites bar under the toolbar (⇧⌘B): favorites as buttons, folders
/// as menus. A click opens in this tab, ⌘-click in a new one.
@MainActor
final class FavoritesBarController: NSTitlebarAccessoryViewController {
    private let stack = NSStackView()
    var items: () -> [BookmarkStore.Node] = { [] }
    var childrenOf: (Int64) -> [BookmarkStore.Node] = { _ in [] }
    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }

    override func loadView() {
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 4, right: 10)
        stack.alignment = .centerY
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 28),
        ])
        view = container
        layoutAttribute = .bottom
        reload()
    }

    /// For the self-test.
    private(set) var titles: [String] = []

    func reload() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let favorites = items()
        titles = favorites.map(\.title)
        if favorites.isEmpty {
            let hint = NSTextField(labelWithString: "Add favorites with ⌘D to see them here.")
            hint.textColor = .tertiaryLabelColor
            hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            stack.addArrangedSubview(hint)
            return
        }
        for node in favorites {
            let button = NSButton(title: node.title, target: self, action: #selector(clicked(_:)))
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.lineBreakMode = .byTruncatingTail
            button.tag = Int(node.id)
            button.toolTip = node.url?.absoluteString ?? node.title
            if node.kind == .folder {
                button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                button.imagePosition = .imageLeading
            }
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            stack.addArrangedSubview(button)
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        let node = items().first { Int($0.id) == sender.tag }
        if let url = node?.url {
            open(url, NSEvent.modifierFlags.contains(.command))
        } else if let node {
            let menu = NSMenu()
            BookmarksMenuFiller.fill(menu, with: childrenOf(node.id), children: childrenOf)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
        }
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
