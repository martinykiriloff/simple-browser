import Foundation

/// A search engine the address bar can use.
public struct SearchEngine: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// `%s` is replaced by the query.
    public let searchTemplate: String
    /// OpenSearch suggestions (`["q", ["s1", "s2"]]`), or nil when the engine offers none.
    public let suggestTemplate: String?

    public init(id: String, name: String, searchTemplate: String, suggestTemplate: String?) {
        self.id = id
        self.name = name
        self.searchTemplate = searchTemplate
        self.suggestTemplate = suggestTemplate
    }

    public static let all: [SearchEngine] = [
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", searchTemplate: "https://duckduckgo.com/?q=%s",
                     suggestTemplate: "https://duckduckgo.com/ac/?q=%s&type=list"),
        SearchEngine(id: "google", name: "Google", searchTemplate: "https://www.google.com/search?q=%s",
                     suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"),
        SearchEngine(id: "bing", name: "Bing", searchTemplate: "https://www.bing.com/search?q=%s",
                     suggestTemplate: "https://api.bing.com/osjson.aspx?query=%s"),
        SearchEngine(id: "ecosia", name: "Ecosia", searchTemplate: "https://www.ecosia.org/search?q=%s",
                     suggestTemplate: "https://ac.ecosia.org/autocomplete?q=%s&type=list"),
        SearchEngine(id: "kagi", name: "Kagi", searchTemplate: "https://kagi.com/search?q=%s", suggestTemplate: nil),
        SearchEngine(id: "startpage", name: "Startpage", searchTemplate: "https://www.startpage.com/do/search?query=%s", suggestTemplate: nil),
    ]

    public static let `default` = all[0]

    /// A person's own engine: any URL with `%s` where the query goes.
    public static func custom(template: String) -> SearchEngine? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("%s"), let url = URL(string: trimmed.replacingOccurrences(of: "%s", with: "x")),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return SearchEngine(id: "custom", name: url.host()?.replacingOccurrences(of: "www.", with: "") ?? "Custom",
                            searchTemplate: trimmed, suggestTemplate: nil)
    }

    public func searchURL(for query: String) -> URL? {
        URL(string: searchTemplate.replacingOccurrences(of: "%s", with: Self.encode(query)))
    }

    public func suggestURL(for query: String) -> URL? {
        suggestTemplate.flatMap { URL(string: $0.replacingOccurrences(of: "%s", with: Self.encode(query))) }
    }

    static func encode(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#%")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }

    /// Reads the OpenSearch answer: `["query", ["suggestion", …], …]`.
    public static func parseSuggestions(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count >= 2,
              let list = json[1] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }
}

/// One row under the address bar.
public struct AddressSuggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case switchToTab(id: String)
        case bookmark
        case history
        case search
    }
    public let kind: Kind
    public let title: String
    /// Where it goes; for a search, the search results page.
    public let url: URL
    /// For a search, the words; otherwise the address shown beside the title.
    public let detail: String

    public init(kind: Kind, title: String, url: URL, detail: String) {
        self.kind = kind
        self.title = title
        self.url = url
        self.detail = detail
    }
}

/// Merges what the person has (open tabs, bookmarks, history) with the
/// engine's suggestions, and picks the inline completion.
public enum SuggestionRanker {
    public struct Candidate: Sendable {
        public let title: String
        public let url: URL
        public let score: Double
        public init(title: String, url: URL, score: Double = 0) {
            self.title = title
            self.url = url
            self.score = score
        }
    }

    /// The address as the person would type it: no scheme, no `www.`.
    public static func typeable(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") && text.filter({ $0 == "/" }).count == 1 { text.removeLast() }
        return text
    }

    /// What to add after the typed text, selected, so Return goes there
    /// and one more keystroke replaces it: `git` → `hub.com`.
    ///
    /// Only an address that starts with what was typed, and only the host
    /// unless the person is already typing a path, so a completion never
    /// runs further than they meant.
    public static func completion(for typed: String, candidates: [Candidate]) -> (text: String, url: URL)? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let address = typeable(candidate.url)
            guard address.lowercased().hasPrefix(lower), address.count > text.count else { continue }
            let host = address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? address
            let full = text.contains("/") ? address : host
            guard full.lowercased().hasPrefix(lower), full.count > text.count else { continue }
            let rest = String(full.dropFirst(text.count))
            // The site itself, keeping its scheme, host and port.
            var site = URLComponents(url: candidate.url, resolvingAgainstBaseURL: false)
            site?.path = "/"
            site?.query = nil
            site?.fragment = nil
            let url = text.contains("/") ? candidate.url : site?.url ?? candidate.url
            return (rest, url)
        }
        return nil
    }

    /// Open tabs first (a tab already open beats opening it again), then
    /// bookmarks, then history, then the search itself and the engine's
    /// suggestions. No address appears twice.
    public static func rank(query: String, tabs: [(id: String, title: String, url: URL)], bookmarks: [Candidate],
                            history: [Candidate], searches: [String], engine: SearchEngine, limit: Int = 10) -> [AddressSuggestion] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        let words = text.lowercased().split(separator: " ").map(String.init)
        func matches(_ title: String, _ url: URL) -> Bool {
            let haystack = (title + " " + url.absoluteString).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        var seen: Set<String> = []
        var result: [AddressSuggestion] = []
        func add(_ suggestion: AddressSuggestion) {
            let key = suggestion.kind == .search ? "search:" + suggestion.detail.lowercased() : typeable(suggestion.url).lowercased()
            guard seen.insert(key).inserted else { return }
            result.append(suggestion)
        }
        for tab in tabs where matches(tab.title, tab.url) {
            add(AddressSuggestion(kind: .switchToTab(id: tab.id), title: tab.title.isEmpty ? typeable(tab.url) : tab.title, url: tab.url, detail: typeable(tab.url)))
        }
        for bookmark in bookmarks.sorted(by: { $0.score > $1.score }).prefix(4) where matches(bookmark.title, bookmark.url) {
            add(AddressSuggestion(kind: .bookmark, title: bookmark.title.isEmpty ? typeable(bookmark.url) : bookmark.title, url: bookmark.url, detail: typeable(bookmark.url)))
        }
        for page in history.sorted(by: { $0.score > $1.score }).prefix(6) where matches(page.title, page.url) {
            add(AddressSuggestion(kind: .history, title: page.title.isEmpty ? typeable(page.url) : page.title, url: page.url, detail: typeable(page.url)))
        }
        let pages = Array(result.prefix(max(0, limit - 4)))
        result = pages
        seen = Set(pages.map { typeable($0.url).lowercased() })
        for term in [text] + searches where result.count < limit {
            if let url = engine.searchURL(for: term) {
                add(AddressSuggestion(kind: .search, title: term, url: url, detail: term))
            }
        }
        return result
    }
}
