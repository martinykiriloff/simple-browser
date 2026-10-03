import Foundation

/// A connection WebKit refused because the site's certificate could not be
/// trusted, as the warning page and the exception need it.
public struct CertificateProblem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case untrusted, unknownIssuer, expired, notYetValid, wrongHost, other

        /// From the URL loading system's error code.
        public init(errorCode: Int) {
            switch errorCode {
            case -1201: self = .expired             // NSURLErrorServerCertificateHasBadDate
            case -1202: self = .untrusted           // NSURLErrorServerCertificateUntrusted
            case -1203: self = .unknownIssuer       // NSURLErrorServerCertificateHasUnknownRoot
            case -1204: self = .notYetValid         // NSURLErrorServerCertificateNotYetValid
            default: self = .other
            }
        }

        public static func isCertificateError(_ code: Int) -> Bool { (-1204 ... -1201).contains(code) }

        public func explanation(site: String) -> String {
            switch self {
            case .expired: return "The certificate \(site) presented has expired. The site may simply be neglected, or your Mac's clock may be wrong."
            case .notYetValid: return "The certificate \(site) presented is not valid yet. Your Mac's clock may be wrong."
            case .unknownIssuer: return "The certificate \(site) presented was issued by someone this Mac does not know, so nobody vouches for it being \(site)."
            case .wrongHost: return "The certificate presented belongs to another site, not \(site)."
            case .untrusted, .other: return "The certificate \(site) presented cannot be verified, so this may not be \(site) at all."
            }
        }
    }

    public var url: URL
    public var kind: Kind
    /// SHA-256 of the certificate presented, in hex. What an exception is for.
    public var fingerprint: String
    public var subject: String
    public var issuer: String
    public var expires: Date?

    public init(url: URL, kind: Kind, fingerprint: String, subject: String = "", issuer: String = "", expires: Date? = nil) {
        self.url = url
        self.kind = kind
        self.fingerprint = fingerprint
        self.subject = subject
        self.issuer = issuer
        self.expires = expires
    }

    public var host: String { url.host(percentEncoded: false)?.lowercased() ?? "" }
    public var port: Int { url.port ?? 443 }
}

/// Certificates the person chose to go on with, for the life of the app
/// (or of the private session). An exception is for one certificate on one
/// host and port: if the site presents another, the warning is back.
public struct CertificateExceptions: Equatable, Sendable {
    private var accepted: [String: String] = [:]

    public init() {}

    private static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    public mutating func accept(_ problem: CertificateProblem) {
        guard !problem.fingerprint.isEmpty else { return }
        accepted[Self.key(problem.host, problem.port)] = problem.fingerprint
    }

    public func allows(host: String, port: Int, fingerprint: String) -> Bool {
        !fingerprint.isEmpty && accepted[Self.key(host, port)] == fingerprint
    }

    /// Whether the connection to this page rests on an exception.
    public func covers(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host(percentEncoded: false) else { return false }
        return accepted[Self.key(host, url.port ?? 443)] != nil
    }

    public mutating func forget(host: String, port: Int) { accepted[Self.key(host, port)] = nil }
    public var isEmpty: Bool { accepted.isEmpty }
}

/// The page shown instead of a site whose certificate cannot be trusted.
public enum WarningPage {
    public static let scheme = "keel"
    public static let host = "warning"
    public static let actionHost = "warning-action"

    public static func url(token: String, original: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + token
        components.queryItems = [URLQueryItem(name: "url", value: original.absoluteString)]
        return components.url
    }

    public static func isWarning(_ url: URL?) -> Bool { url?.scheme == scheme && url?.host() == host }

    public static func token(of url: URL?) -> String? {
        guard isWarning(url), let path = url?.path, path.count > 1 else { return nil }
        return String(path.dropFirst())
    }

    public static func original(of url: URL?) -> URL? {
        guard isWarning(url), let url, let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value, let original = URL(string: value),
              original.scheme == "https", original.host() != nil else { return nil }
        return original
    }

    public enum Action: Equatable, Sendable {
        case back
        case proceed(token: String)
    }

