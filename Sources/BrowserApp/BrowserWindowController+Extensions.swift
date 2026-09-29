import AppKit
import WebKit
import BrowserKit

/// A tab, as web extensions see it (`chrome.tabs`).
extension BrowserWindowController: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { extensions?.window(of: self) }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        organizer?.tabs(besides: self).firstIndex { $0 === self } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { pageWebView }
    func title(for context: WKWebExtensionContext) -> String? { window?.title }
    func url(for context: WKWebExtensionContext) -> URL? { currentURL }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !pageWebView.isLoading }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { zoom }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        (window?.tabGroup?.selectedWindow ?? window) === window || splitHost != nil
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { reader.isAvailable }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { reader.isActive }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        organizer?.setPinned([self], pinned)
        completionHandler(nil)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        pageWebView.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { pageWebView.reloadFromOrigin() } else { pageWebView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        pageWebView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        pageWebView.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        show()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }

    /// Extensions may act on the page in front as soon as the person clicks
    /// their button (activeTab), as in every browser.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// The extensions' buttons in the toolbar.
extension BrowserWindowController {
    /// One button per extension with an action, in the order they were added.
    func syncExtensionButtons() {
        let loaded = extensions?.loaded ?? []
        extensionButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (item, context) in loaded {
            guard let action = context.action(for: self) else { continue }
            let button = ExtensionButton(id: item.id)
            button.image = action.icon(for: NSSize(width: 18, height: 18)) ?? context.webExtension.icon(for: NSSize(width: 18, height: 18))
            button.imageScaling = .scaleProportionallyDown
            button.bezelStyle = .toolbar
            button.isEnabled = action.isEnabled
            button.badge = action.badgeText
            let label = action.label.isEmpty ? item.name : action.label
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = #selector(extensionButtonClicked(_:))
            button.menuFor = { [weak self] in self?.extensionMenu(for: item.id) }
            extensionButtons.addArrangedSubview(button)
        }
        extensionsItem?.isHidden = extensionButtons.arrangedSubviews.isEmpty
        fitAddressField()
    }

    func extensionButton(for id: String) -> ExtensionButton? {
        extensionButtons.arrangedSubviews.compactMap { $0 as? ExtensionButton }.first { $0.id == id }
    }

    @objc func extensionButtonClicked(_ sender: ExtensionButton) {
        guard let context = extensions?.contexts[sender.id] else { return }
        context.performAction(for: self)
    }

    private func extensionMenu(for id: String) -> NSMenu {
        let menu = NSMenu()
        if let context = extensions?.contexts[id], let options = context.optionsPageURL {
            menu.addItem(ClosureMenuItem("Options") { [weak self] in self?.openInNewTab?(options, true) })
        }
        menu.addItem(ClosureMenuItem("Manage Extensions…") {
            NSApp.sendAction(#selector(AppDelegate.showExtensionsSettings(_:)), to: nil, from: nil)
        })
        return menu
    }

    /// The extensions' own items for the right-click menu of this page.
    func extensionMenuItems() -> [NSMenuItem] {
        (extensions?.loaded ?? []).flatMap { $0.context.menuItems(for: self) }
    }
}

/// An extension's toolbar button, with its badge.
@MainActor
final class ExtensionButton: NSButton {
    let id: String
    var menuFor: (() -> NSMenu?)?
    var badge: String = "" { didSet { badgeLabel.stringValue = badge; badgeLabel.isHidden = badge.isEmpty } }
    private let badgeLabel = NSTextField(labelWithString: "")

    init(id: String) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        badgeLabel.font = .systemFont(ofSize: 8, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.drawsBackground = true
        badgeLabel.backgroundColor = .systemRed
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 3
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1),
            widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func menu(for event: NSEvent) -> NSMenu? { menuFor?() }
}
