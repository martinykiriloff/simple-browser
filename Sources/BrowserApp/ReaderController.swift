import AppKit
import WebKit
import BrowserKit

/// The articles Reader pages are showing, by the token in their address.
/// In memory only: a Reader page asked for after a relaunch sends its tab
/// to the article itself.
@MainActor
final class ReaderStore {
    static let shared = ReaderStore()
    private var articles: [String: ReaderArticle] = [:]
    private var order: [String] = []

    func add(_ article: ReaderArticle) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        articles[token] = article
        order.append(token)
        if order.count > 40 { articles[order.removeFirst()] = nil }
        return token
    }

    func article(for url: URL?) -> ReaderArticle? {
        ReaderPage.token(of: url).flatMap { articles[$0] }
    }

    /// What the scheme handler serves for a Reader address.
    func html(for url: URL?) -> String {
        guard let article = article(for: url) else { return ReaderPage.redirect(to: ReaderPage.original(of: url)) }
        return ReaderPage.html(article, appearance: BrowserSettings.readerAppearance)
    }
}

/// One tab's Reader: the button that appears when the page has an article,
/// the article taken from the page, and how it looks.
@MainActor
final class ReaderController: NSObject, WKScriptMessageHandler {
    static let worldName = "KeelReader"
    static let handlerName = "reader"
    static let appearanceDidChange = Notification.Name("Keel.readerAppearanceDidChange")

    weak var webView: WKWebView?
    var onStateChange: (() -> Void)?
    private(set) var installError: String?

    let button = NSButton()
    let appearanceButton = NSButton()
    /// The page showing has an article.
    private(set) var isAvailable = false
    private(set) var popover: NSPopover?
    private(set) var appearanceController: ReaderAppearanceController?

    private let world = WKContentWorld.world(name: ReaderController.worldName)
    private weak var userContentController: WKUserContentController?
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        for (control, action) in [(button, #selector(toggle(_:))), (appearanceButton, #selector(showAppearance(_:)))] {
            control.bezelStyle = .toolbar
            control.target = self
            control.action = action
        }
        appearanceButton.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Reader appearance")
        appearanceButton.toolTip = "Font, size and colours in Reader"
        observer = NotificationCenter.default.addObserver(forName: Self.appearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        sync()
    }

    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        guard let url = AppResources.bundle.url(forResource: "reader-agent", withExtension: "js", subdirectory: "ReaderAgent"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            installError = "reader-agent.js is missing from the app's resources"
            return
        }
        controller.add(self, contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    func uninstall() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        popover?.close()
    }

    var isActive: Bool { ReaderPage.isReader(webView?.url) }

    // MARK: - The page

    func didCommitNavigation() {
        isAvailable = false
        popover?.close()
        // Out of Reader and onto its article, by the button or by Back.
        let left = showing
        showing = ReaderPage.original(of: webView?.url)
        restore = left.flatMap { $0 == webView?.url ? scrolled[$0] : nil }
        sync()
    }

    /// WebKit restores a page's scroll position on the way back, from what
    /// its web process last told it. Measured: leaving for a page of the
    /// browser's own scheme within a second of scrolling, it has not been
    /// told yet, and the article comes back at its top. So where the article
    /// was is kept here as Reader is entered, and put back if WebKit did not.
    func didFinishNavigation() {
        guard let position = restore, position > 0, let webView else { return }
        restore = nil
        webView.callAsyncJavaScript("if (window.scrollY < 1) window.scrollTo(0, position)", arguments: ["position": position],
                                    in: nil, in: .defaultClient) { _ in }
    }

    private var showing: URL?
    private var restore: Double?
    private var scrolled: [URL: Double] = [:]

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, message.world == world, let body = message.body as? [String: Any],
              body["kind"] as? String == "readerable", let value = body["value"] as? Bool else { return }
        // The Reader page is itself an article, and the agent says so. It is
        // not offered Reader of Reader. (By what is showing: a frame's own
        // account of itself is stale after an app-initiated load.)
        guard !isActive, webView?.url?.scheme == "http" || webView?.url?.scheme == "https" else { return }
        isAvailable = value
        sync()
    }

    // MARK: - Reader

    /// View → Show Reader / Hide Reader (⇧⌘R), and the button.
    @objc func toggle(_ sender: Any?) {
        if isActive { hide() } else { Task { @MainActor in await show() } }
    }