    /// What a link on the warning page asks for. The page has no script:
    /// its two buttons are links to these addresses, which only a warning
    /// page is listened to on.
    public static func action(of url: URL?) -> Action? {
        guard let url, url.scheme == scheme, url.host() == actionHost else { return nil }
        switch url.path {
        case "/back": return .back
        case "/proceed":
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
            return token.map { .proceed(token: $0) }
        default: return nil
        }
    }

    public static func html(_ problem: CertificateProblem, token: String) -> String {
        let site = ReaderPage.escape(problem.host + (problem.port == 443 ? "" : ":\(problem.port)"))
        var rows: [(String, String)] = []
        if !problem.subject.isEmpty { rows.append(("Issued to", problem.subject)) }
        if !problem.issuer.isEmpty { rows.append(("Issued by", problem.issuer)) }
        if let expires = problem.expires {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            rows.append((expires < Date() ? "Expired" : "Expires", formatter.string(from: expires)))
        }
        if !problem.fingerprint.isEmpty {
            // In groups, as certificate viewers show it, to compare by eye.
            let grouped = stride(from: 0, to: problem.fingerprint.count, by: 4).map { start -> String in
                let from = problem.fingerprint.index(problem.fingerprint.startIndex, offsetBy: start)
                let to = problem.fingerprint.index(from, offsetBy: 4, limitedBy: problem.fingerprint.endIndex) ?? problem.fingerprint.endIndex
                return String(problem.fingerprint[from..<to]).uppercased()
            }.joined(separator: " ")
            rows.append(("SHA-256", grouped))
        }
        let table = rows.map { "<tr><th>\(ReaderPage.escape($0.0))</th><td>\(ReaderPage.escape($0.1))</td></tr>" }.joined()
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="color-scheme" content="light dark"><title>This Connection Is Not Private</title>
        <style>
          :root { color-scheme: light dark; --bg: #fbfbfd; --text: #1d1d1f; --muted: #6e6e73; --card: #f0f0f3; --danger: #c9302c; }
          @media (prefers-color-scheme: dark) { :root { --bg: #1e1e20; --text: #f5f5f7; --muted: #a1a1a6; --card: #2c2c2e; --danger: #ff6b63; } }
          body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, system-ui; }
          main { max-width: 600px; margin: 12vh auto; padding: 0 28px; }
          h1 { font-size: 26px; margin: 0 0 12px; color: var(--danger); }
          p { margin: 0 0 14px; }
          .muted { color: var(--muted); }
          .actions { display: flex; gap: 12px; align-items: center; margin: 26px 0; }
          a.button { display: inline-block; padding: 8px 18px; border-radius: 8px; text-decoration: none; font-weight: 600; background: #0a62c9; color: white; }
          a.proceed { color: var(--muted); font-size: 13px; }
          details { background: var(--card); border-radius: 10px; padding: 12px 16px; }
          summary { cursor: default; font-weight: 600; }
          table { border-collapse: collapse; margin-top: 10px; font-size: 13px; }
          th { text-align: left; vertical-align: top; padding: 3px 14px 3px 0; color: var(--muted); font-weight: 500; white-space: nowrap; }
          td { padding: 3px 0; word-break: break-all; }
        </style></head><body><main>
        <h1 id="warning-title">This Connection Is Not Private</h1>
        <p id="warning-site">This page says it is <b>\(site)</b>, but that could not be verified.</p>
        <p id="warning-why">\(ReaderPage.escape(problem.kind.explanation(site: problem.host)))</p>
        <p class="muted">Someone on the network may be pretending to be the site to read what you send it: passwords, messages, card numbers.</p>
        <div class="actions">
          <a class="button" id="warning-back" href="\(scheme)://\(actionHost)/back">Go Back</a>
          <a class="proceed" id="warning-proceed" href="\(scheme)://\(actionHost)/proceed?token=\(ReaderPage.escape(token))">Visit this website anyway</a>
        </div>
        <details><summary>The certificate</summary><table>\(table)</table></details>
        </main></body></html>
        """
    }
}
