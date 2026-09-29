import AppKit

/// Two tabs side by side in one window. Each tab is a window of its own, so
/// the tab on the right (the guest) lends its page to the window of the tab
/// on the left (the host) and leaves the tab bar while the split lasts. The
/// toolbar is the side in front's own: the window takes that tab's toolbar,
/// so its address, buttons and menus act on it. Closing either side, by its
/// header's button or ⌘W on it, leaves the other as an ordinary tab.
@MainActor
final class SplitViewController: NSObject, NSSplitViewDelegate {
    private(set) weak var host: BrowserWindowController!
    private(set) weak var guest: BrowserWindowController!
    private(set) weak var focused: BrowserWindowController!

    let pages = NSSplitView()
    let hostPane: SplitPane
    let guestPane: SplitPane
    private var hostToolbar: NSToolbar?
    private var guestToolbar: NSToolbar?
    private var guestResponder: NSResponder?
    private var mouseMonitor: Any?
    private var observer: NSObjectProtocol?
    private var applying = false

    /// Opens `guest` beside `host`, in host's window.
    @discardableResult
    static func open(_ guest: BrowserWindowController, beside host: BrowserWindowController) -> SplitViewController? {
        guard host !== guest, !host.isInSplit, !guest.isInSplit, host.isPrivate == guest.isPrivate,
              host.profile.id == guest.profile.id, let hostWindow = host.window, guest.window != nil else { return nil }
        let split = SplitViewController(host: host, guest: guest)
        split.start(in: hostWindow)
        return split
    }

    private init(host: BrowserWindowController, guest: BrowserWindowController) {
        self.host = host
        self.guest = guest
        self.focused = host
        hostPane = SplitPane(owner: host)
        guestPane = SplitPane(owner: guest)
        super.init()
    }

    private func start(in hostWindow: NSWindow) {
        // Laying the panes out is not the divider being moved.
        applying = true
        // Out of the tab bar: a window ordered out leaves its tab group.
        guest.window?.orderOut(nil)
        hostToolbar = hostWindow.toolbar
        guestToolbar = guest.window?.toolbar

        hostPane.embed(host.detachPage())
        guestPane.embed(guest.detachPage())
        hostPane.onClose = { [weak self] in self.map { $0.close($0.host) } }
        guestPane.onClose = { [weak self] in self.map { $0.close($0.guest) } }
        pages.isVertical = true
        pages.dividerStyle = .thin
        pages.delegate = self
        pages.addArrangedSubview(hostPane)
        pages.addArrangedSubview(guestPane)
        host.showInPlaceOfPage(pages)
        host.split = self
        guest.splitHost = host
        // The guest answers menus for its own page: it is next after its pane.
        guestResponder = guest.nextResponder
        guest.nextResponder = pages

        pages.layoutSubtreeIfNeeded()
        applyFraction()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.host?.window else { return event }
            let point = self.guestPane.convert(event.locationInWindow, from: nil)
            let side: BrowserWindowController? = self.guestPane.bounds.contains(point) ? self.guest
                : self.hostPane.bounds.contains(self.hostPane.convert(event.locationInWindow, from: nil)) ? self.host : nil
            if let side, side !== self.focused { self.focus(side, moveKeyboard: false) }
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: TabOrganizer.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncHeaders() }
        }
        focus(guest)
        host.organizer?.changed()
    }

    // MARK: - Focus

    /// Makes one side the one in front: its toolbar in the window, the
    /// keyboard in its page, its header marked.
    func focus(_ side: BrowserWindowController, moveKeyboard: Bool = true) {
        guard side === host || side === guest, let window = host.window else { return }
        focused = side
        let toolbar = side === guest ? guestToolbar : hostToolbar
        if window.toolbar !== toolbar {
            if side === guest {
                guest.window?.toolbar = nil
                window.toolbar = guestToolbar
            } else {
                window.toolbar = hostToolbar
                guest.window?.toolbar = guestToolbar
            }
            side.fitAddressField()
            window.toolbar?.validateVisibleItems()
        }
        if moveKeyboard { window.makeFirstResponder(side.pageWebView) }
        syncHeaders()
    }

    private func syncHeaders() {
        guard let host, let guest else { return }
        hostPane.header.show(title: host.window?.title ?? "", url: host.currentURL, focused: focused === host)
        guestPane.header.show(title: guest.window?.title ?? "", url: guest.currentURL, focused: focused === guest)
        // The tab bar shows the pair as one tab.
        host.window?.tab.title = "\(host.window?.title ?? "")  |  \(guest.window?.title ?? "")"
    }

    // MARK: - Ending

    /// Closes one side's tab; the other goes on as a tab of its own.
    func close(_ side: BrowserWindowController) {
        let other: BrowserWindowController = side === host ? guest : host
        end(front: other)
        side.window?.performClose(nil)
    }

    /// Back to two tabs, the guest just after the host in the tab bar.
    func end(front: BrowserWindowController? = nil) {
        guard let host, let guest, host.split === self else { return }
        applying = true
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        host.window?.toolbar = hostToolbar
        guest.window?.toolbar = guestToolbar
        guest.nextResponder = guestResponder
        host.split = nil
        guest.splitHost = nil
        host.window?.tab.title = nil
        hostPane.release()
        guestPane.release()
        host.reattachPage(replacing: pages)
        guest.reattachPage()
        if let window = host.window, let guestWindow = guest.window {
            guestWindow.tabbingMode = .automatic
            window.addTabbedWindow(guestWindow, ordered: .above)
            guest.acceptTabs()
        }
        (front ?? host).window?.makeKeyAndOrderFront(nil)
        host.organizer?.arrange(besides: host)
        host.organizer?.changed()
    }

    // MARK: - The divider

    /// The left page's share of the width, as it was last left.
    var fraction: Double {
        let total = pages.bounds.width - pages.dividerThickness
        return total > 0 ? Double(hostPane.frame.width / total) : BrowserSettings.splitFraction
    }

    func setFraction(_ fraction: Double) {
        let total = pages.bounds.width - pages.dividerThickness
        pages.setPosition(CGFloat(fraction) * total, ofDividerAt: 0)
    }

    private func applyFraction() {
        applying = true
        setFraction(BrowserSettings.splitFraction)
        DispatchQueue.main.async { [weak self] in self?.applying = false }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, splitView.bounds.width * 0.2)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width * 0.8)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    /// Remembered for the next split, as the divider is left.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applying, hostPane.superview === pages, guestPane.superview === pages,
              hostPane.frame.width > 0, guestPane.frame.width > 0, pages.window != nil else { return }
        // A window being resized keeps the share; the divider moving changes it.
        guard pages.window?.inLiveResize != true else { return }
        BrowserSettings.splitFraction = fraction
    }
}