    /// Takes the article from the page and shows it. False when the page
    /// turned out not to have one.
    @discardableResult
    func show() async -> Bool {
        guard let webView, !isActive, let url = webView.url, url.scheme == "http" || url.scheme == "https" else { return false }
        let script = "const found = window.__sbReader ? window.__sbReader.extract() : null; if (found) found.scrollY = window.scrollY; return found"
        guard let found = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world) as? [String: Any],
              let html = found["html"] as? String, !html.isEmpty, webView.url == url else {
            isAvailable = false
            sync()
            return false
        }
        let article = ReaderArticle(
            url: url, title: found["title"] as? String ?? webView.title ?? "", byline: found["byline"] as? String ?? "",
            site: found["site"] as? String ?? "", published: found["published"] as? String ?? "",
            language: found["language"] as? String ?? "", direction: found["direction"] as? String ?? "ltr",
            words: (found["words"] as? NSNumber)?.intValue ?? 0, html: html)
        guard let address = ReaderPage.url(token: ReaderStore.shared.add(article), original: url) else { return false }
        scrolled = [url: (found["scrollY"] as? NSNumber)?.doubleValue ?? 0]
        webView.load(URLRequest(url: address))
        return true
    }

    /// Back to the page itself: by going back if that is where Back leads,
    /// which keeps its scroll position and what was typed into it.
    func hide() {
        guard let webView, isActive, let original = ReaderPage.original(of: webView.url) else { return }
        if webView.backForwardList.backItem?.url == original { webView.goBack() } else { webView.load(URLRequest(url: original)) }
    }

    // MARK: - Appearance

    @objc func showAppearance(_ sender: Any?) {
        if let popover, popover.isShown { popover.close(); return }
        guard appearanceButton.window != nil else { return }
        let controller = ReaderAppearanceController()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: appearanceButton.bounds, of: appearanceButton, preferredEdge: .maxY)
        self.popover = popover
        appearanceController = controller
    }

    /// A setting changed: the Reader page showing follows at once.
    private func applyAppearance() {
        guard isActive, let webView else { return }
        let attributes = BrowserSettings.readerAppearance.attributes
        webView.callAsyncJavaScript("for (const name in attributes) document.documentElement.setAttribute(name, attributes[name])",
                                    arguments: ["attributes": attributes], in: nil, in: .defaultClient) { _ in }
    }

    func sync() {
        let active = isActive
        button.image = NSImage(systemSymbolName: active ? "doc.plaintext.fill" : "doc.plaintext", accessibilityDescription: "Reader")?
            .withSymbolConfiguration(.init(paletteColors: [active ? .controlAccentColor : .labelColor]))
        button.toolTip = active ? "Hide Reader (⇧⌘R)" : "Show Reader (⇧⌘R)"
        button.setAccessibilityLabel(active ? "Hide Reader" : "Show Reader")
        onStateChange?()
    }
}

/// Font, size, width and colours, in a popover under the "Aa" button.
@MainActor
final class ReaderAppearanceController: NSViewController {
    let themes = NSSegmentedControl(labels: ReaderAppearance.Theme.allCases.map(\.name), trackingMode: .selectOne, target: nil, action: nil)
    let fonts = NSPopUpButton(frame: .zero, pullsDown: false)
    let smaller = NSButton(title: "A", target: nil, action: nil)
    let larger = NSButton(title: "A", target: nil, action: nil)
    let sizeLabel = NSTextField(labelWithString: "")
    let widths = NSSegmentedControl(labels: ReaderAppearance.Width.allCases.map(\.name), trackingMode: .selectOne, target: nil, action: nil)

    override func loadView() {
        themes.target = self
        themes.action = #selector(themeChanged(_:))
        themes.setAccessibilityLabel("Colours")
        fonts.addItems(withTitles: ReaderAppearance.Font.allCases.map(\.name))
        fonts.target = self
        fonts.action = #selector(fontChanged(_:))
        fonts.setAccessibilityLabel("Font")
        smaller.font = .systemFont(ofSize: 11)
        larger.font = .systemFont(ofSize: 17)
        smaller.setAccessibilityLabel("Smaller text")
        larger.setAccessibilityLabel("Larger text")
        for (button, action) in [(smaller, #selector(shrink(_:))), (larger, #selector(grow(_:)))] {
            button.target = self
            button.action = action
        }
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        widths.target = self
        widths.action = #selector(widthChanged(_:))
        widths.setAccessibilityLabel("Width")

        let size = NSStackView(views: [smaller, larger, sizeLabel])
        size.spacing = 6
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Colours"), themes],
            [NSTextField(labelWithString: "Font"), fonts],
            [NSTextField(labelWithString: "Size"), size],
            [NSTextField(labelWithString: "Width"), widths],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for row in 0..<4 { grid.row(at: row).yPlacement = .center }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        view = root
        refresh()
    }

    func refresh() {
        let look = BrowserSettings.readerAppearance
        themes.selectedSegment = ReaderAppearance.Theme.allCases.firstIndex(of: look.theme) ?? 0
        fonts.selectItem(at: ReaderAppearance.Font.allCases.firstIndex(of: look.font) ?? 0)
        widths.selectedSegment = ReaderAppearance.Width.allCases.firstIndex(of: look.width) ?? 1
        sizeLabel.stringValue = "\(look.size) pt"
        smaller.isEnabled = look.canShrink
        larger.isEnabled = look.canGrow
    }

    private func change(_ body: (inout ReaderAppearance) -> Void) {
        var look = BrowserSettings.readerAppearance
        body(&look)
        BrowserSettings.readerAppearance = look
        refresh()
        NotificationCenter.default.post(name: ReaderController.appearanceDidChange, object: nil)
    }

    @objc private func themeChanged(_ sender: Any?) {
        let all = ReaderAppearance.Theme.allCases
        guard all.indices.contains(themes.selectedSegment) else { return }
        change { $0.theme = all[themes.selectedSegment] }
    }

    @objc private func fontChanged(_ sender: Any?) {
        let all = ReaderAppearance.Font.allCases
        guard all.indices.contains(fonts.indexOfSelectedItem) else { return }
        change { $0.font = all[fonts.indexOfSelectedItem] }
    }

    @objc private func widthChanged(_ sender: Any?) {
        let all = ReaderAppearance.Width.allCases
        guard all.indices.contains(widths.selectedSegment) else { return }
        change { $0.width = all[widths.selectedSegment] }
    }

    @objc private func shrink(_ sender: Any?) { change { $0.shrink() } }
    @objc private func grow(_ sender: Any?) { change { $0.grow() } }
}
