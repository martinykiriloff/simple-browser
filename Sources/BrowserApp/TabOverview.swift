import AppKit

/// View → Show All Tabs (⇧⌘\), or a pinch in on the page: every tab of the
/// window as a picture with its title, over the page. A click shows it, ✕
/// closes it, typing filters, arrows move and Return opens, Esc leaves.
///
/// Drawn as Design D's overview (G1-03): a dark surface, a search box,
/// chips that narrow it to agent, borrowed or sandbox tabs, and cards with
/// the page's picture. An agent's tab has an amber ring and the agent's name.
@MainActor
final class TabOverviewController: NSViewController, NSSearchFieldDelegate {
    struct Entry {
        let controller: BrowserWindowController
        let title: String
        let url: URL?
        let image: NSImage?
    }

    /// What a tab is to the agents, for its card and the chips.
    struct Identity: Equatable {
        enum Kind: Equatable { case personal, agent, borrowed, sandbox }
        var kind: Kind
        /// "Claude", or "Borrowed · 42 min".
        var chip: String?

        @MainActor
        static func of(_ controller: BrowserWindowController) -> Identity {
            let session = controller.agentTrust?()?.live(for: controller)?.session
            if case .borrowed(_, let expires) = session?.mode {
                let left = expires.map { " · \(BrowserWindowController.minutesLeft(until: $0)) min" } ?? ""
                return Identity(kind: .borrowed, chip: "Borrowed" + left)
            }
            if controller.agentSessionID != nil {
                return Identity(kind: .agent, chip: session?.clientName ?? "Agent")
            }
            if controller.privateSession != nil { return Identity(kind: .sandbox, chip: nil) }
            return Identity(kind: .personal, chip: nil)
        }
    }

    /// The chips: everything, or one kind of tab.
    enum Filter: CaseIterable {
        case all, agent, borrowed, sandbox

        var title: String {
            switch self {
            case .all: return "All"
            case .agent: return "Agent"
            case .borrowed: return "Borrowed"
            case .sandbox: return "Sandbox"
            }
        }

        func admits(_ identity: Identity) -> Bool {
            switch self {
            case .all: return true
            case .agent: return identity.kind == .agent || identity.kind == .borrowed
            case .borrowed: return identity.kind == .borrowed
            // An agent's own tab is in its sandbox: a sandbox too.
            case .sandbox: return identity.kind == .sandbox || identity.kind == .agent
            }
        }
    }

    var onClose: (() -> Void)?
    let searchField = NSSearchField()
    private let searchBox = KeelFill(fill: Keel.raised, border: Keel.inputBorder, radius: 10)
    private let chipRow = NSStackView()
    private(set) var chips: [Filter: KeelChip] = [:]
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private(set) var entries: [Entry] = []
    private var identities: [ObjectIdentifier: Identity] = [:]
    private(set) var tiles: [TabTile] = []
    private(set) var selectedIndex = 0
    private var filter = ""
    private(set) var kindFilter: Filter = .all

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
        root.appearance = Keel.darkAppearance

        searchField.placeholderString = "Search Tabs"
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search tabs")
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = Keel.font(14)
        searchField.textColor = Keel.text
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let hint = KeelKbd("⇧⌘\\")
        searchBox.addSubview(searchField)
        searchBox.addSubview(hint)
        root.addSubview(searchBox)

