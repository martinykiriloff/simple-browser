import AppKit

/// Design D ("Slim console"): dark chrome around a light page. Agent is
/// amber, sandbox green, borrowed coral, danger red. Flat fills, 1px
/// borders, no gradients or blur.
@MainActor
enum Keel {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                 blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    // Chrome
    static let chrome = hex(0x0B0D11)
    static let surface = hex(0x12151B)
    static let raised = hex(0x171B22)
    static let hairline = hex(0x232831)
    static let inputBorder = hex(0x262C36)
    static let menuBorder = hex(0x2A303B)
    static let text = hex(0xE6E8EC)
    static let muted = hex(0x9AA1AD)
    static let dim = hex(0x7C8492)

    // Agent
    static let amber = hex(0xF2A93B)
    static let amberChip = hex(0x3A2A0E)
    static let amberSoft = hex(0xF0C98A)
    static let approvalBackground = hex(0x1A160F)
    static let approvalBorder = hex(0x5A4216)
    static let approvalBody = hex(0xB5AA93)
    static let onAmber = hex(0x2A1B00)

    // Sandbox
    static let green = hex(0x4CC38A)
    static let greenChip = hex(0x12281F)
    static let greenText = hex(0x6FD3A4)

    // Borrowed
    static let coral = hex(0xE2704A)
    static let coralChip = hex(0x33180F)
    static let coralText = hex(0xF2A58A)

    // Danger
    static let dangerText = hex(0xFF8A80)
    static let dangerFill = hex(0x3A1717)

    static let blue = hex(0x6EA0FF)
    static let idle = hex(0x5B6472)

    static var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    /// "SECTION": 11 pt, semibold, tracked, dim.
    static func sectionLabel(_ text: String, color: NSColor = Keel.dim) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text.uppercased(), attributes: [
            .font: font(11, .semibold), .foregroundColor: color, .kern: 0.66,
        ]))
        return label
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Keel.text, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = font(size, weight)
        label.textColor = color
        label.isSelectable = false
        return label
    }

    static func monoLabel(_ text: String, color: NSColor = Keel.dim) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}

/// A flat 32 pt button with the design's fills.
final class KeelButton: NSButton {
    enum Kind { case allow, neutral, danger, primary, coral }

    private let kind: Kind

    init(_ title: String, kind: Kind, target: AnyObject?, action: Selector?) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var colors: (fill: NSColor, text: NSColor) {
        switch kind {
        case .allow: return (Keel.amber, Keel.onAmber)
        case .neutral: return (Keel.inputBorder, Keel.text)
        case .danger: return (Keel.dangerFill, Keel.dangerText)
        case .primary: return (Keel.text, Keel.chrome)
        case .coral: return (Keel.coral, Keel.hex(0x2A0F05))
        }
    }

    private func apply() {
        layer?.backgroundColor = colors.fill.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [.font: Keel.font(13, .semibold), .foregroundColor: colors.text])
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 32, height: 32)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A pill: "Sandbox · ephemeral", "1 waiting".
final class KeelChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = Keel.font(12, .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ text: String, fill: NSColor, color: NSColor, dot dotColor: NSColor?) {
        label.stringValue = text
        label.textColor = color
        layer?.backgroundColor = fill.cgColor
        dot.isHidden = dotColor == nil
        dot.layer?.backgroundColor = dotColor?.cgColor
        setAccessibilityLabel(text)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// A flat rounded panel with a 1 pt border.
class KeelPanel: NSView {
    init(fill: NSColor, border: NSColor, radius: CGFloat = 12) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = radius
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Dialog parts (pairing, grants, lending, the activity log)

extension Keel {
    /// Radio and checkbox rings, "off".
    static let ring = hex(0x5B6472)
    /// The ring of a picked row that is not an identity choice.
    static let pickedRing = hex(0x3A414D)

    /// A flat, dark window for the agent dialogs: no title bar to speak of,
    /// the dialog fill, and only a close button.
    static func dialogWindow(title: String, width: CGFloat) -> NSWindow {
        let window = KeelDialogWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = surface
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        QuietMode.apply(to: window)
        return window
    }