/// One side of a split: a header with the page's site and a close button,
/// and the page under it. Its next responder is its tab, so the menus act
/// on the page it holds.
@MainActor
final class SplitPane: NSView {
    weak var owner: BrowserWindowController?
    let header = SplitHeader()
    private weak var page: NSView?
    var onClose: (() -> Void)? {
        get { header.onClose }
        set { header.onClose = newValue }
    }

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init(frame: .zero)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func embed(_ view: NSView) {
        page = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: header.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Lets go of the page, to go back to its own window.
    func release() {
        guard let page else { return }
        page.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = true
        page.autoresizingMask = [.width, .height]
    }

    override var nextResponder: NSResponder? {
        get { owner?.splitHost != nil ? owner : super.nextResponder }
        set { super.nextResponder = newValue }
    }
}

/// A side's header: which site it is, and whether it is the side in front.
@MainActor
final class SplitHeader: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    var onClose: (() -> Void)?
    private(set) var isFocused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close This Side")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.toolTip = "Close this tab; the other stays"
        closeButton.setAccessibilityLabel("Close This Side")
        for view in [icon, label, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(title: String, url: URL?, focused: Bool) {
        isFocused = focused
        icon.image = Favicons.shared.icon(for: url, title: title)
        let host = url?.host() ?? ""
        label.stringValue = host.isEmpty || title.isEmpty ? (title.isEmpty ? host : title) : "\(title) — \(host)"
        label.textColor = focused ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel("\(focused ? "In front: " : "")\(label.stringValue)")
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    /// The side in front has the accent colour under its header.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.sublayers?.removeAll { $0.name == "accent" }
        let line = CALayer()
        line.name = "accent"
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: isFocused ? 2 : 1)
        line.backgroundColor = (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        line.autoresizingMask = [.layerWidthSizable]
        layer?.addSublayer(line)
    }

    @objc private func close(_ sender: Any?) { onClose?() }
}
