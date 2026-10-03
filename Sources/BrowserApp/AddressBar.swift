import AppKit
import BrowserKit

/// The address bar's field: tells its tab when it takes focus, so the tab
/// can swap the short display (the domain) for the full address.
///
/// In Keel's chrome it is drawn flat (Design D): raised fill, a 1 pt ring,
/// radius 9, 32 pt tall, a status dot before the address (green sandbox,
/// coral borrowed, grey personal) and a ⌘L hint after it.
@MainActor
final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    /// Where the text starts in Keel's chrome, before any accessory: room
    /// for the status dot.
    static let statusInset: CGFloat = 26
    static let height: CGFloat = 32

    enum Status: Equatable {
        case personal, sandbox, borrowed

        @MainActor var color: NSColor {
            switch self {
            case .personal: return Keel.muted
            case .sandbox: return Keel.green
            case .borrowed: return Keel.coral
            }
        }

        var name: String {
            switch self {
            case .personal: return "Personal profile"
            case .sandbox: return "Sandbox, ephemeral"
            case .borrowed: return "Borrowed by an agent"
            }
        }
    }

    override class var cellClass: AnyClass? {
        get { AddressFieldCell.self }
        set {}
    }

    private(set) var isKeelStyle = false
    private let statusDot = NSView()
    private let hint = NSTextField(labelWithString: "⌘L")
    private(set) var status: Status = .personal

    /// Draws the field flat, as Design D's address bar.
    func applyKeelStyle() {
        guard !isKeelStyle else { return }
        isKeelStyle = true
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .default
        textColor = Keel.addressText
        font = Keel.font(13)
        wantsLayer = true
        layer?.backgroundColor = Keel.raised.cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = Keel.inputBorder.cgColor
        if let placeholder = placeholderString {
            placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: Keel.dim, .font: Keel.font(13)])
        }
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.setAccessibilityElement(false)
        hint.font = Keel.mono
        hint.textColor = Keel.dim
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setAccessibilityElement(false)
        addSubview(statusDot)
        addSubview(hint)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let cell = cell as? AddressFieldCell {
            cell.statusInset = Self.statusInset
            cell.trailingInset = 34
            cell.centersVertically = true
        }
        setStatus(status)
        needsDisplay = true
    }

    /// The dot before the address: whose session this tab is in.
    func setStatus(_ status: Status) {
        self.status = status
        statusDot.layer?.backgroundColor = status.color.cgColor
        setAccessibilityHelp(isKeelStyle ? status.name : nil)
    }

    /// The ring follows the rounded field, not its rectangle.
    override func drawFocusRingMask() {
        guard isKeelStyle else { return super.drawFocusRingMask() }
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    /// Something shown inside the field, before the text: the lock, or
    /// "Not Secure". The text and the caret start after it.
    func setLeadingAccessory(_ view: NSView?) {
        let start: CGFloat = isKeelStyle ? Self.statusInset : 8
        if accessory !== view || accessoryStart != start {
            accessory?.removeFromSuperview()
            accessory = view
            accessoryStart = start
            if let view {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: start),
                    view.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
        }
        let width = view.map { $0.isHidden ? 0 : $0.fittingSize.width + (isKeelStyle ? 6 : 12) } ?? 0
        guard let cell = cell as? AddressFieldCell, cell.leadingInset != width else { return }
        cell.leadingInset = width
        needsDisplay = true
        // The field editor, if there is one, was placed with the old inset.
        if let editor = currentEditor() {
            editor.frame = cell.drawingRect(forBounds: bounds)
        }
    }

    private weak var accessory: NSView?
    private var accessoryStart: CGFloat = 8

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

/// Leaves room at the start of the field for the accessory (and, in Keel's
/// chrome, the status dot and the ⌘L hint), and centres the text.
final class AddressFieldCell: NSTextFieldCell {
    var leadingInset: CGFloat = 0
    var statusInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    var centersVertically = false

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inner = super.drawingRect(forBounds: rect)
        let start = leadingInset + statusInset
        inner.origin.x += start
        inner.size.width = max(0, inner.size.width - start - trailingInset)
        if centersVertically, let font {
            let height = ceil(font.ascender - font.descender + font.leading) + 1
            inner.origin.y = rect.minY + floor((rect.height - height) / 2)
            inner.size.height = height
        }
        return inner
    }

    // Unbezeled, the field editor would be placed over the whole field:
    // in Keel's chrome it goes where the text is drawn.
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centersVertically ? drawingRect(forBounds: rect) : rect, in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centersVertically ? drawingRect(forBounds: rect) : rect, in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}