    /// Puts a view in a dialog window and sizes the window to it, keeping the
    /// top edge where it was.
    static func setDialogContent(_ view: NSView, of window: NSWindow, width: CGFloat) {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = surface.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        let top = window.frame.maxY
        let wasVisible = window.isVisible
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        let size = container.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.minX
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
        if !wasVisible { window.center() }
    }

    /// A 1 pt hairline.
    static func separator(_ color: NSColor = Keel.hairline) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = color.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// A flat square or circle with an optional glyph: icons, status marks.
    static func mark(_ fill: NSColor, size: CGFloat = 16, radius: CGFloat? = nil, glyph: String? = nil, glyphColor: NSColor = Keel.text,
                     border: NSColor? = nil) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = fill.cgColor
        view.layer?.cornerRadius = radius ?? size / 2
        if let border { view.layer?.borderColor = border.cgColor; view.layer?.borderWidth = 1.5 }
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: size), view.heightAnchor.constraint(equalToConstant: size)])
        if let glyph {
            let label = Keel.label(glyph, size: max(9, size * 0.6), weight: .heavy, color: glyphColor)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                         label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        }
        view.setAccessibilityElement(false)
        return view
    }

    /// The green ✓ of a step that is done.
    static func checkBadge(size: CGFloat = 18) -> NSView { mark(greenChip, size: size, glyph: "✓", glyphColor: green) }

    /// A 24 pt toolbar button ("Export JSON", "Copy").
    static func miniButton(_ title: String, kind: KeelButton.Kind = .neutral, handler: @escaping () -> Void) -> NSButton {
        let button = KeelMiniButton(title: title, kind: kind)
        KeelButtonActions.attach(button, handler)
        return button
    }

    /// A text field in the design's rounded input box.
    static func inputField(placeholder: String, mono: Bool = false) -> (box: NSView, field: NSTextField) {
        let box = KeelPanel(fill: raised, border: inputBorder, radius: 9)
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = mono ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : font(13)
        field.textColor = text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: dim, .font: field.font!])
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel(placeholder)
        box.addSubview(field)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 32),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return (box, field)
    }

    /// Lays views out in rows that wrap at `width`, like inline chips.
    static func wrapping(_ views: [NSView], width: CGFloat, spacing: CGFloat = 6) -> NSStackView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = spacing
        var row = NSStackView()
        var used: CGFloat = 0
        for view in views {
            let needed = view.fittingSize.width
            if used > 0, used + spacing + needed > width {
                rows.addArrangedSubview(row)
                row = NSStackView()
                used = 0
            }
            row.spacing = spacing
            row.addArrangedSubview(view)
            used += (used > 0 ? spacing : 0) + needed
        }
        if !row.arrangedSubviews.isEmpty { rows.addArrangedSubview(row) }
        return rows
    }

    /// "HH:mm:ss" in the person's time zone.
    static func clock(_ date: Date, seconds: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }
}

/// A dialog window that closes on Esc when no Cancel button took the key.
final class KeelDialogWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { performClose(nil) } else { super.keyDown(with: event) }
    }
}

/// A 24 pt flat button, for toolbars and Copy.
final class KeelMiniButton: NSButton {
    private let kind: KeelButton.Kind

