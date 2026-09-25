import AppKit

/// The list that drops down under a sign-in field, as Chrome's does.
///
/// It is a native panel, not something drawn into the page: page script can
/// neither read the account names in it nor click it. It never becomes key,
/// so the field in the page keeps its focus and its caret while it is up.
@MainActor
final class CredentialSuggestionPanel {

    struct Item {
        var title: String
        var subtitle: String?
        var symbol: String
        /// Set apart from the accounts by a separator ("Manage Passwords…").
        var isFooter = false
        var action: () -> Void
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private(set) var rows: [SuggestionRow] = []
    private var selection: Int?
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel?.isVisible ?? false }
    /// For the self-test: what is on offer, in order.
    var titles: [String] { rows.map(\.item.title) }

    /// - Parameter anchor: the field, in screen coordinates.
    func show(_ items: [Item], below anchor: NSRect, in parent: NSWindow) {
        hide()
        guard !items.isEmpty else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        rows = []
        for item in items {
            if item.isFooter, !rows.isEmpty {
                let separator = NSBox()
                separator.boxType = .separator
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
                stack.setCustomSpacing(4, after: separator)
                if let previous = rows.last { stack.setCustomSpacing(4, after: previous) }
            }
            let row = SuggestionRow(item: item) { [weak self] in
                self?.hide()
                item.action()
            }
            rows.append(row)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        }

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        let width = min(max(anchor.width, 260), 420)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(equalToConstant: width),
        ])
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize

        // Under the field; above it when there is no room below.
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 3)
        if origin.y < screen.minY { origin.y = anchor.maxY + 3 }
        origin.x = max(screen.minX + 4, min(origin.x, screen.maxX - size.width - 4))

        let panel = Panel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        parent.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.parent = parent
        selection = nil

        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
        }
    }

    func hide() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        rows = []
        selection = nil
    }

    /// Arrow keys, Return and Escape while the list is up. Returns true when
    /// the key was the list's and must not reach the page.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible, !rows.isEmpty else { return false }
        switch event.keyCode {
        case 125: select((selection.map { $0 + 1 } ?? 0) % rows.count); return true                 // ↓
        case 126: select(((selection ?? rows.count) - 1 + rows.count) % rows.count); return true      // ↑
        case 36, 76:                                                                                  // ↩
            guard let selection else { return false }
            rows[selection].choose()
            return true
        case 53: hide(); return true                                                                  // esc
        case 48: hide(); return false                                                                 // tab moves on
        default: return false
        }
    }

    private func select(_ index: Int) {
        selection = index
        for (offset, row) in rows.enumerated() { row.isHighlighted = offset == index }
    }
}

/// One row: icon, title, optional second line. Highlights under the pointer.
@MainActor
final class SuggestionRow: NSView {
    let item: CredentialSuggestionPanel.Item
    private let onChoose: () -> Void
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?
    private let icon = NSImageView()

    var isHighlighted = false { didSet { updateColors() } }

    init(item: CredentialSuggestionPanel.Item, onChoose: @escaping () -> Void) {
        self.item = item
        self.onChoose = onChoose
        titleLabel = NSTextField(labelWithString: item.title)
        subtitleLabel = item.subtitle.map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel?.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel?.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [titleLabel] + (subtitleLabel.map { [$0] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let content = NSStackView(views: [icon, text])
        content.orientation = .horizontal
        content.spacing = 8
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func choose() { onChoose() }

    // The panel is never key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isHighlighted = true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { choose() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    private func updateColors() {
        layer?.backgroundColor = isHighlighted ? NSColor.selectedContentBackgroundColor.cgColor : nil
        titleLabel.textColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
        subtitleLabel?.textColor = isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
        icon.contentTintColor = isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}