        chipRow.spacing = 8
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        for filter in Filter.allCases {
            let chip = KeelChip()
            chip.onClick = { [weak self] in self?.apply(kind: filter) }
            chips[filter] = chip
            chipRow.addArrangedSubview(chip)
        }
        root.addSubview(chipRow)

        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        let width = searchBox.widthAnchor.constraint(equalToConstant: 1100)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            searchBox.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            searchBox.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            width,
            searchBox.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            searchBox.heightAnchor.constraint(equalToConstant: 44),
            searchField.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            chipRow.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 16),
            chipRow.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.setAccessibilityLabel("All tabs")
        view = root
    }

    func show(_ entries: [Entry], selected: BrowserWindowController?) {
        self.entries = entries
        identities = Dictionary(entries.map { (ObjectIdentifier($0.controller), Identity.of($0.controller)) }, uniquingKeysWith: { first, _ in first })
        selectedIndex = max(0, entries.firstIndex { $0.controller === selected } ?? 0)
        searchField.placeholderString = entries.count == 1 ? "Search 1 open tab…" : "Search \(entries.count) open tabs…"
        syncChips()
        apply(filter: searchField.stringValue)
    }

    func identity(of controller: BrowserWindowController) -> Identity {
        identities[ObjectIdentifier(controller)] ?? Identity(kind: .personal, chip: nil)
    }

    private func syncChips() {
        for filter in Filter.allCases {
            guard let chip = chips[filter] else { continue }
            let count = entries.filter { filter.admits(identity(of: $0.controller)) }.count
            let colors: (NSColor, NSColor)
            switch filter {
            case .all: colors = (Keel.inputBorder, Keel.text)
            case .agent: colors = (Keel.amberChip, Keel.amber)
            case .borrowed: colors = (Keel.coralChip, Keel.coralText)
            case .sandbox: colors = (Keel.greenChip, Keel.greenText)
            }
            chip.set("\(filter.title) · \(count)", fill: colors.0, color: colors.1, dot: nil)
            chip.isHidden = filter != .all && count == 0
            chip.layer?.borderWidth = filter == kindFilter ? 1 : 0
            chip.layer?.borderColor = colors.1.cgColor
            chip.setAccessibilityValue(filter == kindFilter ? "selected" : nil)
        }
    }

    var shown: [Entry] {
        let needle = filter.lowercased()
        return entries.filter { entry in
            kindFilter.admits(identity(of: entry.controller))
                && (needle.isEmpty || entry.title.lowercased().contains(needle) || (entry.url?.absoluteString.lowercased().contains(needle) ?? false))
        }
    }

    /// A chip: only that kind of tab (again: all of them).
    func apply(kind: Filter) {
        kindFilter = kindFilter == kind ? .all : kind
        syncChips()
        apply(filter: filter)
    }

    func apply(filter: String) {
        self.filter = filter
        for tile in tiles { tile.removeFromSuperview() }
        tiles = shown.enumerated().map { index, entry in
            let tile = TabTile(entry: entry, identity: identity(of: entry.controller))
            tile.onOpen = { [weak self] in self?.open(entry.controller) }
            tile.onClose = { [weak self] in self?.closeTab(entry.controller) }
            tile.onHandToAgent = { [weak self] in self?.handToAgent(entry.controller) }
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

    private static let gap: CGFloat = 20
    /// Three across in a wide window, as many as fit in a narrow one.
    private var columns: Int { max(1, min(3, Int((gridWidth + Self.gap) / (TabTile.minWidth + Self.gap)))) }
    private var gridWidth: CGFloat { min(1100, max(TabTile.minWidth, view.bounds.width - 48)) }
    private var tileWidth: CGFloat { floor((gridWidth - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)) }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutTiles()
    }

    private func layoutTiles() {
        let columns = self.columns
        let width = tileWidth
        let rowHeight = TabTile.height + Self.gap
        let totalWidth = CGFloat(columns) * (width + Self.gap) - Self.gap
        let left = max(12, (view.bounds.width - totalWidth) / 2)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: left + CGFloat(index % columns) * (width + Self.gap), y: 4 + CGFloat(index / columns) * rowHeight,
                                width: width, height: TabTile.height)
        }
        content.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 24 + CGFloat((tiles.count + columns - 1) / columns) * rowHeight)
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

    /// The card's menu: Hand to agent… acts on the tab in front, so the
    /// card's tab is brought to the front first.
    func handToAgent(_ controller: BrowserWindowController) {
        open(controller)
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(AppDelegate.handTabToAgent(_:)), to: nil, from: nil)
        }
    }

    func closeTab(_ controller: BrowserWindowController) {
        entries.removeAll { $0.controller === controller }
        controller.window?.performClose(nil)
        syncChips()
        if entries.isEmpty { close() } else { apply(filter: filter) }
    }

    func close() { onClose?() }
}

/// One tab: its picture, its title and address, and ✕.
@MainActor
final class TabTile: NSView {
    static let minWidth: CGFloat = 240
    static let height: CGFloat = 206
    static let pictureHeight: CGFloat = 150
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onHandToAgent: (() -> Void)?
    let imageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let addressLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton(title: "×", target: nil, action: nil)
    let identity: TabOverviewController.Identity
    private let image: NSImage?
    var isSelected = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private var ring: NSColor {
        switch identity.kind {
        case .agent: return Keel.amber
        case .borrowed: return Keel.coral
        default: return Keel.hairline
        }
    }