    init(title: String, kind: KeelButton.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Changes the title and keeps the design's fills.
    func setLabel(_ text: String) {
        title = text
        restyle()
    }

    override var isEnabled: Bool {
        didSet { restyle() }
    }

    private func restyle() {
        let fill: NSColor, color: NSColor
        switch kind {
        case .danger: (fill, color) = (Keel.dangerFill, Keel.dangerText)
        case .allow: (fill, color) = (Keel.amber, Keel.onAmber)
        case .coral: (fill, color) = (Keel.coral, Keel.hex(0x2A0F05))
        case .primary: (fill, color) = (Keel.text, Keel.chrome)
        case .neutral: (fill, color) = (Keel.inputBorder, Keel.text)
        }
        layer?.backgroundColor = fill.cgColor
        alphaValue = isEnabled ? 1 : 0.45
        attributedTitle = NSAttributedString(string: title, attributes: [.font: Keel.font(12, .semibold), .foregroundColor: color])
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 20, height: 24)
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// A row the person picks: a radio or a checkbox, a title and a line of
/// explanation. Session type, approval policy, origins to lend.
final class KeelOptionRow: NSView {
    enum Indicator { case radio, check }

    @MainActor
    struct Accent {
        var mark: NSColor
        /// Fill and ring of the picked row; nil keeps the plain look.
        var fill: NSColor?
        var ring: NSColor
        var title: NSColor
        static let sandbox = Accent(mark: Keel.green, fill: Keel.greenChip, ring: Keel.green, title: Keel.greenText)
        static let borrowed = Accent(mark: Keel.coral, fill: Keel.coralChip, ring: Keel.coral, title: Keel.coralText)
        static let plain = Accent(mark: Keel.green, fill: Keel.raised, ring: Keel.pickedRing, title: Keel.text)
        static let lend = Accent(mark: Keel.coral, fill: Keel.raised, ring: Keel.coral, title: Keel.text)
    }

    private let indicatorKind: Indicator
    private let accent: Accent
    private let indicator = NSView()
    private let inner = NSTextField(labelWithString: "")
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    let trailing = NSStackView()
    var onToggle: (() -> Void)?

    var isOn = false { didSet { restyle() } }
    var isDisabled = false { didSet { restyle() } }

    init(title: String, subtitle: String, indicator kind: Indicator, accent: Accent, monoTitle: Bool = false) {
        indicatorKind = kind
        self.accent = accent
        titleLabel = Keel.label(title, size: 13, weight: .semibold)
        if monoTitle { titleLabel.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold) }
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel = Keel.label(subtitle, size: 12, color: Keel.muted, wraps: true)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false

        indicator.wantsLayer = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        let size: CGFloat = kind == .radio ? 16 : 18
        indicator.layer?.cornerRadius = kind == .radio ? 8 : 5
        inner.font = Keel.font(11, .heavy)
        inner.alignment = .center
        inner.translatesAutoresizingMaskIntoConstraints = false
        indicator.addSubview(inner)

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.spacing = 6
        let row = NSStackView(views: [indicator, text, trailing])
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: size), indicator.heightAnchor.constraint(equalToConstant: size),
            inner.centerXAnchor.constraint(equalTo: indicator.centerXAnchor), inner.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(kind == .radio ? .radioButton : .checkBox)
        setAccessibilityLabel(title)
        setAccessibilityHelp(subtitle)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The width the explanation wraps at.
    func setTextWidth(_ width: CGFloat) {
        subtitleLabel.preferredMaxLayoutWidth = width
        titleLabel.preferredMaxLayoutWidth = width
    }

    var subtitle: String {
        get { subtitleLabel.stringValue }
        set { subtitleLabel.stringValue = newValue; setAccessibilityHelp(newValue) }
    }

    private func restyle() {
        let picked = isOn && !isDisabled
        layer?.backgroundColor = (isDisabled ? Keel.hex(0x0F1217) : picked ? (accent.fill ?? .clear) : .clear).cgColor
        layer?.borderColor = (isDisabled ? Keel.hex(0x1C2027) : picked ? accent.ring : Keel.hairline).cgColor
        layer?.borderWidth = picked && accent.fill != Keel.raised ? 1.5 : 1
        titleLabel.textColor = picked ? accent.title : Keel.text
        indicator.layer?.backgroundColor = (picked ? accent.mark : isDisabled ? Keel.hairline : .clear).cgColor
        indicator.layer?.borderColor = Keel.ring.cgColor
        indicator.layer?.borderWidth = picked || isDisabled ? 0 : 1.5
        switch indicatorKind {
        case .radio:
            inner.stringValue = picked ? "●" : ""
            inner.font = Keel.font(7)
            inner.textColor = Keel.chrome
        case .check:
            inner.stringValue = picked ? "✓" : ""
            inner.textColor = Keel.hex(0x1F0B04)
        }
        alphaValue = isDisabled ? 0.62 : 1
        setAccessibilityValue(isOn)
        setAccessibilityEnabled(!isDisabled)
    }

    override func mouseDown(with event: NSEvent) { if !isDisabled { onToggle?() } }
    override func accessibilityPerformPress() -> Bool {
        guard !isDisabled, let onToggle else { return false }
        onToggle()
        return true
    }
    override func resetCursorRects() { if !isDisabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// One choice out of a few, in a flat track: "15 min · 1 h · Until I stop".
final class KeelSegmented: NSView {
    private var buttons: [NSButton] = []
    private let titles: [String]
    private let fill: NSColor
    private let selectedText: NSColor
    var onChange: ((Int) -> Void)?

    var selectedIndex: Int { didSet { restyle() } }

    init(_ titles: [String], selected: Int = 0, fill: NSColor = Keel.coral, selectedText: NSColor = Keel.hex(0x1F0B04), label: String) {
        self.titles = titles
        self.fill = fill
        self.selectedText = selectedText
        selectedIndex = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Keel.chrome.cgColor
        layer?.borderColor = Keel.hairline.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: nil, action: nil)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.setButtonType(.momentaryChange)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            KeelButtonActions.attach(button) { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.onChange?(index)
            }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(label)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func restyle() {
        for (index, button) in buttons.enumerated() {
            let on = index == selectedIndex
            button.layer?.backgroundColor = (on ? fill : .clear).cgColor
            button.attributedTitle = NSAttributedString(string: titles[index], attributes: [
                .font: Keel.font(13, on ? .bold : .regular), .foregroundColor: on ? selectedText : Keel.muted,
            ])
            button.setAccessibilityValue(on ? "selected" : "")
        }
    }
}

/// − value unit +, for budgets.
final class KeelStepper: NSView {
    private let value = NSTextField(labelWithString: "")
    var onStep: ((Int) -> Void)?

    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = Keel.raised.cgColor
        layer?.borderColor = Keel.inputBorder.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        func step(_ glyph: String, _ delta: Int, _ name: String) -> NSButton {
            let button = NSButton(title: glyph, target: nil, action: nil)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = Keel.inputBorder.cgColor
            button.attributedTitle = NSAttributedString(string: glyph, attributes: [.font: Keel.font(15), .foregroundColor: Keel.text])
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)])
            button.setAccessibilityLabel("\(name) \(label)")
            KeelButtonActions.attach(button) { [weak self] in self?.onStep?(delta) }
            return button
        }
        value.alignment = .center
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [step("−", -1, "Decrease"), value, step("+", 1, "Increase")])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.incrementor)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// "200" "actions".
    func set(_ number: String, unit: String) {
        let text = NSMutableAttributedString(string: number, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: Keel.text,
        ])
        text.append(NSAttributedString(string: " " + unit, attributes: [.font: Keel.font(12), .foregroundColor: Keel.dim]))
        value.attributedStringValue = text
        setAccessibilityValue("\(number) \(unit)")
    }

    override func accessibilityPerformIncrement() -> Bool { onStep?(1); return true }
    override func accessibilityPerformDecrement() -> Bool { onStep?(-1); return true }
}

