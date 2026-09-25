import Foundation

/// A saved sign-in, without its password. The password is fetched separately
/// and only when something is about to use it, so lists, searches and "does
/// this site have a saved account?" never hold secrets in memory.
public struct Credential: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    /// `scheme://host[:port]`, normalised by `CredentialOrigin`.
    public var origin: String
    public var username: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), origin: String, username: String,
                createdAt: Date = Date(), modifiedAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.origin = origin
        self.username = username
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastUsedAt = lastUsedAt
    }

    /// The host, for display: `example.com`, or `example.com:8443`.
    public var site: String { CredentialOrigin.site(of: origin) }
}

/// Origins are the security boundary of the whole feature: a password saved
/// for one origin is only ever offered to that origin.
public enum CredentialOrigin {

    /// The normalised origin of a page URL; nil for anything that is not a
    /// web page (`about:`, `file:`, `data:`), where nothing is saved or filled.
    public static func origin(of url: URL) -> String? {
        // Not `host()`: its default percent-encodes an international host
        // instead of giving the ASCII (punycode) form WebKit reports.
        origin(scheme: url.scheme ?? "", host: url.host(percentEncoded: false) ?? "", port: url.port)
    }

    /// From the parts WebKit reports for a frame's security origin. WebKit
    /// uses port 0 for "the scheme's default".
    public static func origin(scheme: String, host: String, port: Int?) -> String? {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port, port > 0, port != (scheme == "https" ? 443 : 80) else { return "\(scheme)://\(bracketed)" }
        return "\(scheme)://\(bracketed):\(port)"
    }

    /// Accepts what a person types or a CSV holds: a full URL, or a bare host.
    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate) else { return nil }
        return origin(of: url)
    }

    public static func site(of origin: String) -> String {
        origin.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? origin
    }

    /// Whether a password saved for `saved` may be offered to a page at `page`.
    ///
    /// The same origin, or the https version of an http origin: a site that
    /// moved to https keeps its passwords. Never the other way round -- an
    /// https password must not be handed to a plain-http page, which anyone on
    /// the network can impersonate. No subdomain or sibling-domain matching:
    /// that needs the public suffix list to be safe, and guessing is not.
    public static func matches(saved: String, page: String) -> Bool {
        if saved == page { return true }
        guard saved.hasPrefix("http://"), page.hasPrefix("https://") else { return false }
        return saved.dropFirst("http://".count) == page.dropFirst("https://".count)
    }

    /// Worth a warning in the UI: a password typed here crosses the network
    /// in the clear. Loopback is exempt, as it is in every browser.
    public static func isInsecure(_ origin: String) -> Bool {
        guard origin.hasPrefix("http://") else { return false }
        let host = site(of: origin).split(separator: ":").first.map(String.init) ?? ""
        return !(host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host.hasSuffix(".localhost"))
    }
}
