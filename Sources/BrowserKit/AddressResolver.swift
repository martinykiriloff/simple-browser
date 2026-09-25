import Foundation

/// Turns whatever the user typed into the address bar into a URL.
///
/// Pure Foundation so it can be unit-tested without a web view. Three cases:
/// an absolute URL is used as-is, something that looks like a host gets
/// `https://` prepended, and everything else becomes a search query.
public enum AddressResolver {
    public static let defaultSearchTemplate = "https://duckduckgo.com/?q="

    public static func resolve(
        _ input: String,
        searchTemplate: String = defaultSearchTemplate
    ) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = address(text) { return url }
        let query = text.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? text
        return URL(string: searchTemplate + query)
    }

    /// The URL for input that names a place (an absolute URL or something
    /// host-like), or nil when the input could only be a search query.
    public static func address(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            let schemeNeedsNoHost = ["about", "file", "data", "javascript"].contains(scheme)
            if url.host != nil || schemeNeedsNoHost { return url }
        }

        if looksLikeHost(text), let url = URL(string: "https://" + text) {
            return url
        }
        return nil
    }

    /// `example.com`, `example.com/path`, `localhost:8080` — but not `hello world`.
    static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let hostPart = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
        let hostOnly = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
        if hostOnly == "localhost" { return true }
        guard hostOnly.contains(".") else { return false }
        return !hostOnly.hasPrefix(".") && !hostOnly.hasSuffix(".")
    }

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}