/// Text the person copies: an endpoint, a command, a config. Mono, in a
/// raised box, with a Copy button.
final class KeelCopyField: KeelPanel {
    private let text: NSTextField
    private var copy: NSButton?

    /// `width`: the box's width, for text that wraps.
    init(_ value: String, note: String? = nil, wraps: Bool = false, label: String, width: CGFloat? = nil) {
        text = wraps ? NSTextField(wrappingLabelWithString: value) : NSTextField(labelWithString: value)
        super.init(fill: Keel.raised, border: Keel.inputBorder, radius: 9)
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = Keel.text
        text.isSelectable = true
        text.lineBreakMode = wraps ? .byCharWrapping : .byTruncatingMiddle
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setAccessibilityLabel(label)
        if let width { text.preferredMaxLayoutWidth = width - 100 }
        let button = Keel.miniButton("Copy") { [weak self] in self?.copyValue() }
        button.setAccessibilityLabel("Copy \(label)")
        copy = button
        var views: [NSView] = [text]
        if let note { views.append(Keel.label(note, size: 12, color: Keel.dim)) }
        views.append(button)
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.alignment = wraps ? .top : .centerY
        stack.edgeInsets = NSEdgeInsets(top: wraps ? 9 : 6, left: 12, bottom: wraps ? 9 : 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var value: String { text.stringValue }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.stringValue, forType: .string)
        (copy as? KeelMiniButton)?.setLabel("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { (self?.copy as? KeelMiniButton)?.setLabel("Copy") }
        }
    }
}

