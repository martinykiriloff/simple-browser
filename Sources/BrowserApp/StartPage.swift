import AppKit
import WebKit
import DataKit
import BrowserKit

/// The page a new tab or window opens with: favorites, frequently visited
/// sites, the reading list and recently closed tabs. Built on the Mac from
/// the profile's own data, so it shows at once and needs no network.
///
/// Served from `keel://start` by a scheme handler on each tab's
/// configuration. The page is inert HTML: every link is an ordinary link.
@MainActor
final class StartPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "keel"
    static let url = URL(string: "keel://start")!

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
        /// An agent's sandbox window: the private page, saying "Sandbox".
        var isSandbox = false
        /// Recent agent sessions, newest first (Design D, G1-01).
        var agentSessions: [AgentTrust.SessionRecord] = []
        /// The window's profile, for the identity pill.
        var profileName = ""
    }

    /// The trust layer's session history, for "Recent agent sessions".
    /// Set by the app (`configureRestyle`).
    static var agentSessions: (() -> [AgentTrust.SessionRecord])?
    /// The window a page is shown in, for its profile and whether it is an
    /// agent's sandbox. Set by the app (`configureRestyle`).
    static var browserForWebView: ((WKWebView) -> BrowserWindowController?)?
    /// "View all": opens the agent activity log, from the start page only.
    static let agentLogURL = URL(string: "keel://agent-log")!

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
        let url = task.request.url
        // "View all" under Recent agent sessions: the activity log. Only the
        // start page may ask (a web page cannot open browser windows this
        // way), and it stays where it is: the answer is "no content".
        if url?.host() == Self.agentLogURL.host() {
            if Self.isStartPage(webView.url) {
                NSApp.sendAction(#selector(AppDelegate.showAgentActivityLog(_:)), to: nil, from: nil)
            }
            let response = HTTPURLResponse(url: url ?? Self.agentLogURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/gif"])
                ?? URLResponse(url: url ?? Self.agentLogURL, mimeType: "image/gif", expectedContentLength: 0, textEncodingName: nil)
            task.didReceive(response)
            task.didFinish()
            return
        }
        // Reader pages share the scheme: keel://reader/<token>.
        let html: String
        if ReaderPage.isReader(url) {
            html = ReaderStore.shared.html(for: url)
        } else if WarningPage.isWarning(url) {
            html = CertificateStore.shared.html(for: url)
        } else {
            var content = content()
            let browser = Self.browserForWebView?(webView)
            if content.isPrivate {
                content.isSandbox = browser?.privateSession?.agentSessionID != nil
            } else {
                content.agentSessions = Self.agentSessions?() ?? []
            }
            content.profileName = browser?.profile.name ?? ""
            html = Self.html(content)
        }
        let data = Data(html.utf8)
        let response = URLResponse(url: url ?? Self.url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func isStartPage(_ url: URL?) -> Bool {
        url?.scheme == scheme && !ReaderPage.isReader(url) && !WarningPage.isWarning(url) && url?.host() != agentLogURL.host()
    }

    /// A tab's configuration gets the handler once; a pop-up's configuration,
    /// copied from its opener, already has it.
    static func install(_ handler: StartPageSchemeHandler, into configuration: WKWebViewConfiguration) {
        if configuration.urlSchemeHandler(forURLScheme: scheme) == nil {
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
    }

    // MARK: - The page (Design D, G1-01)

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Light, as every page is in Design D, with the chrome's palette for
    /// a person who keeps the system dark.
    private static let style = """
      :root { color-scheme: light dark; \(Keel.pageCSS) --card: #FFFFFF; --hover: #F4F5F7; }
      @media (prefers-color-scheme: dark) {
        :root { --ink: #E6E8EC; --muted: #9AA1AD; --line: #262C36; --subtle: #171B22; --page: #12151B; --card: #12151B; --hover: #171B22; --red: #FF8A80; }
      }
      @media (prefers-contrast: more) { :root { --muted: var(--ink); } }
      * { box-sizing: border-box; }
      html, body { height: 100%; }
      body { margin: 0; background: var(--page); color: var(--ink); font: 13px/1.4 var(--sans); letter-spacing: -0.005em;
             display: flex; flex-direction: column; align-items: center; }
      main { width: min(760px, calc(100% - 48px)); display: flex; flex-direction: column; align-items: center; padding-top: 12vh; flex: 1; }
      .wordmark { margin: 0; font-size: 28px; font-weight: 700; letter-spacing: -0.03em; }
      form { margin: 22px 0 0; width: min(600px, 100%); position: relative; }
      input { width: 100%; height: 48px; font: 14px var(--sans); color: var(--ink); padding: 0 64px 0 42px; border-radius: 12px;
              border: 1px solid var(--line); background: var(--card); box-shadow: 0 0 0 3px var(--subtle); outline: none; }
      input::placeholder { color: var(--muted); }
      input:focus { border-color: var(--ink); }
      input::-webkit-search-cancel-button { display: none; }
      .lens { position: absolute; left: 16px; top: 17px; width: 14px; height: 14px; border-radius: 50%; border: 2px solid var(--muted); pointer-events: none; }
      .kbd { font: 11px var(--mono); color: var(--muted); border: 1px solid var(--line); border-radius: 5px; padding: 1px 6px; line-height: 16px; }
      form .kbd { position: absolute; right: 16px; top: 14px; pointer-events: none; }
      section { width: 100%; margin-top: 36px; }
      section.first { margin-top: 40px; }
      .head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 12px; }
      h2 { margin: 0; font-size: 11px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); }
      .head a { font-size: 12px; color: var(--muted); text-decoration: none; }
      .head a:hover, .head a:focus-visible { color: var(--ink); text-decoration: underline; }
      .tiles { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 14px; }
      .tile { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 16px 8px 14px; border-radius: 12px;
              border: 1px solid var(--line); background: var(--card); color: inherit; text-decoration: none; min-width: 0; }
      .tile:hover, .tile:focus-visible { background: var(--hover); outline: none; border-color: var(--muted); }
      .icon { width: 44px; height: 44px; border-radius: 10px; background: var(--subtle); display: grid; place-items: center; }
      .icon i { width: 22px; height: 22px; border-radius: 5px; display: grid; place-items: center; color: #fff; font: 700 12px var(--sans); font-style: normal; }
      .tile .text { text-align: center; max-width: 100%; }
      .label { display: block; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .host { display: block; font: 11px var(--mono); color: var(--muted); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .list { border: 1px solid var(--line); border-radius: 12px; background: var(--card); overflow: hidden; margin: 0; padding: 0; list-style: none; }
      .list > * + * { border-top: 1px solid var(--line); }
      .row { display: flex; align-items: center; gap: 12px; height: 44px; padding: 0 16px; color: inherit; text-decoration: none; }
      a.row:hover, a.row:focus-visible { background: var(--hover); outline: none; }
      .row .title { flex: 1; min-width: 0; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .row .meta { font: 11px var(--mono); color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 45%; }
      .row .when { width: 68px; text-align: right; font-size: 12px; color: var(--muted); white-space: nowrap; }
      .row.empty { color: var(--muted); }
      .dot { width: 7px; height: 7px; border-radius: 50%; flex: none; background: var(--idle); }
      .dot.done { background: var(--green); } .dot.waiting, .dot.running { background: var(--amber); } .dot.failed { background: var(--red); }
      .cards { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
      .card { border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; background: var(--card); }
      .card h3 { margin: 0 0 8px; font-size: 11px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); }
      .card ul { margin: 0; padding-left: 16px; color: var(--muted); line-height: 1.6; }
      .pill { display: flex; align-items: center; gap: 8px; margin: 32px 0 24px; padding: 6px 12px; border-radius: 13px; background: var(--subtle);
              font-size: 12px; color: var(--muted); max-width: calc(100% - 32px); }
      .pill b { color: var(--ink); font-weight: 600; }
      .pill .dot.sandbox { background: var(--green); } .pill .dot.personal { background: var(--idle); }
      @media (max-width: 640px) { .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); } .cards { grid-template-columns: 1fr; } .row .meta { display: none; } }
    """

    private static func searchForm(_ content: Content) -> String {
        let label = "Search \(escape(content.searchEngine)) or enter an address"
        return """
        <form action="keel://search" method="get" role="search">
          <span class="lens" aria-hidden="true"></span>
          <input name="q" type="search" autocomplete="off" spellcheck="false" aria-label="\(label)" placeholder="\(label)">
          <span class="kbd" aria-hidden="true">⌘L</span>
        </form>
        """
    }

    private static func tile(_ item: (title: String, url: URL), kind: String) -> String {
        let host = item.url.host()?.replacingOccurrences(of: "www.", with: "") ?? item.url.absoluteString
        let title = item.title.isEmpty ? host : item.title
        let letter = String(host.first ?? "•").uppercased()
        // Stable across launches, unlike hashValue: a site keeps its colour.
        let hue = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return """
        <a class="tile" data-kind="\(kind)" href="\(escape(item.url.absoluteString))" title="\(escape(item.url.absoluteString))">
          <span class="icon" aria-hidden="true"><i style="background: hsl(\(hue) 38% 42%)">\(escape(letter))</i></span>
          <span class="text"><span class="label">\(escape(title))</span><span class="host">\(escape(host))</span></span></a>
        """
    }

    private static func linkRow(_ item: (title: String, url: URL)) -> String {
        let title = item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title
        return "<li><a class=\"row\" href=\"\(escape(item.url.absoluteString))\"><span class=\"title\">\(escape(title))</span>"
            + "<span class=\"meta\">\(escape(item.url.host() ?? ""))</span></a></li>"
    }

    /// "2 min ago", "1 h ago".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    private static func sessionRow(_ record: AgentTrust.SessionRecord) -> String {
        let outcome = ["done", "waiting", "running", "failed"].contains(record.outcome) ? record.outcome : "stopped"
        let title = record.lastSummary.isEmpty ? "Session \(record.id)" : record.lastSummary
        let steps = record.actions == 1 ? "1 step" : "\(record.actions) steps"
        let meta = "\(record.client) · \(steps) · \(record.mode)"
        let when = relative(record.ended ?? record.started)
        return """
        <li class="row" data-session="\(escape(record.id))"><span class="dot \(outcome)" role="img" aria-label="\(outcome)"></span>\
        <span class="title">\(escape(title))</span><span class="meta">\(escape(meta))</span><span class="when">\(when)</span></li>
        """
    }

    /// Opens the activity log without leaving the page; the link still
    /// works as a link where script does not run.
    private static let agentLogScript = """
    <script>
    document.getElementById('agent-log')?.addEventListener('click', e => { e.preventDefault(); new Image().src = 'keel://agent-log?' + Date.now(); });
    </script>
    """

    private static func privateHTML(_ content: Content, tiles: String) -> String {
        let pill = content.isSandbox
            ? "<div class=\"pill\" id=\"identity\"><span class=\"dot sandbox\"></span><span><b>Sandbox · ephemeral</b> — history and cookies are discarded when this window closes</span></div>"
            : "<div class=\"pill\" id=\"identity\"><span class=\"dot personal\"></span><span><b>Private</b> — history and cookies are discarded when this window closes</span></div>"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(content.isSandbox ? "Agent Sandbox" : "Private Browsing")</title>
        <meta name="color-scheme" content="light dark">
        <style>\(style)</style></head><body><main>
        <h1 class="wordmark" id="private-title">\(content.isSandbox ? "Agent Sandbox" : "Private Browsing")</h1>
        \(searchForm(content))
        <section class="first" aria-label="What private means"><div class="cards">
          <div class="card"><h3>Not kept</h3><ul><li>The pages you visit</li><li>Cookies and site data</li><li>What you type into forms</li><li>New passwords</li></ul></div>
          <div class="card"><h3>Still visible to others</h3><ul><li>Sites you visit see your visit</li><li>Your network and employer</li><li>Files you download stay</li><li>Bookmarks you add stay</li></ul></div>
        </div></section>
        \(tiles.isEmpty ? "" : "<section><div class=head><h2>Favorites</h2></div><div class=tiles>" + tiles + "</div></section>")
        </main>\(pill)</body></html>
        """
    }

    static func html(_ content: Content) -> String {
        if content.isPrivate {
            return privateHTML(content, tiles: content.favorites.prefix(8).map { tile($0, kind: "favorite") }.joined())
        }
        // Top sites: favorites first, then the most visited, eight in all.
        let top = (content.favorites.map { ($0, "favorite") } + content.frequent.map { ($0, "frequent") }).prefix(8)
        let tiles = top.map { tile($0.0, kind: $0.1) }.joined()
        let sessions = content.agentSessions.prefix(4).map(sessionRow).joined()
        let profile = content.profileName.isEmpty ? "" : " · \(escape(content.profileName))"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Start Page</title>
        <meta name="color-scheme" content="light dark">
        <style>\(style)</style></head><body><main>
        <h1 class="wordmark">Keel</h1>
        \(searchForm(content))
        \(tiles.isEmpty
            ? "<section class=first><div class=head><h2>Top sites</h2></div><ul class=list><li class=\"row empty\">Sites you visit and bookmark will appear here.</li></ul></section>"
            : "<section class=first><div class=head><h2>Top sites</h2></div><div class=tiles>" + tiles + "</div></section>")
        <section id="agent-sessions"><div class="head"><h2>Recent agent sessions</h2><a id="agent-log" href="keel://agent-log">View all · ⌥⌘A</a></div>
          <ul class="list">\(sessions.isEmpty ? "<li class=\"row empty\">No agent sessions yet. Agent → Pair a New Agent… (⌥⌘P) connects one.</li>" : sessions)</ul></section>
        \(content.reading.isEmpty ? "" : "<section><div class=head><h2>Reading list</h2></div><ul class=list>" + content.reading.prefix(5).map(linkRow).joined() + "</ul></section>")
        \(content.closed.isEmpty ? "" : "<section><div class=head><h2>Recently closed</h2></div><ul class=list>" + content.closed.prefix(5).map(linkRow).joined() + "</ul></section>")
        </main>
        <div class="pill" id="identity"><span class="dot personal"></span><span><b>Personal profile\(profile)</b> — history and cookies are kept on this Mac</span></div>
        \(agentLogScript)
        </body></html>
        """
    }
}
