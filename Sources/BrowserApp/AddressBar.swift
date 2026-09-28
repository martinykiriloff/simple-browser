import AppKit
import BrowserKit

/// The address bar's field: tells its tab when it takes focus, so the tab
/// can swap the short display (the domain) for the full address.
@MainActor
final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    override class var cellClass: AnyClass? {
        get { AddressFieldCell.self }
        set {}
    }

    /// Something shown inside the field, before the text: the lock, or
    /// "Not Secure". The text and the caret start after it.
    func setLeadingAccessory(_ view: NSView?) {
        if accessory !== view {
            accessory?.removeFromSuperview()
            accessory = view
            if let view {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                    view.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
        }
        let width = view.map { $0.isHidden ? 0 : $0.fittingSize.width + 12 } ?? 0
        guard let cell = cell as? AddressFieldCell, cell.leadingInset != width else { return }
        cell.leadingInset = width
        needsDisplay = true
        // The field editor, if there is one, was placed with the old inset.
        if let editor = currentEditor() {
            editor.frame = cell.drawingRect(forBounds: bounds)
        }
    }

    private weak var accessory: NSView?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

/// Leaves room at the start of the field for the accessory.
final class AddressFieldCell: NSTextFieldCell {
    var leadingInset: CGFloat = 0

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inner = super.drawingRect(forBounds: rect)
        inner.origin.x += leadingInset
        inner.size.width = max(0, inner.size.width - leadingInset)
        return inner
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
        panel.contentView = effect
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
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: suggestion.title)
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        var views: [NSView] = [icon, title]
        if suggestion.kind != .search {
            let detail = NSTextField(labelWithString: "— " + suggestion.detail)
            detail.textColor = .secondaryLabelColor
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
            label.textColor = .controlAccentColor
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