/// An origin as a removable pill: "shop.acme.test ×".
final class KeelTokenChip: KeelPanel {
    init(_ text: String, onRemove: @escaping () -> Void) {
        super.init(fill: Keel.raised, border: Keel.menuBorder, radius: 13)
        let label = Keel.monoLabel(text, color: Keel.text)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let remove = NSButton(title: "×", target: nil, action: nil)
        remove.isBordered = false
        remove.attributedTitle = NSAttributedString(string: "×", attributes: [.font: Keel.font(13), .foregroundColor: Keel.dim])
        remove.setAccessibilityLabel("Remove \(text)")
        KeelButtonActions.attach(remove, onRemove)
        let stack = NSStackView(views: [label, remove])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Settings panes

/// Top-down layout for scrolling content.
final class KeelFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The design's 34×20 switch: green when on, grey when off, white knob.
final class KeelSwitch: NSControl {
    var isOn = false { didSet { update() } }
    private let knob = CALayer()

    init(label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 20))
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 10
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = 8
        layer?.addSublayer(knob)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityLabel(label)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }
    override var isEnabled: Bool { didSet { update() } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(Accessibility.reduceMotion)
        layer?.backgroundColor = (isOn ? Keel.green : Keel.menuBorder).cgColor
        knob.frame = NSRect(x: isOn ? 16 : 2, y: 2, width: 16, height: 16)
        CATransaction.commit()
        alphaValue = isEnabled ? 1 : 0.4
        setAccessibilityValue(isOn ? 1 : 0)
    }

    /// Flips, and tells the target, as a click on a checkbox does.
    func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func mouseDown(with event: NSEvent) { toggle() }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { toggle() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }
}

/// A card of rows split by 1 pt hairlines (Settings, G4-01…05).
final class KeelCard: KeelPanel {
    private let stack = NSStackView()

    init(rows: [NSView] = [], fill: NSColor = Keel.raised) {
        super.init(fill: fill, border: Keel.hairline)
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setRows(rows)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRows(_ rows: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(KeelSettings.hairline()) }
            stack.addArrangedSubview(row)
        }
    }
}

/// Building blocks of the dark Settings panes (Agents & permissions,
/// Developer & MCP): a header, a scrolling column of sections, rows.
@MainActor
enum KeelSettings {
    /// The pane's size; the column inside is `contentWidth` wide.
    static let paneSize = NSSize(width: 680, height: 620)
    static let contentWidth: CGFloat = paneSize.width - 56
    static let page = Keel.surface

