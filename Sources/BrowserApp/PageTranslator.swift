import AppKit
import NaturalLanguage
import WebKit
import TranslateKit

/// Translates one web view's page through Google Translate, and puts the
/// original back: the Chrome feature, built in.
///
/// Nothing leaves the Mac until the person asks for a translation (or has
/// said "Always translate" for the page's language). Working out what
/// language a page is in happens on-device, with NaturalLanguage, from the
/// page's own declaration and a sample of its text.
@MainActor
final class PageTranslator: NSObject, WKScriptMessageHandler {
    static let worldName = "SimpleBrowserTranslate"
    static let handlerName = "translate"

    enum State: Equatable {
        case idle
        case translating(TranslationLanguage)
        case translated(TranslationLanguage)
        case failed(String)
    }

    private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?() } } }
    /// The page's language as a Google code, once known.
    private(set) var pageLanguage: TranslationLanguage? { didSet { if pageLanguage != oldValue { onStateChange?() } } }
    /// The page asked not to be translated (`translate="no"`, `<meta name=google content=notranslate>`).
    private(set) var optedOut = false

    weak var webView: WKWebView?
    var onStateChange: (() -> Void)?
    /// Replaced by the self-test with a stub; never the real service there.
    var translator = GoogleTranslator()
    let world = WKContentWorld.world(name: worldName)
    private(set) var installError: String?

    private weak var userContentController: WKUserContentController?
    /// Bumped by every navigation and every Show Original: a translation
    /// still in flight for an older page, or one the person undid, must not
    /// land on what is showing now.
    private var generation = 0
    private var moreWaiting = false

    // MARK: - Installation

    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        guard let url = AppResources.bundle.url(forResource: "translate-agent", withExtension: "js", subdirectory: "TranslateAgent"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            installError = "translate-agent.js is missing from the app's resources"
            return
        }
        controller.add(self, contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    func uninstall() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
    }

    func didCommitNavigation() {
        generation += 1
        moreWaiting = false
        state = .idle
        pageLanguage = nil
        optedOut = false
    }

    // MARK: - What to offer

    /// The language translations go into: the last one chosen, else the
    /// first of the person's preferred languages Google can do.
    static var target: TranslationLanguage {
        get { BrowserSettings.translateTarget.flatMap(TranslationLanguage.matching) ?? .preferred() }
        set { BrowserSettings.translateTarget = newValue.code }
    }

    /// Worth offering: the page is in some other language than the target.
    var suggestsTranslation: Bool {
        guard let pageLanguage, !optedOut else { return false }
        return pageLanguage.code != Self.target.code
    }

    var isTranslated: Bool {
        switch state {
        case .translated, .translating: return true
        default: return false
        }
    }

    // MARK: - Messages from the agent

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        switch body["kind"] as? String {
        case "language":
            optedOut = body["optedOut"] as? Bool ?? false
            pageLanguage = Self.detectLanguage(declared: body["declared"] as? String ?? "", sample: body["sample"] as? String ?? "")
            if let pageLanguage, suggestsTranslation, BrowserSettings.alwaysTranslateLanguages.contains(pageLanguage.code), state == .idle {
                translate(to: Self.target)
            }
        case "more":
            if case .translated(let target) = state { translateRest(to: target, generation: generation) }
            else if case .translating = state { moreWaiting = true }
        default:
            break
        }
    }

    /// Trusts what the text itself says over what the page declares when
    /// the two disagree clearly: templates ship `lang="en"` on every page.
    static func detectLanguage(declared: String, sample: String) -> TranslationLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let detected = recognizer.languageHypotheses(withMaximum: 3).max { $0.value < $1.value }
        let declaredLanguage = TranslationLanguage.matching(declared)
        if let detected, sample.count >= 40, detected.value > 0.8,
           let fromText = TranslationLanguage.matching(detected.key.rawValue) {
            if let declaredLanguage, declaredLanguage.code.hasPrefix("zh"), fromText.code.hasPrefix("zh") { return declaredLanguage }
            return fromText
        }
        return declaredLanguage ?? detected.flatMap { TranslationLanguage.matching($0.key.rawValue) }
    }

    // MARK: - Translating

    func translate(to target: TranslationLanguage) {
        Self.target = target
        if case .translated(let current) = state, current == target { return }
        if case .translating(let current) = state, current == target { return }
        let needsRestore = isTranslated
        generation += 1
        let generation = generation
        state = .translating(target)
        Task { @MainActor in
            if needsRestore { await restoreInPage() }
            guard generation == self.generation else { return }
            await translatePieces(to: target, generation: generation)
        }
    }

    func showOriginal() {
        generation += 1
        moreWaiting = false
        state = .idle
        Task { @MainActor in await restoreInPage() }
    }

    /// Content the page added after it was translated.
    private func translateRest(to target: TranslationLanguage, generation: Int) {
        state = .translating(target)
        Task { @MainActor in await translatePieces(to: target, generation: generation) }
    }

    private func translatePieces(to target: TranslationLanguage, generation: Int) async {
        let pieces = await collect(target)
        guard generation == self.generation else { return }
        // A small first request, so what is on screen changes quickly; the
        // rest follows in full-sized ones.
        let head = Array(pieces.prefix(15))
        let tail = Array(pieces.dropFirst(15))
        let chunks = [head] + GoogleTranslator.batches(tail.map(\.html)).reduce(into: [[(id: Int, html: String)]]()) { result, batch in
            let start = result.reduce(0) { $0 + $1.count }
            result.append(Array(tail[start..<start + batch.count]))
        }
        do {
            for chunk in chunks where !chunk.isEmpty {
                let translations = try await translator.translateBatch(chunk.map(\.html), to: target)
                guard generation == self.generation else { return }
                if pageLanguage == nil, let detected = GoogleTranslator.dominantLanguage(of: translations, sources: chunk.map(\.html)) {
                    pageLanguage = TranslationLanguage.matching(detected)
                }
                let results = zip(chunk, translations).map { ["id": $0.id, "html": $1.text] as [String: Any] }
                _ = try? await webView?.callAsyncJavaScript(
                    "return window.__sbTranslate ? window.__sbTranslate.apply(results) : 0",
                    arguments: ["results": results], in: nil, contentWorld: world)
            }
            guard generation == self.generation else { return }
            state = .translated(target)
            if moreWaiting {
                moreWaiting = false
                translateRest(to: target, generation: generation)
            }
        } catch {
            guard generation == self.generation else { return }
            state = .failed(Self.describe(error))
        }
    }

    private func collect(_ target: TranslationLanguage) async -> [(id: Int, html: String)] {
        let raw = try? await webView?.callAsyncJavaScript(
            "return window.__sbTranslate ? window.__sbTranslate.collect(target) : []",
            arguments: ["target": target.code], in: nil, contentWorld: world)
        return (raw as? [[String: Any]] ?? []).compactMap { piece in
            guard let id = (piece["id"] as? NSNumber)?.intValue, let html = piece["html"] as? String, !html.isEmpty else { return nil }
            return (id, html)
        }
    }

    private func restoreInPage() async {
        _ = try? await webView?.callAsyncJavaScript("if (window.__sbTranslate) window.__sbTranslate.restore()",
                                                   arguments: [:], in: nil, contentWorld: world)
    }

    /// For the self-test: how far the page's agent got.
    func agentState() async -> [String: Any]? {
        try? await webView?.callAsyncJavaScript("return window.__sbTranslate ? window.__sbTranslate.state() : null",
                                                arguments: [:], in: nil, contentWorld: world) as? [String: Any]
    }

    /// A few words, for "Translate “…”" on a selection.
    func translateText(_ text: String, to target: TranslationLanguage) async throws -> GoogleTranslator.Translation {
        let result = try await translator.translateBatch([text], to: target, html: false)
        guard let first = result.first else { throw GoogleTranslator.TranslatorError.unexpectedResponse }
        return first
    }

    static func describe(_ error: any Error) -> String {
        switch error as? GoogleTranslator.TranslatorError {
        case .rateLimited: return "Google Translate is limiting requests right now. Try again in a minute."
        case .http(let status): return "Google Translate answered with an error (\(status))."
        case .unexpectedResponse: return "Google Translate sent an answer this browser could not read."
        case nil:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return "Google Translate could not be reached. Check the connection." }
            return error.localizedDescription
        }
    }
}

