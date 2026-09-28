import AppKit
import WebKit
import DataKit
import BrowserKit

/// The page a new tab or window opens with: favorites, frequently visited
/// sites, the reading list and recently closed tabs. Built on the Mac from
/// the profile's own data, so it shows at once and needs no network.
///
/// Served from `simplebrowser://start` by a scheme handler on each tab's
/// configuration. The page is inert HTML: every link is an ordinary link.
@MainActor
final class StartPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "simplebrowser"
    static let url = URL(string: "simplebrowser://start")!

    struct Content {
        var favorites: [(title: String, url: URL)] = []
        var frequent: [(title: String, url: URL)] = []
        var reading: [(title: String, url: URL)] = []
        var closed: [(title: String, url: URL)] = []
        /// The engine the search box uses, by name.
        var searchEngine = SearchEngine.default.name
        /// A private window's start page: what private means, and nothing
        /// drawn from history.
        var isPrivate = false
    }

    /// Where the page's search box sends what was typed. The tab takes it
    /// from there, so the box follows the engine chosen in Settings and an
    /// address typed into it is opened, not searched for.
    static func searchText(from url: URL?) -> String? {
        guard let url, url.scheme == scheme, url.host() == "search",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // A form writes a space as "+", and a real plus as %2B.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        return components.queryItems?.first { $0.name == "q" }?.value
    }

    /// Gathered when the page loads, so it is always current.
    let content: () -> Content

    init(content: @escaping () -> Content) {
        self.content = content
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        // Reader pages share the scheme: simplebrowser://reader/<token>.
        let html: String
        if ReaderPage.isReader(task.request.url) {
            html = ReaderStore.shared.html(for: task.request.url)
        } else if WarningPage.isWarning(task.request.url) {
            html = CertificateStore.shared.html(for: task.request.url)
        } else {
            html = Self.html(content())
        }
        let data = Data(html.utf8)
        let response = URLResponse(url: task.request.url ?? Self.url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func isStartPage(_ url: URL?) -> Bool { url?.scheme == scheme && !ReaderPage.isReader(url) && !WarningPage.isWarning(url) }

    /// A tab's configuration gets the handler once; a pop-up's configuration,
    /// copied from its opener, already has it.
    static func install(_ handler: StartPageSchemeHandler, into configuration: WKWebViewConfiguration) {
        if configuration.urlSchemeHandler(forURLScheme: scheme) == nil {
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
    }

    // MARK: - The page

    private static func privateHTML(_ content: Content, escape: (String) -> String, tiles: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Private Browsing</title>
        <meta name="color-scheme" content="dark">
        <style>
          body { margin: 0; background: #1b1922; color: #f2f0f7; font: 14px -apple-system, system-ui; }
          main { max-width: 640px; margin: 12vh auto; padding: 0 24px; }
          h1 { font-size: 26px; margin: 0 0 6px; }
          p.lead { color: #b9b3c9; margin: 0 0 26px; font-size: 15px; }
          form { margin: 0 0 30px; }
          input { width: 100%; box-sizing: border-box; font: 16px -apple-system, system-ui; padding: 11px 18px; border-radius: 22px;
                  border: 1px solid rgba(255,255,255,.18); background: #2a2735; color: inherit; outline: none; }
          input:focus { border-color: #9b86e0; box-shadow: 0 0 0 3px rgba(155,134,224,.3); }
          .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
          .card { background: #252231; border-radius: 12px; padding: 14px 18px; }
          h2 { font-size: 13px; margin: 0 0 8px; color: #cfc8e6; }
          ul { margin: 0; padding-left: 18px; color: #b9b3c9; line-height: 1.55; }
          h3 { font-size: 15px; margin: 30px 0 10px; }
          .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 14px; }
          .tile { display: flex; flex-direction: column; align-items: center; gap: 8px; text-decoration: none; color: inherit; padding: 8px; border-radius: 12px; }
          .tile:hover { background: #252231; }
          .icon { width: 56px; height: 56px; border-radius: 14px; display: grid; place-items: center; color: white; font: 600 24px -apple-system; }
          .label { font-size: 12px; max-width: 96px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; text-align: center; }
        </style></head><body><main>
        <h1 id="private-title">Private Browsing</h1>
        <p class="lead">What you do in this window stays out of your history and is gone when you close it.</p>
        <form action="simplebrowser://search" method="get" role="search">
          <input name="q" type="search" autocomplete="off" spellcheck="false" aria-label="Search \(escape(content.searchEngine)) or enter an address"
                 placeholder="Search \(escape(content.searchEngine)) or enter an address">
        </form>
        <div class="columns">
          <div class="card"><h2>Not kept</h2><ul><li>The pages you visit</li><li>Cookies and site data</li><li>What you type into forms</li><li>New passwords</li></ul></div>
          <div class="card"><h2>Still visible to others</h2><ul><li>Sites you visit see your visit</li><li>Your network and employer</li><li>Files you download stay</li><li>Bookmarks you add stay</li></ul></div>
        </div>
        \(tiles.isEmpty ? "" : "<h3>Favorites</h3><div class=tiles>" + tiles + "</div>")
        </main></body></html>
        """
    }

    static func html(_ content: Content) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func tile(_ item: (title: String, url: URL)) -> String {
            let host = item.url.host()?.replacingOccurrences(of: "www.", with: "") ?? item.url.absoluteString
            let title = item.title.isEmpty ? host : item.title
            let letter = String(host.first ?? "•").uppercased()
            // Stable across launches, unlike hashValue: a site keeps its colour.
            let hue = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
            return """
            <a class="tile" href="\(escape(item.url.absoluteString))" title="\(escape(item.url.absoluteString))">
              <span class="icon" style="background: hsl(\(hue) 55% 46%)">\(escape(letter))</span>
              <span class="label">\(escape(title))</span></a>
            """
        }
        func row(_ item: (title: String, url: URL)) -> String {
            let title = item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title
            return "<li><a href=\"\(escape(item.url.absoluteString))\">\(escape(title))<span>\(escape(item.url.host() ?? ""))</span></a></li>"
        }
        func section(_ title: String, _ body: String, empty: Bool) -> String {
            empty ? "" : "<section><h2>\(title)</h2>\(body)</section>"
        }
        let nothing = content.favorites.isEmpty && content.frequent.isEmpty && content.reading.isEmpty && content.closed.isEmpty
        if content.isPrivate { return privateHTML(content, escape: escape, tiles: content.favorites.map(tile).joined()) }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Start Page</title>
        <meta name="color-scheme" content="light dark">
        <style>
          :root { color-scheme: light dark; --bg: #f5f5f7; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73; }
          @media (prefers-color-scheme: dark) { :root { --bg: #1e1e20; --card: #2c2c2e; --text: #f5f5f7; --muted: #98989d; } }
          body { margin: 0; background: var(--bg); color: var(--text); font: 14px -apple-system, system-ui; }
          main { max-width: 860px; margin: 8vh auto; padding: 0 24px; }
          h2 { font-size: 17px; font-weight: 700; margin: 28px 0 12px; }
          .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 14px; }
          .tile { display: flex; flex-direction: column; align-items: center; gap: 8px; text-decoration: none; color: inherit; padding: 8px; border-radius: 12px; }
          .tile:hover { background: var(--card); }
          .icon { width: 56px; height: 56px; border-radius: 14px; display: grid; place-items: center; color: white; font: 600 24px -apple-system; box-shadow: 0 1px 3px rgba(0,0,0,.15); }
          .label { font-size: 12px; max-width: 96px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; text-align: center; }
          ul { list-style: none; padding: 0; margin: 0; background: var(--card); border-radius: 12px; overflow: hidden; }
          li a { display: flex; justify-content: space-between; gap: 16px; padding: 10px 14px; color: inherit; text-decoration: none; }
          li + li a { border-top: 1px solid rgba(128,128,128,.18); }
          li a:hover { background: rgba(128,128,128,.12); }
          li span { color: var(--muted); white-space: nowrap; }
          .empty { color: var(--muted); text-align: center; margin-top: 12vh; }
          form { margin: 0 auto 8px; max-width: 560px; }
          input { width: 100%; box-sizing: border-box; font: 16px -apple-system, system-ui; padding: 11px 18px; border-radius: 22px;
                  border: 1px solid rgba(128,128,128,.3); background: var(--card); color: var(--text); outline: none; }
          input:focus { border-color: AccentColor; box-shadow: 0 0 0 3px color-mix(in srgb, AccentColor 30%, transparent); }
        </style></head><body><main>
        <form action="simplebrowser://search" method="get" role="search">
          <input name="q" type="search" autocomplete="off" spellcheck="false" aria-label="Search \(escape(content.searchEngine)) or enter an address"
                 placeholder="Search \(escape(content.searchEngine)) or enter an address">
        </form>
        \(section("Favorites", "<div class=tiles>" + content.favorites.map(tile).joined() + "</div>", empty: content.favorites.isEmpty))
        \(section("Frequently Visited", "<div class=tiles>" + content.frequent.map(tile).joined() + "</div>", empty: content.frequent.isEmpty))
        \(section("Reading List", "<ul>" + content.reading.prefix(8).map(row).joined() + "</ul>", empty: content.reading.isEmpty))
        \(section("Recently Closed", "<ul>" + content.closed.prefix(6).map(row).joined() + "</ul>", empty: content.closed.isEmpty))
        \(nothing ? "<p class=empty>Sites you visit and bookmark will appear here.</p>" : "")
        </main></body></html>
        """
    }
}
