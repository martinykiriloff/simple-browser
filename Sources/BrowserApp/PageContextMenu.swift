import AppKit
import WebKit
import BrowserKit
import TranslateKit

/// The right-click menu on a page, as Safari and Chrome have it.
///
/// WebKit builds a menu for what was clicked: a link, an image, a selection,
/// a text field or the page. Its editing, copying, Look Up, Share and Speech
/// items work as they are and are kept. Items that expect a browser around
/// the web view -- a new window, a download, a web search, the page actions --
/// would do nothing, or open Safari, so they are replaced by the app's own.
@MainActor
final class PageContextMenu: NSObject, WKScriptMessageHandler {
    static let worldName = "SimpleBrowserPageMenu"
    static let handlerName = "pageMenu"

    /// What the pointer was on, reported by the agent as the menu opened.
    struct Context: Equatable {
        var link: URL?
        var linkText = ""
        var image: URL?
        var media: URL?
        var selection = ""
    }

    private(set) var context = Context()
    private let world = WKContentWorld.world(name: worldName)
    private weak var userContentController: WKUserContentController?
    private(set) var installError: String?

    weak var webView: BrowserWebView?
    let translator: PageTranslator
    let downloads: DownloadController
    /// Opens a URL in a new window of this window's profile.
    var openInNewWindow: ((URL) -> Void)?
    /// Opens a URL in a new tab beside this one, behind it.
    var openInNewTab: ((URL) -> Void)?
    var inspect: ((CGPoint) -> Void)?
    var viewSource: (() -> Void)?
    /// For the self-test: the titles of the last menu shown, after rewriting.
    private(set) var lastTitles: [String] = []
    private(set) weak var lastMenu: NSMenu?
    var onMenuReady: ((NSMenu) -> Void)?

    init(translator: PageTranslator, downloads: DownloadController) {
        self.translator = translator
        self.downloads = downloads
        super.init()
    }

    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        guard let url = AppResources.bundle.url(forResource: "page-menu-agent", withExtension: "js", subdirectory: "PageMenuAgent"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            installError = "page-menu-agent.js is missing from the app's resources"
            return
        }
        controller.add(self, contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }

    func uninstall() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        func url(_ key: String) -> URL? {
            (body[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        context = Context(link: url("link"), linkText: body["linkText"] as? String ?? "",
                          image: url("image"), media: url("media"), selection: body["selection"] as? String ?? "")
    }

    // MARK: - Building the menu

    private enum WebKitItem: String {
        case openLink = "WKMenuItemIdentifierOpenLink"
        case openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
        case downloadLinkedFile = "WKMenuItemIdentifierDownloadLinkedFile"
        case copyLink = "WKMenuItemIdentifierCopyLink"
        case openImageInNewWindow = "WKMenuItemIdentifierOpenImageInNewWindow"
        case downloadImage = "WKMenuItemIdentifierDownloadImage"
        case copyImage = "WKMenuItemIdentifierCopyImage"
        case openMediaInNewWindow = "WKMenuItemIdentifierOpenMediaInNewWindow"
        case downloadMedia = "WKMenuItemIdentifierDownloadMedia"
        case copyMediaLink = "WKMenuItemIdentifierCopyMediaLink"
        case openFrameInNewWindow = "WKMenuItemIdentifierOpenFrameInNewWindow"
        case searchWeb = "WKMenuItemIdentifierSearchWeb"
        case translate = "WKMenuItemIdentifierTranslate"
        case reload = "WKMenuItemIdentifierReload"
        case goBack = "WKMenuItemIdentifierGoBack"
        case goForward = "WKMenuItemIdentifierGoForward"
        case inspectElement = "WKMenuItemIdentifierInspectElement"
        case copy = "WKMenuItemIdentifierCopy"
        case paste = "WKMenuItemIdentifierPaste"
    }

    private func find(_ menu: NSMenu, _ item: WebKitItem) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == item.rawValue }
    }

    private func add(_ title: String, _ action: Selector, after anchor: NSMenuItem?, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let anchor, let index = menu.items.firstIndex(of: anchor) { menu.insertItem(item, at: index + 1) } else { menu.addItem(item) }
        return item
    }

    /// Puts an item of ours where WebKit's was.
    @discardableResult
    private func replace(_ item: WebKitItem, in menu: NSMenu, title: String, action: Selector) -> NSMenuItem? {
        guard let existing = find(menu, item), let index = menu.items.firstIndex(of: existing) else { return nil }
        let replacement = NSMenuItem(title: title, action: action, keyEquivalent: "")
        replacement.target = self
        menu.removeItem(at: index)
        menu.insertItem(replacement, at: index)
        return replacement
    }