/// The Translate menu, the same wherever it appears: the toolbar button, the
/// View menu's submenu and the page's context menu.
@MainActor
enum TranslateMenu {
    /// Most-used targets first, then everything by name.
    private static var recent: [String] {
        get { BrowserSettings.recentTranslateTargets }
        set { BrowserSettings.recentTranslateTargets = Array(newValue.prefix(5)) }
    }

    static func noteUsed(_ language: TranslationLanguage) {
        recent = [language.code] + recent.filter { $0 != language.code }
    }

    static func items(for translator: PageTranslator, target: AnyObject, includeStatus: Bool = true) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let goal = PageTranslator.target
        if includeStatus, let status = statusLine(for: translator) {
            let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)
        }
        switch translator.state {
        case .translated(let current), .translating(let current):
            if current != goal { items.append(item("Translate to \(goal.name)", #selector(BrowserWindowController.translatePageTo(_:)), goal, target)) }
            items.append(item("Show Original", #selector(BrowserWindowController.showOriginalPage(_:)), nil, target))
        default:
            let translate = item("Translate to \(goal.name)", #selector(BrowserWindowController.translatePageTo(_:)), goal, target)
            translate.isEnabled = !translator.optedOut
            items.append(translate)
        }

        let submenu = NSMenu(title: "Translate To")
        let recentLanguages = recent.compactMap(TranslationLanguage.matching)
        for language in recentLanguages {
            submenu.addItem(item(language.name, #selector(BrowserWindowController.translatePageTo(_:)), language, target))
        }
        if !recentLanguages.isEmpty { submenu.addItem(.separator()) }
        for language in TranslationLanguage.all.sorted(by: { $0.name.localizedCompare($1.name) == .orderedAscending }) {
            let entry = item(language.name, #selector(BrowserWindowController.translatePageTo(_:)), language, target)
            if case .translated(let current) = translator.state, current == language { entry.state = .on }
            submenu.addItem(entry)
        }
        let more = NSMenuItem(title: "Translate To", action: nil, keyEquivalent: "")
        more.submenu = submenu
        items.append(more)

        if let language = translator.pageLanguage, language != goal {
            let always = item("Always Translate \(language.name)", #selector(BrowserWindowController.toggleAlwaysTranslate(_:)), language, target)
            always.state = BrowserSettings.alwaysTranslateLanguages.contains(language.code) ? .on : .off
            items.append(.separator())
            items.append(always)
        }
        return items
    }

    static func statusLine(for translator: PageTranslator) -> String? {
        let page = translator.pageLanguage?.name
        switch translator.state {
        case .translating(let target): return "Translating to \(target.name)…"
        case .translated(let target): return page.map { "Translated from \($0) to \(target.name)" } ?? "Translated to \(target.name)"
        case .failed(let message): return message
        case .idle:
            if translator.optedOut { return "This page asks not to be translated" }
            return page.map { "This page is in \($0)" }
        }
    }

    private static func item(_ title: String, _ action: Selector, _ language: TranslationLanguage?, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = language?.code
        return item
    }
}
