import AppKit
import WebKit
import BrowserKit
import TranslateKit

/// #9 Find in page, zoom and Reader.
extension FeatureSelfTest {

    func find() async {
        let browser = first
        browser.window?.makeKeyAndOrderFront(nil)
        await open("/find", in: browser)
        let finder = browser.finder
        check("find: WebKit's own find is there, for counts and frames", finder.usesPrivateFind)

        browser.findInPage(nil)
        check("find: ⌘F opens the bar over the page", await waitFor { finder.isVisible && finder.bar.superview != nil })
        finder.field.stringValue = "needle"
        finder.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: finder.field))
        check("find: every match is counted, in the frame too, whatever its case", await waitFor { finder.matchCount == 7 }, finder.matchCount as Any)
        check("find: …and the first one is where it starts", await waitFor { finder.status == "1 of 7" }, finder.status)
        snapshot(browser.window, "find-bar")

        browser.findNextInPage(nil)
        check("find: ⌘G goes to the next", await waitFor { finder.status == "2 of 7" }, finder.status)
        browser.findNextInPage(nil)
        check("find: …scrolling to a match far down the page", await waitFor { finder.status == "3 of 7" }, finder.status)
        let scrolled = await waitFor { ((await self.js("return window.scrollY", in: browser) as? NSNumber)?.doubleValue ?? 0) > 500 }
        check("find: …which the page scrolled to", scrolled, await js("return window.scrollY", in: browser) as Any)
        for _ in 0..<3 { browser.findNextInPage(nil); await pause(0.15) }
        check("find: matches inside a frame are reached", await waitFor { finder.status == "6 of 7" }, finder.status)
        let inFrame = await js("return document.getElementById('frame').contentWindow.getSelection().toString().toLowerCase()", in: browser) as? String
        check("find: …and selected there", inFrame == "needle", inFrame as Any)
        browser.findNextInPage(nil)
        await pause(0.15)
        browser.findNextInPage(nil)
        check("find: after the last it wraps to the first", await waitFor { finder.status == "1 of 7" }, finder.status)
        browser.findPreviousInPage(nil)
        check("find: ⇧⌘G goes back, wrapping to the last", await waitFor { finder.status == "7 of 7" }, finder.status)

        finder.field.stringValue = "haystack"
        finder.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: finder.field))
        check("find: what is not there is said not to be", await waitFor { finder.status == "Not found" }, finder.status)
        check("find: …with nothing to step through", !finder.nextButton.isEnabled && !finder.previousButton.isEnabled)

        // The bar follows to the next page.
        finder.field.stringValue = "paragraph"
        finder.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: finder.field))
        _ = await waitFor { finder.matchCount == 1 }
        await open("/long", in: browser)
        check("find: on a new page the bar stays and looks again", await waitFor { finder.isVisible && finder.matchCount == 200 }, finder.status)

        if let editor = finder.field.currentEditor() as? NSTextView {
            _ = finder.control(finder.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        } else {
            finder.hide()
        }
        check("find: Escape closes the bar", !finder.isVisible && finder.bar.superview == nil)

        // ⌘E, then ⌘G.
        await open("/find", in: browser)
        _ = await js("const range = document.createRange(); range.selectNodeContents(document.getElementById('far')); const s = getSelection(); s.removeAllRanges(); s.addRange(range); s.collapseToStart(); s.modify('extend', 'forward', 'word'); s.modify('extend', 'forward', 'word')", in: browser)
        browser.useSelectionForFind(nil)
        check("find: ⌘E takes the selection", await waitFor { finder.lastQuery == "Far down" }, finder.lastQuery)
        check("find: …without opening the bar", !finder.isVisible)
        browser.findNextInPage(nil)
        check("find: ⌘G then looks for it", await waitFor { finder.isVisible && finder.field.stringValue == "Far down" && finder.matchCount == 1 }, finder.status)
        finder.hide()
    }

    func zoom() async {
        let browser = first
        let profile = browser.profile.id.description
        browser.window?.makeKeyAndOrderFront(nil)
        await open("/second", in: browser)
        check("zoom: a page starts at its actual size, with no indicator", browser.zoom == 1 && browser.zoomIndicator.isEmpty)

        browser.zoomIn(nil)
        browser.zoomIn(nil)
        check("zoom: ⌘+ twice is 125%", abs(browser.zoom - 1.25) < 0.001 && browser.zoomIndicator == "125%", browser.zoomIndicator)
        let width = (await js("return window.innerWidth", in: browser) as? NSNumber)?.doubleValue ?? 0
        check("zoom: the page is laid out for the zoom, not just magnified", width > 0 && width < Double(browser.pageWebView.bounds.width) * 0.85, width)
        check("zoom: it is remembered for the site", BrowserSettings.zoomLevels(profile: profile) == ["127.0.0.1": 1.25], BrowserSettings.zoomLevels(profile: profile))
        snapshot(browser.window, "zoom-indicator")
        browser.window?.layoutIfNeeded()
        check("zoom: with the indicator showing, every toolbar button still fits", browser.overflowingToolbarItems.isEmpty, browser.overflowingToolbarItems)
        if let window = browser.window {
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 900, height: frame.height), display: true)
            await pause(0.3)
            check("zoom: in a narrow window the address gives way, not the buttons", browser.overflowingToolbarItems.isEmpty, browser.overflowingToolbarItems)
            window.setFrame(frame, display: true)
            await pause(0.2)
        }

        await open("/long", in: browser)
        check("zoom: another page of the site has it too", abs(browser.zoom - 1.25) < 0.001)
        browser.load(URL(string: "http://localhost:8767/second")!)
        _ = await waitFor { browser.currentURL?.host() == "localhost" && !browser.pageWebView.isLoading }
        check("zoom: another site does not", await waitFor { browser.zoom == 1 && browser.zoomIndicator.isEmpty }, browser.zoom)
        browser.zoomOut(nil)
        check("zoom: ⌘− there is 90%", abs(browser.zoom - 0.9) < 0.001 && browser.zoomIndicator == "90%", browser.zoomIndicator)
        await open("/second", in: browser)
        check("zoom: back on the first site, its own level is back", await waitFor { abs(browser.zoom - 1.25) < 0.001 }, browser.zoom)

        let other = app.newTab(beside: browser, url: URL(string: site + "/long"))
        _ = await waitFor { !other.pageWebView.isLoading && other.currentURL?.path == "/long" }
        check("zoom: a new tab on the site opens at the site's level", await waitFor { abs(other.zoom - 1.25) < 0.001 }, other.zoom)
        other.zoomIn(nil)
        check("zoom: changing it in one tab changes the site's other tabs", await waitFor { abs(browser.zoom - 1.5) < 0.001 }, browser.zoom)
        other.window?.close()
        browser.window?.makeKeyAndOrderFront(nil)

        let item = NSMenuItem(title: "Actual Size", action: #selector(BrowserWindowController.zoomReset(_:)), keyEquivalent: "0")
        check("zoom: Actual Size is offered while zoomed", browser.validateMenuItem(item))
        browser.zoomReset(nil)
        check("zoom: ⌘0 is actual size again, and forgotten", browser.zoom == 1 && browser.zoomIndicator.isEmpty
              && BrowserSettings.zoomLevels(profile: profile) == ["localhost": 0.9], BrowserSettings.zoomLevels(profile: profile))
        check("zoom: …and Actual Size is no longer offered", !browser.validateMenuItem(item))
        for _ in 0..<30 { browser.zoomIn(nil) }
        check("zoom: it stops at 500%", abs(browser.zoom - 5) < 0.001 && !browser.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "")))
        browser.zoomReset(nil)

        let view = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "View" }
        check("zoom: the View menu has the three, with Chrome's and Safari's keys",
              view?.items.filter { !$0.isHidden }.compactMap { item in ["Actual Size", "Zoom In", "Zoom Out"].contains(item.title) ? item.title + " ⌘" + item.keyEquivalent : nil }
              == ["Actual Size ⌘0", "Zoom In ⌘+", "Zoom Out ⌘-"], view?.items.map(\.title))
        check("zoom: ⌘= zooms in too", view?.items.contains { $0.isHidden && $0.keyEquivalent == "=" && $0.action == #selector(BrowserWindowController.zoomIn(_:)) } == true)
        BrowserSettings.setZoomLevels([:], profile: profile)
    }
}