    /// Drawn, not a layer: what a person sees is also what a window picture shows.
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        Keel.surface.setFill()
        card.fill()
        // The picture: the page's top, filling the card's width.
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        let picture = NSRect(x: 1, y: 1, width: bounds.width - 2, height: Self.pictureHeight)
        NSColor.white.setFill()
        picture.fill()
        NSBezierPath(rect: picture).addClip()
        if let image, image.size.width > 0 {
            let scale = picture.width / image.size.width
            let height = image.size.height * scale
            image.draw(in: NSRect(x: picture.minX, y: picture.minY, width: picture.width, height: height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let letter = String((addressLabel.stringValue.isEmpty ? titleLabel.stringValue : addressLabel.stringValue).prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [.font: Keel.font(36, .semibold), .foregroundColor: Keel.pageBorder]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2), withAttributes: attributes)
        }
        if identity.kind == .agent || identity.kind == .borrowed {
            ring.setFill()
            NSRect(x: picture.minX, y: picture.minY, width: picture.width, height: 3).fill()
        }
        Keel.hairline.setFill()
        NSRect(x: picture.minX, y: picture.maxY, width: picture.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()

        // An agent's card keeps its colour; the chosen card's ring is thicker.
        let agent = identity.kind == .agent || identity.kind == .borrowed
        card.lineWidth = isSelected ? 3 : (agent || Accessibility.increaseContrast ? 2 : 1)
        (agent ? ring : isSelected ? Keel.text : Accessibility.increaseContrast ? Keel.muted : ring).setStroke()
        card.stroke()
    }

    init(entry: TabOverviewController.Entry, identity: TabOverviewController.Identity) {
        self.identity = identity
        self.image = entry.image
        super.init(frame: .zero)
        // Kept for the self-test and for VoiceOver's picture of the tab.
        imageView.image = entry.image ?? Self.placeholder(for: entry)
        imageView.isHidden = true
        addSubview(imageView)

        let squareColor: NSColor
        switch identity.kind {
        case .agent: squareColor = Keel.amber
        case .borrowed: squareColor = Keel.coral
        default: squareColor = Keel.idle
        }
        let square = Keel.square(squareColor, size: 12)
        titleLabel.stringValue = entry.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = Keel.font(13, .semibold)
        titleLabel.textColor = identity.kind == .agent ? Keel.amberSoft : Keel.text
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressLabel.stringValue = entry.url.map(Self.shortAddress) ?? ""
        addressLabel.font = Keel.mono
        addressLabel.textColor = Keel.dim
        addressLabel.lineBreakMode = .byTruncatingTail
        addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel, addressLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var row: [NSView] = [square, text]
        if let chipText = identity.chip {
            let chip = KeelChip()
            if identity.kind == .borrowed {
                chip.set(chipText, fill: Keel.coralChip, color: Keel.coralText, dot: nil)
            } else {
                chip.set(chipText, fill: Keel.amberChip, color: Keel.amber, dot: nil)
            }
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.append(chip)
        }
        closeButton.isBordered = false
        closeButton.attributedTitle = NSAttributedString(string: "×", attributes: [.font: Keel.font(16), .foregroundColor: Keel.dim])
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.append(closeButton)
        let footer = NSStackView(views: row)
        footer.spacing = 10
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: topAnchor, constant: Self.pictureHeight + 2),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        toolTip = entry.url?.absoluteString
        menu = makeMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// "shop.acme.test/checkout": the host and path, as the card shows it.
    static func shortAddress(_ url: URL) -> String {
        let host = url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        let path = url.path == "/" ? "" : url.path
        return host.isEmpty ? url.absoluteString : host + path
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Tab", action: #selector(openTab(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if identity.kind == .personal {
            let hand = menu.addItem(withTitle: "Hand to Agent…", action: #selector(handToAgent(_:)), keyEquivalent: "")
            hand.target = self
            hand.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [Keel.amber])))
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "").target = self
        return menu
    }

    override func mouseUp(with event: NSEvent) { onOpen?() }
    @objc private func openTab(_ sender: Any?) { onOpen?() }
    @objc private func closeTab(_ sender: Any?) { onClose?() }
    @objc private func handToAgent(_ sender: Any?) { onHandToAgent?() }
    override var acceptsFirstResponder: Bool { true }

    /// A tab with no picture yet: its site's initial on a tile.
    static func placeholder(for entry: TabOverviewController.Entry) -> NSImage {
        let image = NSImage(size: NSSize(width: 204, height: 130), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let letter = String((entry.url?.host() ?? entry.title).prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: Keel.pageBorder]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
        return image
    }
}

/// The backdrop, which takes the keys: the chrome's surface, flat.
@MainActor
final class OverviewBackground: NSView {
    var onEscape: (() -> Void)?
    var onArrow: ((Int) -> Void)?
    var onReturn: (() -> Void)?
    var onType: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Keel.surface.setFill()
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