    static func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Keel.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// "Keel 1.4.2 · build 318 · WebKit 626.1".
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        let webKit = Bundle(identifier: "com.apple.WebKit")?.infoDictionary?["CFBundleVersion"] as? String
        return (["Keel \(version)"] + [build.map { "build \($0)" }, webKit.map { "WebKit \($0)" }].compactMap { $0 }).joined(separator: " · ")
    }

    /// The whole pane: a 60 pt header with the title and the version, then
    /// the sections in a scroll view. Dark whatever the system appearance.
    static func page(title: String, subtitle: String, sections: [NSView]) -> NSView {
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = page.cgColor
        // The window may be wider than the pane (the pane chooser above it
        // sets its width): the pane then fills it rather than sitting in it.
        let width = root.widthAnchor.constraint(equalToConstant: paneSize.width)
        width.priority = .defaultLow
        let height = root.heightAnchor.constraint(equalToConstant: paneSize.height)
        height.priority = .defaultLow

        let titleLabel = Keel.label(title, size: 17, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        let subtitleLabel = Keel.label(subtitle, size: 12, color: Keel.muted)
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let version = Keel.monoLabel(versionLine)
        version.lineBreakMode = .byTruncatingTail
        version.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titles, NSView(), version])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 0, left: 28, bottom: 0, right: 28)
        header.translatesAutoresizingMaskIntoConstraints = false
        let line = hairline()

        let column = NSStackView(views: sections)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 28, right: 28)
        column.translatesAutoresizingMaskIntoConstraints = false
        let document = KeelFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(line)
        root.addSubview(scroll)
        for section in sections where !(section is NSTextField) {
            section.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -56).isActive = true
        }
        NSLayoutConstraint.activate([
            width, height,
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: paneSize.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 60),
            line.topAnchor.constraint(equalTo: header.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        return root
    }

    /// "SECTION", with the 24 pt gap above it the design has between sections.
    static func section(_ text: String, first: Bool = false) -> NSView {
        let label = Keel.sectionLabel(text)
        label.setAccessibilityRole(.staticText)
        let wrapper = NSStackView(views: [label])
        wrapper.edgeInsets = NSEdgeInsets(top: first ? 0 : 16, left: 0, bottom: 0, right: 0)
        return wrapper
    }

    /// A 12 pt muted line that wraps at `width`.
    static func note(_ text: String, width: CGFloat = contentWidth, size: CGFloat = 12, color: NSColor = Keel.muted) -> NSTextField {
        let label = Keel.label(text, size: size, color: color, wraps: true)
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// A settings row: title and an optional detail on the left, controls on
    /// the right; at least 48 pt tall.
    static func row(_ title: String, detail: String? = nil, detailWidth: CGFloat = 340, leading: [NSView] = [], accessories: [NSView]) -> NSView {
        let titleLabel = Keel.label(title)
        var labels: [NSView] = [titleLabel]
        if let detail { labels.append(note(detail, width: detailWidth)) }
        return row(labels: labels, leading: leading, accessories: accessories)
    }

    static func row(labels: [NSView], leading: [NSView] = [], accessories: [NSView]) -> NSView {
        let text = NSStackView(views: labels)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: leading + [text, spacer] + accessories)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        for view in accessories { view.setContentHuggingPriority(.required, for: .horizontal) }
        return row
    }

    /// A pop-up of fixed choices, as the design's 32 pt select.
    static func popUp(_ titles: [String], label: String, target: AnyObject?, action: Selector?) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: titles)
        popUp.target = target
        popUp.action = action
        popUp.setAccessibilityLabel(label)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return popUp
    }

    /// A 7 pt status dot.
    static func dot(_ color: NSColor) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)])
        return dot
    }

    /// A 22 pt pill with text only: "Experimental", "Not in this build".
    static func tag(_ text: String, fill: NSColor, color: NSColor) -> NSView {
        let label = Keel.label(text, size: 11.5, weight: .medium, color: color)
        let pill = KeelPanel(fill: fill, border: fill, radius: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        pill.setContentHuggingPriority(.required, for: .horizontal)
        return pill
    }

    /// A small mono chip: tool names, key hints.
    static func codeChip(_ text: String, color: NSColor = Keel.text, border: NSColor = Keel.inputBorder) -> NSView {
        let label = Keel.monoLabel(text, color: color)
        label.lineBreakMode = .byClipping
        let chip = KeelPanel(fill: Keel.chrome, border: border, radius: 6)
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
        ])
        chip.setAccessibilityElement(false)
        return chip
    }

    /// Views in rows that wrap at `width`, left to right.
    static func flow(_ views: [NSView], width: CGFloat, spacing: CGFloat = 6) -> NSStackView {
        var lines: [[NSView]] = [[]]
        var used: CGFloat = 0
        for view in views {
            let size = view.fittingSize.width
            if !lines[lines.count - 1].isEmpty, used + spacing + size > width {
                lines.append([])
                used = 0
            }
            used += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size
            lines[lines.count - 1].append(view)
        }
        let stack = NSStackView(views: lines.map { line in
            let row = NSStackView(views: line)
            row.spacing = spacing
            return row
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
}
