import Foundation

/// Where the Home button goes.
///
/// The stored value is whatever the user typed in Settings, so it is resolved
/// with the same rules as the address bar: `example.com` works, and so does a
/// full URL. An empty or unusable value falls back to the default rather than
/// leaving Home doing nothing.
public enum HomePage {
    /// Matches the default search engine, so a fresh install is coherent.
    public static let defaultAddress = "https://duckduckgo.com/"

    public static var defaultURL: URL { URL(string: defaultAddress)! }

    /// The URL Home should load for a stored setting.
    public static func url(for stored: String?) -> URL {
        custom(stored) ?? defaultURL
    }

    /// The user's own homepage, or nil when none is set (or it is unusable).
    ///
    /// A homepage has to be a place, not a search: `hello world` would resolve
    /// to a search results page in the address bar, which is a surprising
    /// thing for Home to open, so only real URLs and host-like input count.
    public static func custom(_ stored: String?) -> URL? {
        guard let url = AddressResolver.address(stored ?? "") else { return nil }
        // Home must not run script in whatever page happens to be open.
        return url.scheme?.lowercased() == "javascript" ? nil : url
    }
}
