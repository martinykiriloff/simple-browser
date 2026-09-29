import AppKit

/// View → Open in Split View and Close Split View.
extension BrowserWindowController {
    /// This tab and the next one side by side; alone in its window, with a new tab.
    @objc func openInSplitView(_ sender: Any?) {
        guard !isInSplit, let organizer else { return }
        let tabs = organizer.tabs(besides: self).filter { !$0.isInSplit }
        let index = tabs.firstIndex { $0 === self } ?? 0
        let partner = tabs.indices.contains(index + 1) ? tabs[index + 1] : index > 0 ? tabs[index - 1] : organizer.openTabs?(self, []).first
        guard let partner else { return }
        // Whichever is further left takes the left side.
        let partnerFirst = tabs.firstIndex { $0 === partner }.map { $0 < index } ?? false
        SplitViewController.open(partnerFirst ? self : partner, beside: partnerFirst ? partner : self)
    }

    @objc func closeSplitView(_ sender: Any?) {
        (split ?? splitHost?.split)?.end(front: self)
    }

    /// Another tab of this window beside this one.
    func openInSplitView(with other: BrowserWindowController) {
        guard !isInSplit, !other.isInSplit else { return }
        SplitViewController.open(other, beside: self)
    }
}

extension BrowserWindowController {
    /// Open Link in Split View: a new tab beside this one. Already in a
    /// split, the link opens in a new tab.
    func openLinkInSplitView(_ url: URL) {
        guard let organizer, let tab = organizer.openTabs?(self, [url]).first else { return }
        if !isInSplit { SplitViewController.open(tab, beside: self) }
    }

    /// While a tab is dragged from the sidebar, the right edge of the page
    /// takes it, for split view.
    func showSplitDropZone(_ shown: Bool) {
        let area = pageArea
        area.subviews.compactMap { $0 as? SplitDropZone }.forEach { $0.removeFromSuperview() }
        splitDropZone = nil
        guard shown, !isInSplit else { return }
        let zone = SplitDropZone()
        zone.onDrop = { [weak self] id in
            guard let self, let tab = self.organizer?.tabs(besides: self).first(where: { $0.tab.description == id }), tab !== self else { return false }
            self.showSplitDropZone(false)
            self.openInSplitView(with: tab)
            return true
        }
        zone.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(zone, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            zone.topAnchor.constraint(equalTo: area.topAnchor),
            zone.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            zone.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            zone.widthAnchor.constraint(equalTo: area.widthAnchor, multiplier: 0.3),
        ])
        splitDropZone = zone
    }
}

/// The right edge of a page while a tab is dragged: drop it there to show it beside.
@MainActor
final class SplitDropZone: NSView {
    var onDrop: ((String) -> Bool)?
    private let label = NSTextField(labelWithString: "Open in Split View")
    private(set) var isTargeted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.sidebarTab])
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        setAccessibilityLabel("Open in Split View")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func target(_ on: Bool) {
        isTargeted = on
        label.isHidden = !on
        layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .sidebarTab) != nil else { return [] }
        target(true)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { target(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        target(false)
        guard let id = sender.draggingPasteboard.string(forType: .sidebarTab) else { return false }
        return onDrop?(id) ?? false
    }

    /// For the self-test: a drop of the tab with this id.
    func drop(_ id: String) -> Bool { onDrop?(id) ?? false }
}
