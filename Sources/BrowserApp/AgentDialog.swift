import AppKit

/// One of the agent dialogs (pairing, grants, lending, the stop summary): a
/// dark window sized to its content, a clock for countdowns, and what to do
/// when it closes or the trust layer changes under it.
@MainActor
final class AgentDialog: NSObject, NSWindowDelegate {
    let window: NSWindow
    let width: CGFloat
    /// Every second while the dialog is open.
    var onTick: (() -> Void)? {
        didSet { startClock() }
    }
    /// Paired clients, sessions or pairings changed.
    var onTrustChange: (() -> Void)? {
        didSet { observeTrust() }
    }
    var onClose: (() -> Void)?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(title: String, width: CGFloat) {
        self.width = width
        window = Keel.dialogWindow(title: title, width: width)
        super.init()
        window.delegate = self
    }

    /// Shows a step of the dialog; the window takes the step's height.
    func show(_ content: NSView, width: CGFloat? = nil, focus: NSView? = nil) {
        Keel.setDialogContent(content, of: window, width: width ?? self.width)
        window.makeKeyAndOrderFront(nil)
        if let focus { window.makeFirstResponder(focus) }
    }

    /// The content grew or shrank (an origin added, a note shown).
    func refit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let done = onClose
        onClose = nil
        onTick = nil
        onTrustChange = nil
        done?()
    }

    private func startClock() {
        guard timer == nil, onTick != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
    }

    private func observeTrust() {
        guard observer == nil, onTrustChange != nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .agentTrustDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTrustChange?() }
        }
    }

    // MARK: - Layout helpers

    /// Pins a view inside a box; a box without vertical insets centres it.
    static func embed(_ view: NSView, in box: NSView, insets: NSEdgeInsets) {
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -insets.right),
        ])
        if insets.top == 0, insets.bottom == 0 {
            view.centerYAnchor.constraint(equalTo: box.centerYAnchor).isActive = true
        } else {
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: insets.top).isActive = true
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -insets.bottom).isActive = true
        }
    }

    /// The dialog's body: views stacked at the dialog's inner width.
    static func column(_ views: [NSView], width: CGFloat, spacing: CGFloat = 16) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 24, right: 24)
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: width - 48).isActive = true
        }
        return stack
    }

    /// A section: its label, then its parts, 8 pt apart.
    static func section(_ title: String, _ views: [NSView], width: CGFloat) -> NSStackView {
        let stack = NSStackView(views: [Keel.sectionLabel(title)] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in views { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return stack
    }

    /// Wrapping text at a known width, so the window can size to it.
    static func text(_ value: String, width: CGFloat, size: CGFloat = 13, color: NSColor = Keel.muted) -> NSTextField {
        let label = Keel.label(value, size: size, color: color, wraps: true)
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// Title and the line under it.
    static func heading(_ title: String, _ subtitle: String?, width: CGFloat) -> NSStackView {
        var views: [NSView] = [Keel.label(title, size: 17, weight: .semibold)]
        if let subtitle { views.append(text(subtitle, width: width)) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// A row of buttons, with an optional note or spacer on the left.
    static func footer(note: String? = nil, leading: [NSView] = [], trailing: [NSView], width: CGFloat) -> NSStackView {
        var views = leading
        if let note {
            let label = text(note, width: width - 220, size: 12, color: Keel.dim)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views.append(label)
        } else {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            views.append(spacer)
        }
        let stack = NSStackView(views: views + trailing)
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    /// A ✓ and a title, with a mono line under it ("Claude Code is paired").
    static func doneHeader(_ title: String, detail: String) -> NSStackView {
        let words = NSStackView(views: [Keel.label(title, size: 17, weight: .semibold), Keel.monoLabel(detail)])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        let stack = NSStackView(views: [Keel.checkBadge(size: 28), words])
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }
}
