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