/// The list under the address bar while typing. A child window of the
/// browser window, so it moves with it and never takes focus from the field:
/// the keyboard stays in the address bar, and ↑/↓/Return drive the list.
@MainActor
final class SuggestionsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private(set) var suggestions: [AddressSuggestion] = []
    var onChoose: ((AddressSuggestion) -> Void)?
    private weak var parent: NSWindow?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.setAccessibilityLabel("Suggestions")
        table.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            table.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6),
            table.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
        if Keel.chromeEnabled {
            // Design D: a flat menu, #171B22 with a 1 pt #2A303B ring.
            panel.appearance = Keel.darkAppearance
            let flat = KeelFill(fill: Keel.raised, border: Keel.menuBorder, radius: 12)
            flat.translatesAutoresizingMaskIntoConstraints = true
            table.removeFromSuperview()
            flat.addSubview(table)
            NSLayoutConstraint.activate([
                table.leadingAnchor.constraint(equalTo: flat.leadingAnchor),
                table.trailingAnchor.constraint(equalTo: flat.trailingAnchor),
                table.topAnchor.constraint(equalTo: flat.topAnchor, constant: 6),
                table.bottomAnchor.constraint(equalTo: flat.bottomAnchor, constant: -6),
            ])
            panel.contentView = flat
            isKeelStyle = true
        } else {
            panel.contentView = effect
        }
    }

    private var isKeelStyle = false

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        isKeelStyle ? KeelRowView() : nil
    }

    var isVisible: Bool { panel.isVisible }
    /// The table keeps its selected row until it is reloaded, which can be
    /// after the list behind it was emptied, so the row is checked against
    /// the list rather than trusted.
    var selectedIndex: Int? { suggestions.indices.contains(table.selectedRow) ? table.selectedRow : nil }
    var selected: AddressSuggestion? { selectedIndex.map { suggestions[$0] } }

    func show(_ items: [AddressSuggestion], below field: NSView) {
        guard let window = field.window, !items.isEmpty else { hide(); return }
        let previous = selected
        suggestions = items
        table.reloadData()
        if let previous, let index = items.firstIndex(of: previous) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        let fieldRect = window.convertToScreen(field.convert(field.bounds, to: nil))
        let width = max(fieldRect.width, 560)
        let height = CGFloat(items.count) * table.rowHeight + 12
        panel.setFrame(NSRect(x: fieldRect.minX, y: fieldRect.minY - height - 4, width: width, height: height), display: true)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        panel.orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
        suggestions = []
        table.reloadData()
    }

    /// ↓ and ↑: -1 from the first row goes back to the field.
    func move(by step: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (selectedIndex ?? (step > 0 ? -1 : suggestions.count)) + step
        if next < 0 || next >= suggestions.count {
            table.deselectAll(nil)
        } else {
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
        }
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0, suggestions.indices.contains(table.clickedRow) else { return }
        onChoose?(suggestions[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard suggestions.indices.contains(row) else { return nil }
        let suggestion = suggestions[row]
        let symbol: String
        var badge: String?
        switch suggestion.kind {
        case .switchToTab: symbol = "square.on.square"; badge = "Switch to Tab"
        case .bookmark: symbol = "bookmark"
        case .history: symbol = "clock"
        case .search: symbol = "magnifyingglass"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = isKeelStyle ? Keel.muted : .secondaryLabelColor
        let title = NSTextField(labelWithString: suggestion.title)
        if isKeelStyle { title.textColor = Keel.text }
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        var views: [NSView] = [icon, title]
        if suggestion.kind != .search {
            let detail = NSTextField(labelWithString: isKeelStyle ? suggestion.detail : "— " + suggestion.detail)
            detail.textColor = isKeelStyle ? Keel.dim : .secondaryLabelColor
            if isKeelStyle { detail.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }
            detail.lineBreakMode = .byTruncatingMiddle
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(detail)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        if let badge {
            let label = NSTextField(labelWithString: badge)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = isKeelStyle ? Keel.muted : .controlAccentColor
            views.append(label)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return stack
    }

    /// For the self-test.
    var titles: [String] { suggestions.map(\.title) }
}
