import Foundation

/// An article as the Reader agent took it from a page.
public struct ReaderArticle: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var byline: String
    public var site: String
    /// As the page gave it: an ISO date, usually.
    public var published: String
    public var language: String
    public var direction: String
    public var words: Int
    /// Already reduced to allowed elements and attributes by the agent.
    public var html: String

    public init(url: URL, title: String, byline: String = "", site: String = "", published: String = "",
                language: String = "", direction: String = "ltr", words: Int = 0, html: String) {
        self.url = url
        self.title = title
        self.byline = byline
        self.site = site
        self.published = published
        self.language = language
        self.direction = direction
        self.words = words
        self.html = html
    }

    /// At 230 words a minute, and never "0 min".
    public var minutes: Int { max(1, Int((Double(words) / 230).rounded())) }
}

/// How Reader looks. One setting for every article, as in Safari.
public struct ReaderAppearance: Equatable, Sendable, Codable {
    public enum Theme: String, CaseIterable, Sendable, Codable {
        case auto, light, sepia, dark
        public var name: String {
            switch self {
            case .auto: return "Match System"
            case .light: return "White"
            case .sepia: return "Sepia"
            case .dark: return "Dark"
            }
        }
    }

    public enum Font: String, CaseIterable, Sendable, Codable {
        case newYork, sanFrancisco, georgia, charter, palatino
        public var name: String {
            switch self {
            case .newYork: return "New York"
            case .sanFrancisco: return "San Francisco"
            case .georgia: return "Georgia"
            case .charter: return "Charter"
            case .palatino: return "Palatino"
            }
        }
        public var css: String {
            switch self {
            case .newYork: return "ui-serif, 'New York', Georgia, serif"
            case .sanFrancisco: return "ui-sans-serif, -apple-system, system-ui, sans-serif"
            case .georgia: return "Georgia, serif"
            case .charter: return "Charter, 'Bitstream Charter', Georgia, serif"
            case .palatino: return "Palatino, 'Palatino Linotype', serif"
            }
        }
    }

    public enum Width: String, CaseIterable, Sendable, Codable {
        case narrow, medium, wide
        public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        public var css: String {
            switch self {
            case .narrow: return "32em"
            case .medium: return "40em"
            case .wide: return "52em"
            }
        }
    }

    public static let sizes = [14, 15, 16, 17, 18, 19, 20, 22, 24, 26, 28, 32]

    public var theme = Theme.auto
    public var font = Font.newYork
    public var size = 19
    public var width = Width.medium

    public init() {}

    public var canGrow: Bool { size < (Self.sizes.last ?? 32) }
    public var canShrink: Bool { size > (Self.sizes.first ?? 14) }
    public mutating func grow() { size = Self.sizes.first { $0 > size } ?? size }
    public mutating func shrink() { size = Self.sizes.last { $0 < size } ?? size }

    /// What to set on the Reader page's root element so it looks like this.
    /// Used both when the page is written and when a setting changes while
    /// it is showing, so the two cannot disagree.
    public var attributes: [String: String] {
        ["data-theme": theme.rawValue, "style": "--size: \(size)px; --font: \(font.css); --width: \(width.css)"]
    }
}

/// The Reader page's address, and its markup.
public enum ReaderPage {
    public static let scheme = "simplebrowser"
    public static let host = "reader"

    /// `simplebrowser://reader/<token>?url=<the article's own address>`.
    /// The article's address is in it so that a Reader page reached when the
    /// article is no longer held (a restored session) can send the tab there.
    public static func url(token: String, original: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + token
        components.queryItems = [URLQueryItem(name: "url", value: original.absoluteString)]
        return components.url
    }

    public static func isReader(_ url: URL?) -> Bool {
        url?.scheme == scheme && url?.host() == host
    }

    public static func token(of url: URL?) -> String? {
        guard isReader(url), let path = url?.path, path.count > 1 else { return nil }
        return String(path.dropFirst())
    }

