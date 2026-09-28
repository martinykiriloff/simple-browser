import Foundation

/// What the address bar says about the connection to the page showing.
///
/// It matters more now that the bar shows only the site's name while it is
/// not being edited: with the scheme out of sight, this is the only thing
/// that tells `http` from `https`.
public enum PageSecurity: Equatable, Sendable {
    /// https, and everything on the page came over https.
    case secure
    /// https, but the page pulled in something over plain http.
    case mixed
    /// Plain http: anyone on the network can read and change the page.
    case notSecure
    /// Plain http to this Mac itself, which crosses no network.
    case local
    /// The browser's own pages, files and blanks: nothing to say.
    case none

    public static func of(_ url: URL?, hasOnlySecureContent: Bool) -> PageSecurity {
        guard let url, let scheme = url.scheme?.lowercased() else { return .none }
        switch scheme {
        case "https":
            return hasOnlySecureContent ? .secure : .mixed
        case "http":
            let host = (url.host(percentEncoded: false) ?? "").lowercased()
            let loopback = host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]"
                || (host.hasPrefix("127.") && host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." })
            return loopback ? .local : .notSecure
        default:
            return .none
        }
    }

    /// Shown beside the address. Only trouble gets words; a lock needs none.
    public var label: String? {
        switch self {
        case .notSecure, .mixed: return "Not Secure"
        case .secure, .local, .none: return nil
        }
    }

    public var symbol: String? {
        switch self {
        case .secure: return "lock.fill"
        case .mixed, .notSecure: return "exclamationmark.triangle.fill"
        case .local: return "desktopcomputer"
        case .none: return nil
        }
    }

    public func explanation(site: String) -> String {
        switch self {
        case .secure:
            return "The connection to \(site) is encrypted. What you send and receive cannot be read or changed on the way."
        case .mixed:
            return "\(site) is encrypted, but this page loaded parts of itself without encryption. Those parts could have been read or changed on the way."
        case .notSecure:
            return "The connection to \(site) is not encrypted. Anyone on the network can read what you type here, passwords and card numbers included, and change what you see."
        case .local:
            return "\(site) is on this Mac. The connection does not leave it."
        case .none:
            return ""
        }
    }
}