extension FeatureSelfTest {

    func reader() async {
        let browser = first
        let reader = browser.reader
        browser.window?.makeKeyAndOrderFront(nil)
        BrowserSettings.readerAppearance = ReaderAppearance()
        check("reader: the agent was installed", reader.installError == nil, reader.installError)

        func text(_ selector: String) async -> String? {
            await js("const el = document.querySelector('\(selector)'); return el ? el.textContent.replace(/\\\\s+/g, ' ').trim() : null", in: browser) as? String
        }
        func exists(_ selector: String) async -> Bool { (await js("return !!document.querySelector('\(selector)')", in: browser) as? Bool) ?? false }
        func style(_ property: String, of selector: String = "body") async -> String {
            (await js("return getComputedStyle(document.querySelector('\(selector)')).\(property)", in: browser) as? String) ?? ""
        }
        let showReader = NSMenuItem(title: "Show Reader", action: #selector(BrowserWindowController.toggleReader(_:)), keyEquivalent: "r")

        // Offered, or not.
        await open("/webapp", in: browser)
        await pause(0.8)
        check("reader: a web app is not offered Reader", !reader.isAvailable && !browser.validateMenuItem(showReader))
        check("reader: …and has no button", browser.toolbarItemIsHidden("reader") && browser.toolbarItemIsHidden("readerAppearance"))
        await open("/", in: browser)
        await pause(0.8)
        check("reader: nor is a page of short paragraphs", !reader.isAvailable)
        await open("/article", in: browser)
        check("reader: an article is", await waitFor { reader.isAvailable }, reader.isAvailable)
        check("reader: …with a button beside the address, and View → Show Reader", !browser.toolbarItemIsHidden("reader") && browser.validateMenuItem(showReader) && showReader.title == "Show Reader")
        check("reader: the appearance button waits until Reader is showing", browser.toolbarItemIsHidden("readerAppearance"))
        snapshot(browser.window, "reader-offered")

        // Into Reader.
        _ = await js("window.scrollTo(0, 300)", in: browser)
        check("reader: (setup) the article is scrolled", ((await js("return window.scrollY", in: browser) as? NSNumber)?.doubleValue ?? 0) > 250)
        browser.toggleReader(nil)
        check("reader: ⇧⌘R shows the article alone", await waitFor {
            guard reader.isActive, !browser.pageWebView.isLoading else { return false }
            return await exists("#reader-article")
        })
        check("reader: the address bar still names the article's site", browser.addressText == "127.0.0.1" && browser.currentURL?.absoluteString == site + "/article", browser.addressText)
        check("reader: the title is the headline, without the site's name", await text("#reader-title") == "The light nobody owned", await text("#reader-title") as Any)
        check("reader: …and is not repeated in the article", !(await exists("#reader-article h1")))
        let details = await text("#reader-details") ?? ""
        check("reader: who wrote it, when, and how long it takes", details.hasPrefix("Marta Oyelaran · ") && details.hasSuffix(" · 1 min read") && details.contains("2026"), details)
        check("reader: the site is named", await text(".site") == "The Harbour Gazette", await text(".site") as Any)
        let body = await text("#reader-article") ?? ""
        check("reader: every paragraph of the article is there", body.contains("dark for eleven years") && body.contains("a great deal of grease")
              && body.contains("owned by somebody") && body.contains("belonged, in the most literal sense") && body.contains("longest night of the year"), body.prefix(200))
        check("reader: the author's line is not repeated in the article", !body.contains("By Marta Oyelaran"), body.prefix(80))
        check("reader: the subheading is there", await text("#reader-article h2") == "A question of ownership")
        check("reader: …and the quotation", await exists("#reader-article blockquote"))
        for (what, needle) in [("the navigation", "Weather"), ("the share bar", "Share on X"), ("the advertisement", "boat insurance"), ("the newsletter form", "Sign up"),
                               ("the comments", "First!"), ("the sidebar", "Most read"), ("the footer", "All rights reserved"), ("text hidden on the page", "only machines")] {
            check("reader: \(what) is left out", !body.contains(needle))
        }
        check("reader: no script, frame, form or button came along", !(await exists("#reader-article script, #reader-article iframe, #reader-article form, #reader-article button, #reader-article input")))
        let handlers = await js("return Array.from(document.querySelectorAll('#reader-article *')).flatMap(el => Array.from(el.attributes).map(a => a.name)).filter(n => n.startsWith('on') || n === 'style' || n === 'class' || n === 'id')", in: browser) as? [String]
        check("reader: no handler, style, class or id attribute either", handlers == [], handlers as Any)
        check("reader: the page's scripts did not run in Reader", (await js("return [window.adRan, window.shared, window.clickedParagraph].every(v => v === undefined)", in: browser) as? Bool) == true)
        let links = await js("return Array.from(document.querySelectorAll('#reader-article a')).map(a => a.getAttribute('href'))", in: browser) as? [Any]
        check("reader: a relative link is made whole; a javascript: link loses its address",
              links?.contains { ($0 as? String) == site + "/harbour/history" } == true && links?.contains { (($0 as? String) ?? "").hasPrefix("javascript") } == false, links as Any)
        let image = await js("const img = document.querySelector('#reader-article img'); return img ? [img.getAttribute('src'), img.alt, String(document.querySelectorAll('#reader-article img').length)] : null", in: browser) as? [String]
        check("reader: a lazy image is shown from its real address; the tracking pixel is not shown", image == [site + "/pixel.png", "The lighthouse at dusk", "1"], image as Any)
        check("reader: …and it loaded", await waitFor { (await self.js("return document.querySelector('#reader-article img').naturalWidth > 0", in: browser) as? Bool) == true })
        check("reader: the caption stays with it", await text("#reader-article figcaption") == "The lighthouse at dusk, before the lamp was mended.")
        let policy = await js("return document.querySelector('meta[http-equiv=Content-Security-Policy]').content", in: browser) as? String
        check("reader: the page forbids script", policy?.contains("default-src 'none'") == true)
        _ = await js("const s = document.createElement('script'); s.textContent = 'window.injected = true'; document.body.appendChild(s)", in: browser)
        check("reader: …and the policy holds: a script put into the page does not run", (await js("return window.injected === undefined", in: browser) as? Bool) == true)
        check("reader: the button now hides Reader, and the appearance button is there", !browser.toolbarItemIsHidden("reader") && !browser.toolbarItemIsHidden("readerAppearance")
              && browser.validateMenuItem(showReader) && showReader.title == "Hide Reader", showReader.title)
        check("reader: every toolbar button still fits", browser.overflowingToolbarItems.isEmpty, browser.overflowingToolbarItems)
        check("reader: Reader is not offered on Reader", !reader.isAvailable || reader.isActive)
        check("reader: the star is for the article", browser.currentURL?.absoluteString == site + "/article")
        snapshot(browser.window, "reader-showing")

        // How it looks.
        check("reader: it starts at 19 points", await style("fontSize") == "19px", await style("fontSize"))
        check("reader: …in New York", (await style("fontFamily")).contains("ui-serif"), await style("fontFamily"))
        reader.showAppearance(nil)
        check("reader: the appearance popover opens", await waitFor { reader.appearanceController?.isViewLoaded == true })
        if let look = reader.appearanceController {
            snapshot(look.view.window, "reader-appearance")
            look.larger.performClick(nil)
            look.larger.performClick(nil)
            check("reader: larger text, at once", await waitFor { (await style("fontSize")) == "22px" }, await style("fontSize"))
            check("reader: …and the popover says so", look.sizeLabel.stringValue == "22 pt")
            look.themes.selectedSegment = 2
            look.themes.performClick(nil)
            check("reader: sepia", await waitFor { (await style("backgroundColor", of: "html")) == "rgb(248, 241, 227)" }, await style("backgroundColor", of: "html"))
            look.themes.selectedSegment = 3
            look.themes.performClick(nil)
            check("reader: dark", await waitFor { (await style("backgroundColor", of: "html")) == "rgb(28, 28, 30)" }, await style("backgroundColor", of: "html"))
            look.fonts.selectItem(at: 1)
            look.fonts.performClick(nil)
            _ = look.fonts.target?.perform(look.fonts.action, with: look.fonts)
            check("reader: another font", await waitFor { (await style("fontFamily")).contains("ui-sans-serif") }, await style("fontFamily"))
            let medium = await style("maxWidth")
            look.widths.selectedSegment = 2
            look.widths.performClick(nil)
            check("reader: wider", await waitFor { (await style("maxWidth")) != medium }, await style("maxWidth"))
            snapshot(browser.window, "reader-dark")
        }
        reader.popover?.close()
        check("reader: the look is remembered", BrowserSettings.readerAppearance.size == 22 && BrowserSettings.readerAppearance.theme == .dark
              && BrowserSettings.readerAppearance.font == .sanFrancisco && BrowserSettings.readerAppearance.width == .wide, BrowserSettings.readerAppearance)

        // Translation in Reader.
        browser.translator.translator = GoogleTranslator { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let segments = body.split(separator: "&").map { String($0.dropFirst(2)).removingPercentEncoding ?? "" }
            let data = try JSONSerialization.data(withJSONObject: segments.map { [$0.uppercased(), "en"] })
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        browser.translator.translate(to: TranslationLanguage(code: "fr"))
        check("reader: translation works in Reader", await waitFor { (await text("#reader-title")) == "THE LIGHT NOBODY OWNED" }, await text("#reader-title") as Any)
        check("reader: …on the article as well as its title", (await text("#reader-article blockquote")) == "THERE WAS NO ONE TO SAY THAT SHE COULD NOT MEND IT.", await text("#reader-article blockquote") as Any)
        check("reader: …but not on the site's name", await text(".site") == "The Harbour Gazette")
        browser.translator.showOriginal()

        // Reloading, and leaving.
        browser.reload(nil)
        check("reader: reloading stays in Reader, in the look chosen", await waitFor {
            guard reader.isActive, !browser.pageWebView.isLoading else { return false }
            return await style("fontSize") == "22px"
        })
        browser.toggleReader(nil)
        check("reader: ⇧⌘R again is the page itself", await waitFor { !reader.isActive && browser.pageWebView.url?.absoluteString == self.site + "/article" && !browser.pageWebView.isLoading })
        check("reader: …where it had been scrolled to", await waitFor { ((await self.js("return window.scrollY", in: browser) as? NSNumber)?.doubleValue ?? 0) > 250 }, await js("return window.scrollY", in: browser) as Any)
        check("reader: …and Reader is offered again", await waitFor { reader.isAvailable })
        check("reader: going into Reader did not add a second way back", browser.pageWebView.backForwardList.backItem?.url.path != "/article", browser.pageWebView.backForwardList.backItem?.url as Any)

        // A link in Reader goes to the web.
        browser.toggleReader(nil)
        _ = await waitFor { reader.isActive && !browser.pageWebView.isLoading }
        _ = await js("document.querySelector('#reader-article a[href$=\"/harbour/history\"]').click()", in: browser)
        check("reader: following a link leaves Reader for the page linked", await waitFor { browser.pageWebView.url?.absoluteString == self.site + "/harbour/history" && !reader.isActive })
        check("reader: …which has no article, so no button", await waitFor { browser.toolbarItemIsHidden("reader") && browser.toolbarItemIsHidden("readerAppearance") })
        browser.goBack(nil)
        check("reader: Back returns to Reader", await waitFor {
            guard reader.isActive else { return false }
            return await exists("#reader-article")
        })

        // History has the article, once, and not Reader.
        if let history = app.history(for: browser.profile) {
            let pages = (try? history.pages(matching: "light nobody", limit: 10)) ?? []
            check("reader: history has the article, not the Reader page", pages.map(\.url.absoluteString) == [site + "/article"], pages.map(\.url))
        }

        // A Reader page whose article is gone: a restored session.
        let stale = ReaderPage.url(token: "gone", original: URL(string: site + "/second")!)!
        browser.load(stale)
        check("reader: a Reader page from before a relaunch sends the tab to the article", await waitFor { browser.pageWebView.url?.absoluteString == self.site + "/second" })
        BrowserSettings.readerAppearance = ReaderAppearance()
    }
}