    /// The article a Reader page shows; nil for any other address, and for
    /// a Reader address naming anything but a web page.
    public static func original(of url: URL?) -> URL? {
        guard isReader(url), let url, let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value, let original = URL(string: value),
              original.scheme == "http" || original.scheme == "https", original.host() != nil else { return nil }
        return original
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Nothing on a Reader page runs or phones home: no script from
    /// anywhere, no frames, no forms, no styles but its own. Images and
    /// links are all an article needs.
    static let policy = "default-src 'none'; img-src http: https: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    public static func html(_ article: ReaderArticle, appearance: ReaderAppearance) -> String {
        let attributes = appearance.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\"\(escape($0.value))\"" }.joined(separator: " ")
        let language = article.language.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } ? article.language : ""
        let direction = article.direction == "rtl" ? "rtl" : "ltr"
        var details = [escape(article.byline), formattedDate(article.published)].filter { !$0.isEmpty }
        details.append("\(article.minutes) min read")
        return """
        <!doctype html>
        <html lang="\(escape(language))" dir="\(direction)" \(attributes)><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="referrer" content="no-referrer">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(article.title))</title>
        <style>
          :root { --bg: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --rule: rgba(0,0,0,.12); --link: #0a62c9; --code: rgba(0,0,0,.05); }
          @media (prefers-color-scheme: dark) { :root[data-theme=auto] { --bg: #1c1c1e; --text: #e6e6e8; --muted: #98989d; --rule: rgba(255,255,255,.16); --link: #6cb2ff; --code: rgba(255,255,255,.08); } }
          :root[data-theme=sepia] { --bg: #f8f1e3; --text: #4f3928; --muted: #8a735f; --rule: rgba(79,57,40,.18); --link: #9a4b1c; --code: rgba(79,57,40,.07); color-scheme: light; }
          :root[data-theme=dark] { --bg: #1c1c1e; --text: #e6e6e8; --muted: #98989d; --rule: rgba(255,255,255,.16); --link: #6cb2ff; --code: rgba(255,255,255,.08); color-scheme: dark; }
          :root[data-theme=light] { color-scheme: light; }
          html { background: var(--bg); }
          body { margin: 0 auto; padding: 56px 28px 96px; max-width: var(--width); color: var(--text);
                 font: var(--size)/1.62 var(--font); -webkit-font-smoothing: antialiased; overflow-wrap: break-word; }
          header { margin-bottom: 1.6em; padding-bottom: 1.1em; border-bottom: 1px solid var(--rule); }
          .site { font: 600 0.72em/1.3 -apple-system, system-ui, sans-serif; letter-spacing: .04em; text-transform: uppercase; color: var(--muted); }
          h1 { font-size: 1.85em; line-height: 1.18; margin: .35em 0 .4em; }
          .details { font: 0.78em/1.4 -apple-system, system-ui, sans-serif; color: var(--muted); }
          h2 { font-size: 1.35em; line-height: 1.25; margin: 1.7em 0 .5em; }
          h3, h4, h5, h6 { font-size: 1.1em; line-height: 1.3; margin: 1.5em 0 .4em; }
          p, ul, ol, blockquote, pre, figure, table, dl { margin: 0 0 1.05em; }
          a { color: var(--link); text-decoration-thickness: 1px; text-underline-offset: .15em; }
          img { max-width: 100%; height: auto; border-radius: 6px; display: block; margin: 0 auto; }
          figure { margin-left: 0; margin-right: 0; }
          figcaption { font: 0.78em/1.45 -apple-system, system-ui, sans-serif; color: var(--muted); margin-top: .5em; text-align: center; }
          blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid var(--rule); color: var(--muted); }
          pre, code, kbd { font: 0.86em/1.5 ui-monospace, Menlo, monospace; background: var(--code); border-radius: 4px; }
          code, kbd { padding: .1em .3em; }
          pre { padding: .8em 1em; overflow-x: auto; }
          pre code { background: none; padding: 0; }
          table { border-collapse: collapse; width: 100%; font-size: .9em; }
          th, td { border: 1px solid var(--rule); padding: .4em .6em; text-align: start; vertical-align: top; }
          hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        </style></head>
        <body>
        <header>
          <div class="site" translate="no">\(escape(article.site))</div>
          <h1 id="reader-title">\(escape(article.title))</h1>
          <div class="details" id="reader-details">\(details.joined(separator: " · "))</div>
        </header>
        <article id="reader-article">\(article.html)</article>
        </body></html>
        """
    }

    /// Served for a Reader address whose article is no longer held.
    public static func redirect(to original: URL?) -> String {
        guard let original else {
            return "<!doctype html><meta charset=\"utf-8\"><title>Reader</title><p style=\"font: 15px -apple-system; margin: 15vh auto; max-width: 30em\">This article is no longer available in Reader.</p>"
        }
        let address = escape(original.absoluteString)
        return "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0;url=\(address)\"><title>Reader</title>"
    }

    /// "12 March 2026" from an ISO date; nothing from anything else, rather
    /// than showing a machine's date format to a person.
    static func formattedDate(_ published: String) -> String {
        guard !published.isEmpty else { return "" }
        let iso = ISO8601DateFormatter()
        var date = iso.date(from: published)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: published)
        }
        if date == nil {
            iso.formatOptions = [.withFullDate]
            date = iso.date(from: String(published.prefix(10)))
        }
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
