import AppKit
import WebKit
import TranslateKit

/// Developer aid (`--page-selftest <file>`, run by `scripts/test-page.sh`):
/// translation, the right-click menu and downloads, against the fixture site
/// in `Tests/Fixtures/page`.
///
/// Google is never called: the translator is given a stub that upper-cases
/// the text and leaves the markup alone, which makes every translated word
/// easy to spot and every untouched one too. Right-clicks are real mouse
/// events sent to the window, so WebKit builds its own menu, the page gets
/// its `contextmenu` event, and the menu that opens is the one a person sees.
@MainActor
enum PageSelfTest {

    /// The titles of the menu a right-click opened, once it has.
    @MainActor final class Shown { var titles: [String]? }

    final class StubLog: @unchecked Sendable {
        var requests = 0
        var failWith: Int?
    }

    /// Upper-cases the text between tags; entities keep their case.
    nonisolated static func shout(_ html: String) -> String {
        var out = ""
        var inTag = false, inEntity = false
        for c in html {
            if c == "<" { inTag = true } else if c == ">" { inTag = false; out.append(c); continue }
            if !inTag && c == "&" { inEntity = true }
            out += inTag || inEntity ? String(c) : c.uppercased()
            if inEntity && c == ";" { inEntity = false }
        }
        return out
    }

    static func run(app: AppDelegate, browser: BrowserWindowController, output: String, snapshots: String?) {
        Task { @MainActor in
            var failures: [String] = []
            var environment: [String] = []
            var passed = 0
            func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
                if ok { passed += 1 } else { failures.append(detail.map { "\(name): \($0)" } ?? name) }
            }
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func waitFor(_ seconds: Double = 6, _ condition: () async -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if await condition() { return true }
                    await pause(0.1)
                }
                return await condition()
            }
            @MainActor func snapshot(_ window: NSWindow?, _ name: String) {
                guard let snapshots, let window else { return }
                window.displayIfNeeded()
                AppDelegate.snapshot(window, to: snapshots + "/" + name + ".png")
            }

            let site = "http://127.0.0.1:8767"
            let translator = browser.translator
            let menu = browser.contextMenu

            let suite = "SimpleBrowser.page-selftest"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let scratch = UserDefaults(suiteName: suite) { BrowserSettings.store = scratch }
            BrowserSettings.translateTarget = "en"
            check("the self-test has its own settings suite", BrowserSettings.store !== UserDefaults.standard)
            check("the translate agent was installed", translator.installError == nil, translator.installError)
            check("the page menu agent was installed", menu.installError == nil, menu.installError)

