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