    private func remove(_ item: WebKitItem, from menu: NSMenu) {
        if let existing = find(menu, item) { menu.removeItem(existing) }
    }

    func rewrite(_ menu: NSMenu) {
        let isPage = find(menu, .reload) != nil || find(menu, .goBack) != nil

        // Links. "Open Link" (same tab) and "Copy Link" work as they are.
        if let newWindow = replace(.openLinkInNewWindow, in: menu, title: "Open Link in New Window", action: #selector(openLinkInNewWindow(_:))),
           let index = menu.items.firstIndex(of: newWindow) {
            let tab = NSMenuItem(title: "Open Link in New Tab", action: #selector(openLinkInNewTab(_:)), keyEquivalent: "")
            tab.target = self
            menu.insertItem(tab, at: index)
        }
        replace(.downloadLinkedFile, in: menu, title: "Save Link As…", action: #selector(saveLinkAs(_:)))

        // Images.
        replace(.openImageInNewWindow, in: menu, title: "Open Image in New Window", action: #selector(openImageInNewWindow(_:)))
        replace(.downloadImage, in: menu, title: "Save Image As…", action: #selector(saveImageAs(_:)))
        if let copyImage = find(menu, .copyImage), context.image != nil {
            _ = add("Copy Image Address", #selector(copyImageAddress(_:)), after: copyImage, in: menu)
        }

        // Video and audio.
        replace(.openMediaInNewWindow, in: menu, title: "Open Video in New Window", action: #selector(openMediaInNewWindow(_:)))
        replace(.downloadMedia, in: menu, title: "Save Video As…", action: #selector(saveMediaAs(_:)))
        remove(.openFrameInNewWindow, from: menu)

        // A selection: search with the app's engine, translate with Google.
        let selection = context.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            let quoted = Self.quoted(selection)
            if replace(.searchWeb, in: menu, title: "Search DuckDuckGo for “\(quoted)”", action: #selector(searchSelection(_:))) == nil,
               let copy = find(menu, .copy) {
                _ = add("Search DuckDuckGo for “\(quoted)”", #selector(searchSelection(_:)), after: copy, in: menu)
            }
            let title = "Translate “\(quoted)” to \(PageTranslator.target.name)"
            if replace(.translate, in: menu, title: title, action: #selector(translateSelection(_:))) == nil {
                let anchor = menu.items.first { $0.action == #selector(searchSelection(_:)) } ?? find(menu, .copy)
                _ = add(title, #selector(translateSelection(_:)), after: anchor, in: menu)
            }
        } else {
            remove(.searchWeb, from: menu)
            remove(.translate, from: menu)
        }

        // The page itself: what Chrome and Safari put under Reload.
        if isPage {
            let anchor = find(menu, .reload) ?? find(menu, .goForward) ?? find(menu, .goBack)
            var items: [NSMenuItem] = [.separator()]
            for (title, action) in [("Save Page As…", #selector(savePageAs(_:))), ("Print…", #selector(printPage(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                items.append(item)
            }
            items.append(.separator())
            items.append(contentsOf: TranslateMenu.items(for: translator, target: self, includeStatus: false))
            items.append(.separator())
            let source = NSMenuItem(title: "View Page Source", action: #selector(viewPageSource(_:)), keyEquivalent: "")
            source.target = self
            items.append(source)
            var index = anchor.flatMap { menu.items.firstIndex(of: $0) }.map { $0 + 1 } ?? menu.items.count
            for item in items {
                menu.insertItem(item, at: index)
                index += 1
            }
        }

        // Our DevTools, in place of the WebKit inspector, always last.
        remove(.inspectElement, from: menu)
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
        _ = add("Inspect Element", #selector(inspectElement(_:)), after: nil, in: menu)

        Self.tidySeparators(menu)
        lastTitles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        lastMenu = menu
        onMenuReady?(menu)
    }

    /// No separator first, last, or twice in a row.
    static func tidySeparators(_ menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = true }
            } else {
                previousWasSeparator = false
            }
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    static func quoted(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 30 ? String(flat.prefix(29)) + "…" : flat
    }

    // MARK: - Actions

    @objc func openLinkInNewWindow(_ sender: Any?) { context.link.map { openInNewWindow?($0) } }
    @objc func openLinkInNewTab(_ sender: Any?) { context.link.map { openInNewTab?($0) } }
    @objc func openImageInNewWindow(_ sender: Any?) { context.image.map { openInNewWindow?($0) } }
    @objc func openMediaInNewWindow(_ sender: Any?) { context.media.map { openInNewWindow?($0) } }

    @objc func saveLinkAs(_ sender: Any?) { context.link.map { downloads.download($0, askWhere: true) } }
    @objc func saveImageAs(_ sender: Any?) { context.image.map { downloads.download($0, askWhere: true) } }
    @objc func saveMediaAs(_ sender: Any?) { context.media.map { downloads.download($0, askWhere: true) } }

    @objc func copyImageAddress(_ sender: Any?) {
        guard let image = context.image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image as NSURL])
        NSPasteboard.general.setString(image.absoluteString, forType: .string)
    }

    @objc func searchSelection(_ sender: Any?) {
        let text = context.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always a search, even for something that looks like an address:
        // that is what the item says it does.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard !text.isEmpty, let query = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: AddressResolver.defaultSearchTemplate + query) else { return }
        openInNewWindow?(url)
    }

    @objc func translateSelection(_ sender: Any?) {
        let text = context.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let webView else { return }
        let point = lastPoint
        let target = PageTranslator.target
        let popover = SelectionTranslationPopover(original: text, target: target)
        popover.show(at: point, in: webView)
        Task { @MainActor in
            do {
                let result = try await translator.translateText(text, to: target)
                popover.showResult(result.text, from: result.detectedLanguage.flatMap(TranslationLanguage.matching))
            } catch {
                popover.showError(PageTranslator.describe(error))
            }
        }
    }

    @objc func savePageAs(_ sender: Any?) {
        guard let webView, let window = webView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.webArchive]
        panel.nameFieldStringValue = DownloadController.safeFileName(webView.title ?? webView.url?.host() ?? "Page") + ".webarchive"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            webView.createWebArchiveData { result in
                if case .success(let data) = result { try? data.write(to: url, options: .atomic) }
            }
        }
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView, let window = webView.window else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        // WebKit's print view has no size of its own until given one.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func viewPageSource(_ sender: Any?) { viewSource?() }

    @objc func inspectElement(_ sender: Any?) {
        guard let webView else { return }
        inspect?(webView.cssPoint(lastPoint))
    }

    // Translation, from the page's own menu.
    @objc func translatePageTo(_ sender: Any?) {
        guard let code = (sender as? NSMenuItem)?.representedObject as? String,
              let language = TranslationLanguage.matching(code) else { return }
        TranslateMenu.noteUsed(language)
        translator.translate(to: language)
    }
    @objc func showOriginalPage(_ sender: Any?) { translator.showOriginal() }
    @objc func toggleAlwaysTranslate(_ sender: Any?) {
        guard let code = (sender as? NSMenuItem)?.representedObject as? String else { return }
        TranslateActions.toggleAlwaysTranslate(code, translator: translator)
    }

    /// Where the pointer was, in the web view's coordinates.
    var lastPoint: CGPoint = .zero
}

/// Shared by every place the Translate menu appears.
@MainActor
enum TranslateActions {
    static func toggleAlwaysTranslate(_ code: String, translator: PageTranslator) {
        var always = BrowserSettings.alwaysTranslateLanguages
        if always.contains(code) {
            always.removeAll { $0 == code }
        } else {
            always.append(code)
            if !translator.isTranslated { translator.translate(to: PageTranslator.target) }
        }
        BrowserSettings.alwaysTranslateLanguages = always
    }
}

/// "Translate “…”" on a selection: the translation in a popover beside it.
@MainActor
final class SelectionTranslationPopover: NSObject {
    private let popover = NSPopover()
    private let label = NSTextField(wrappingLabelWithString: "Translating…")
    private let header = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private(set) var text = ""

    init(original: String, target: TranslationLanguage) {
        super.init()
        header.stringValue = "Google Translate → \(target.name)"
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 320
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        copyButton.controlSize = .small
        copyButton.isEnabled = false
        let stack = NSStackView(views: [header, label, copyButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.behavior = .transient
    }

    func show(at point: CGPoint, in view: NSView) {
        popover.show(relativeTo: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4), of: view, preferredEdge: .maxY)
    }

    func showResult(_ translation: String, from source: TranslationLanguage?) {
        text = translation
        label.stringValue = translation
        if let source { header.stringValue += " (from \(source.name))" }
        copyButton.isEnabled = true
    }

    func showError(_ message: String) {
        label.stringValue = message
        label.textColor = .systemRed
    }

    @objc private func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        popover.close()
    }
}
