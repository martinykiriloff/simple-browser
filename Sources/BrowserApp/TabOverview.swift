import AppKit

/// View → Show All Tabs (⇧⌘\), or a pinch in on the page: every tab of the
/// window as a picture with its title, over the page. A click shows it, ✕
/// closes it, typing filters, arrows move and Return opens, Esc leaves.
@MainActor
final class TabOverviewController: NSViewController, NSSearchFieldDelegate {
    struct Entry {
        let controller: BrowserWindowController
        let title: String
        let url: URL?
        let image: NSImage?
    }

    var onClose: (() -> Void)?
    let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private(set) var entries: [Entry] = []
    private(set) var tiles: [TabTile] = []
    private(set) var selectedIndex = 0
    private var filter = ""

    override func loadView() {
        let root = OverviewBackground()
        root.onEscape = { [weak self] in self?.close() }
        root.onArrow = { [weak self] step in self?.move(by: step) }
        root.onReturn = { [weak self] in self?.openSelected() }
        root.onType = { [weak self] text in
            guard let self else { return }
            self.searchField.stringValue += text
            self.view.window?.makeFirstResponder(self.searchField)
            self.searchField.currentEditor()?.selectedRange = NSRange(location: self.searchField.stringValue.count, length: 0)
            self.apply(filter: self.searchField.stringValue)
        }
        searchField.placeholderString = "Search Tabs"
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search tabs")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchField)
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 320),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.setAccessibilityLabel("All tabs")
        view = root
    }

    func show(_ entries: [Entry], selected: BrowserWindowController?) {
        self.entries = entries
        selectedIndex = max(0, entries.firstIndex { $0.controller === selected } ?? 0)
        apply(filter: searchField.stringValue)
    }

    var shown: [Entry] {
        let needle = filter.lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.title.lowercased().contains(needle) || ($0.url?.absoluteString.lowercased().contains(needle) ?? false) }
    }

    func apply(filter: String) {
        self.filter = filter
        for tile in tiles { tile.removeFromSuperview() }
        tiles = shown.enumerated().map { index, entry in
            let tile = TabTile(entry: entry)
            tile.onOpen = { [weak self] in self?.open(entry.controller) }
            tile.onClose = { [weak self] in self?.closeTab(entry.controller) }
            tile.setAccessibilityLabel(entry.title)
            tile.setAccessibilityRole(.button)
            content.addSubview(tile)
            return tile
        }
        selectedIndex = min(selectedIndex, max(0, tiles.count - 1))
        layoutTiles()
        highlight()
    }

    func controlTextDidChange(_ notification: Notification) { apply(filter: searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { close() } else { searchField.stringValue = ""; apply(filter: "") }
            return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.moveLeft(_:)): move(by: -1); return true
        case #selector(NSResponder.moveRight(_:)): move(by: 1); return true
        case #selector(NSResponder.moveDown(_:)): move(by: columns); return true
        case #selector(NSResponder.moveUp(_:)): move(by: -columns); return true
        default: return false
        }
    }

    private var columns: Int { max(1, Int((view.bounds.width - 24) / (TabTile.width + 16))) }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutTiles()
    }

    private func layoutTiles() {
        let columns = self.columns
        let rowHeight = TabTile.height + 16
        let totalWidth = CGFloat(columns) * (TabTile.width + 16) - 16
        let left = max(12, (view.bounds.width - totalWidth) / 2)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: left + CGFloat(index % columns) * (TabTile.width + 16), y: 8 + CGFloat(index / columns) * rowHeight,
                                width: TabTile.width, height: TabTile.height)
        }
        content.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 16 + CGFloat((tiles.count + columns - 1) / columns) * rowHeight)
    }

    private func highlight() {
        for (index, tile) in tiles.enumerated() { tile.isSelected = index == selectedIndex }
        if tiles.indices.contains(selectedIndex) { content.scrollToVisible(tiles[selectedIndex].frame) }
    }

    func move(by step: Int) {
        guard !tiles.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + step), tiles.count - 1)
        highlight()
    }

    func openSelected() {
        guard shown.indices.contains(selectedIndex) else { return }
        open(shown[selectedIndex].controller)
    }

    func open(_ controller: BrowserWindowController) {
        close()
        controller.show()
    }

    func closeTab(_ controller: BrowserWindowController) {
        entries.removeAll { $0.controller === controller }
        controller.window?.performClose(nil)
        if entries.isEmpty { close() } else { apply(filter: filter) }
    }

    func close() { onClose?() }
}

/// One tab: its picture, its title, and ✕.
@MainActor
final class TabTile: NSView {
    static let width: CGFloat = 220
    static let height: CGFloat = 176
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    let imageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab") ?? NSImage(), target: nil, action: nil)
    var isSelected = false { didSet { needsDisplay = true } }

    /// Drawn, not a layer: what a person sees is also what a window picture shows.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        if isSelected {
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        } else if Accessibility.increaseContrast {
            path.lineWidth = 1
            NSColor.labelColor.setStroke()
            path.stroke()
        }
    }

    init(entry: TabOverviewController.Entry) {
        super.init(frame: .zero)
        imageView.image = entry.image ?? Self.placeholder(for: entry)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = entry.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.toolTip = "Close Tab"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(titleLabel)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.heightAnchor.constraint(equalToConstant: 130),
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        toolTip = entry.url?.absoluteString
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func mouseUp(with event: NSEvent) { onOpen?() }
    @objc private func closeTab(_ sender: Any?) { onClose?() }
    override var acceptsFirstResponder: Bool { true }

    /// A tab with no picture yet: its site's initial on a tile.
    static func placeholder(for entry: TabOverviewController.Entry) -> NSImage {
        let image = NSImage(size: NSSize(width: 204, height: 130), flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            rect.fill()
            let letter = String((entry.url?.host() ?? entry.title).prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
        return image
    }
}

/// The dimmed backdrop, which takes the keys.
@MainActor
final class OverviewBackground: NSView {
    var onEscape: (() -> Void)?
    var onArrow: ((Int) -> Void)?
    var onReturn: (() -> Void)?
    var onType: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.withAlphaComponent(Accessibility.increaseContrast ? 1 : 0.96).setFill()
        dirtyRect.fill()
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()
        case 123: onArrow?(-1)
        case 124: onArrow?(1)
        case 36: onReturn?()
        default:
            if let text = event.characters, !text.isEmpty, event.modifierFlags.intersection([.command, .control]).isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                onType?(text)
            } else { super.keyDown(with: event) }
        }
    }
    override func mouseDown(with event: NSEvent) { onEscape?() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