            let log = StubLog()
            translator.translator = GoogleTranslator { request in
                log.requests += 1
                if let status = log.failWith {
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let segments = body.split(separator: "&").map { String($0.dropFirst(2)).removingPercentEncoding ?? "" }
                let pairs = segments.map { [shout($0), "fr"] }
                let data = try JSONSerialization.data(withJSONObject: pairs)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBrowser-page-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            browser.downloads.downloadsDirectory = scratch
            browser.downloads.chooseDestination = { name in scratch.appendingPathComponent("chosen-" + name) }
            var opened: [URL] = []
            browser.openInNewWindow = { opened.append($0) }

            @MainActor func js(_ script: String) async -> Any? { try? await browser.evaluateInPage(script) }
            @MainActor func text(_ id: String) async -> String { await js("return document.getElementById('\(id)').textContent") as? String ?? "<missing>" }
            @MainActor func open(_ path: String) async {
                browser.load(URL(string: site + path)!)
                _ = await waitFor {
                    guard browser.currentURL?.absoluteString == site + path else { return false }
                    return (await js("return document.readyState") as? String) == "complete"
                }
                await pause(0.6)
            }

            // MARK: 1. Language, found on the Mac

            await open("/")
            check("1. the page's language is known", await waitFor { translator.pageLanguage?.code == "fr" }, translator.pageLanguage?.code as Any)
            check("1. a French page is offered translation into English", translator.suggestsTranslation)
            check("1. nothing was sent to Google just by loading", log.requests == 0, log.requests)
            snapshot(browser.window, "1-french-page")

            // MARK: 2. Translating

            let original = await js("return document.body.innerHTML") as? String ?? ""
            translator.translate(to: TranslationLanguage(code: "en"))
            check("2. the page is translated", await waitFor { translator.state == .translated(TranslationLanguage(code: "en")) }, translator.state)
            check("2. headings", await text("title") == "BONJOUR TOUT LE MONDE", await text("title"))
            check("2. a sentence with markup inside it", (await text("intro")).hasPrefix("CECI EST UN ARTICLE IMPORTANT SUR LA CUISINE FRANÇAISE"), await text("intro"))
            check("2. the link is the page's own element, not a copy", await js("return document.getElementById('link') === window.linkRef") as? Bool == true)
            check("2. …translated", await text("link") == "LIEN VERS LA RECETTE", await text("link"))
            _ = await js("document.getElementById('link').click()")
            check("2. …and its click handler still runs", await js("return window.clicked") as? Bool == true)
            check("2. code stays as written", await text("code") == "let x = 1", await text("code"))
            check("2. translate=no / notranslate is respected", await text("brand") == "Maison Dupont", await text("brand"))
            check("2. preformatted text is left alone", await text("pre") == "if (a) { b(); }", await text("pre"))
            check("2. list items", await text("list") == "PREMIER ÉLÉMENT DE LA LISTEDEUXIÈME ÉLÉMENT DE LA LISTE", await text("list"))
            check("2. placeholders", await js("return document.getElementById('search').placeholder") as? String == "RECHERCHER UNE RECETTE")
            check("2. button labels", await js("return document.getElementById('send').value") as? String == "ENVOYER MAINTENANT")
            check("2. alt text", await js("return document.getElementById('image').alt") as? String == "UNE PHOTO DU PLAT")
            check("2. the image is still there", await js("return !!document.getElementById('image')") as? Bool == true)
            check("2. the page's own script cannot see the translator", await js("return typeof window.__sbTranslate") as? String == "undefined")
            snapshot(browser.window, "2-translated")

            // MARK: 3. Show Original

            translator.showOriginal()
            check("3. Show Original puts back exactly what was there",
                  await waitFor { (await js("return document.body.innerHTML") as? String) == original },
                  (await js("return document.body.innerHTML") as? String)?.prefix(200) as Any)
            check("3. …and the state says so", translator.state == .idle)
            check("3. the link is still the same element", await js("return document.getElementById('link') === window.linkRef") as? Bool == true)

            // MARK: 4. Content that arrives later

            translator.translate(to: TranslationLanguage(code: "en"))
            _ = await waitFor { translator.state == .translated(TranslationLanguage(code: "en")) }
            _ = await js("document.getElementById('more').click()")
            check("4. a paragraph added after translating is translated too",
                  await waitFor { await text("added") == "UN NOUVEAU PARAGRAPHE ARRIVE PLUS TARD" }, await text("added"))
            translator.showOriginal()
            check("4. …and goes back with the rest", await waitFor { await text("added") == "Un nouveau paragraphe arrive plus tard" }, await text("added"))

            // MARK: 5. The toolbar menu

            browser.showTranslateMenuForTest()
            let titles = browser.lastTranslateMenuTitles
            check("5. the Translate button says what the page is in", titles.first == "This page is in French", titles)
            check("5. …and offers English", titles.contains("Translate to English"), titles)
            check("5. …and any other language", titles.contains("Translate To"), titles)
            check("5. …and to always translate French", titles.contains("Always Translate French"), titles)

            // MARK: 6. A failure says what happened

            log.failWith = 429
            translator.translate(to: TranslationLanguage(code: "de"))
            check("6. rate limiting is reported, not swallowed", await waitFor {
                if case .failed(let message) = translator.state { return message.contains("limiting") } else { return false }
            }, translator.state)
            log.failWith = nil
            translator.showOriginal()
            // Choosing German made it the target, as it does in Chrome.
            check("6. a language chosen once becomes the target", PageTranslator.target.code == "de")
            BrowserSettings.translateTarget = "en"

            // MARK: 7. Pages that ask not to be, and pages already in English

            await open("/optout")
            _ = await waitFor { translator.pageLanguage != nil }
            check("7. a page with <meta name=google content=notranslate> is not offered", translator.optedOut && !translator.suggestsTranslation)
            await open("/en")
            _ = await waitFor { translator.pageLanguage != nil }
            check("7. an English page is not offered English", translator.pageLanguage?.code == "en" && !translator.suggestsTranslation, translator.pageLanguage?.code as Any)

            // MARK: 8. Always translate French

            BrowserSettings.alwaysTranslateLanguages = ["fr"]
            let before = log.requests
            await open("/")
            check("8. a French page translates itself", await waitFor { await text("title") == "BONJOUR TOUT LE MONDE" }, await text("title"))
            check("8. …by asking Google", log.requests > before)
            BrowserSettings.alwaysTranslateLanguages = []
            translator.showOriginal()
            _ = await waitFor { await text("title") == "Bonjour tout le monde" }

            // MARK: 9. The right-click menu

            /// A real right mouse button press on the element, then the
            /// menu's titles once it has opened, closed again at once.
            @MainActor func rightClick(_ id: String, step: String) async -> [String]? {
                guard let rect = await js("const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.left + Math.min(8, r.width / 2), r.top + r.height / 2]") as? [NSNumber],
                      rect.count == 2, let window = browser.window, let webView = browser.pageView else { return nil }
                let zoom = webView.pageZoom
                var point = NSPoint(x: rect[0].doubleValue * zoom, y: rect[1].doubleValue * zoom)
                if !webView.isFlipped { point.y = webView.bounds.height - point.y }
                let inWindow = webView.convert(point, to: nil)
                let shown = Shown()
                menu.onMenuReady = { opened in
                    shown.titles = menu.lastTitles
                    DispatchQueue.main.async { opened.cancelTrackingWithoutAnimation() }
                }
                defer { menu.onMenuReady = nil }
                for _ in 0..<3 {
                    QuietMode.activate()
                    window.makeKeyAndOrderFront(nil)
                    guard let down = NSEvent.mouseEvent(with: .rightMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                          let up = NSEvent.mouseEvent(with: .rightMouseUp, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return nil }
                    window.sendEvent(down)
                    window.sendEvent(up)
                    if await waitFor(3, { shown.titles != nil }) { return shown.titles }
                }
                environment.append("\(step): the context menu did not open for a synthesized right-click")
                return nil
            }
            @MainActor func choose(_ title: String) -> Bool {
                guard let item = menu.lastMenu?.items.first(where: { $0.title == title }), let action = item.action else { return false }
                return NSApp.sendAction(action, to: item.target, from: item)
            }

            if let titles = await rightClick("link", step: "9. link") {
                check("9. a link: Open Link, in a new window, Save Link As…, Copy Link",
                      ["Open Link", "Open Link in New Window", "Save Link As…", "Copy Link"].allSatisfy(titles.contains), titles)
                check("9. …WebKit's download item is replaced, not duplicated", !titles.contains("Download Linked File"), titles)
                check("9. …Inspect Element last", titles.last == "Inspect Element", titles)
                check("9. …the agent saw which link", menu.context.link?.absoluteString == site + "/recette", menu.context.link as Any)
                opened = []
                check("9. Open Link in New Window runs", choose("Open Link in New Window"))
                check("9. …and opens that link", opened == [URL(string: site + "/recette")!], opened)
            }

            if let titles = await rightClick("image", step: "9. image") {
                check("9. an image: open, save, copy, copy address",
                      ["Open Image in New Window", "Save Image As…", "Copy Image", "Copy Image Address"].allSatisfy(titles.contains), titles)
                check("9. …WebKit's download item is replaced", !titles.contains("Download Image"), titles)
                check("9. Save Image As… runs", choose("Save Image As…"))
                let saved = scratch.appendingPathComponent("chosen-pixel.png")
                check("9. …and saves the image where chosen", await waitFor(8) { browser.downloads.finished.contains(saved) },
                      browser.downloads.finished.map(\.lastPathComponent) + browser.downloads.failures)
                let bytes = (try? Data(contentsOf: saved))?.prefix(4)
                check("9. …as the PNG the page showed", bytes == Data([0x89, 0x50, 0x4E, 0x47]))
            }

            // Empty space: a right-click on words selects the word under it,
            // as everywhere on macOS, and that is the selection's menu.
            if let titles = await rightClick("blank", step: "9. page") {
                for expected in ["Reload", "Save Page As…", "Print…", "Translate to English", "Translate To", "View Page Source", "Inspect Element"] {
                    check("9. the page menu has \(expected)", titles.contains(expected), titles)
                }
                check("9. …in Safari's order: Reload before Save Page As…",
                      (titles.firstIndex(of: "Reload") ?? .max) < (titles.firstIndex(of: "Save Page As…") ?? -1), titles)
                check("9. …with no empty groups", !titles.enumerated().contains { $0.element == "—" && ($0.offset == 0 || titles[$0.offset - 1] == "—") } && titles.last != "—", titles)
                check("9. Translate to English from the menu runs", choose("Translate to English"))
                check("9. …and translates", await waitFor { await text("title") == "BONJOUR TOUT LE MONDE" })
                translator.showOriginal()
                _ = await waitFor { await text("title") == "Bonjour tout le monde" }
            }

            _ = await js("const r = document.createRange(); r.selectNodeContents(document.getElementById('select-me')); getSelection().removeAllRanges(); getSelection().addRange(r);")
            if let titles = await rightClick("select-me", step: "9. selection") {
                check("9. a selection: Copy", titles.contains("Copy"), titles)
                check("9. …search with the browser's engine, not Safari's", titles.contains("Search DuckDuckGo for “Fromage”") && !titles.contains { $0.hasPrefix("Search With") }, titles)
                check("9. …translate the selection", titles.contains("Translate “Fromage” to English"), titles)
                opened = []
                check("9. Search runs", choose("Search DuckDuckGo for “Fromage”"))
                check("9. …in a new window, searching for it", opened.first?.absoluteString == "https://duckduckgo.com/?q=Fromage", opened)
            }
            snapshot(browser.window, "9-after-menus")

            // MARK: 10. A file the page hands over goes to Downloads

            await open("/")
            _ = await js("document.getElementById('file').click()")
            let zip = scratch.appendingPathComponent("rapport.zip")
            check("10. an attachment downloads to the Downloads folder, under its own name",
                  await waitFor(8) { browser.downloads.finished.contains(zip) }, browser.downloads.finished.map(\.lastPathComponent) + browser.downloads.failures)
            check("10. …and the page stays where it was", browser.currentURL?.absoluteString == site + "/")

            UserDefaults.standard.removePersistentDomain(forName: suite)
            let report: [String: Any] = [
                "passed": failures.isEmpty && environment.isEmpty,
                "checksPassed": passed,
                "failures": failures,
                "environment": environment,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }
}
