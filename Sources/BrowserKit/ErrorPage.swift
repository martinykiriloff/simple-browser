import Foundation

/// The page shown when a load fails: what went wrong in plain words, in the
/// system's light or dark look and its accent colour, with a way to try again.
public enum ErrorPage {
    public struct Explanation: Equatable, Sendable {
        public var title: String
        public var advice: String
    }

    /// NSURLError codes, without Foundation's constants so it builds anywhere.
    public static func explanation(domain: String, code: Int, host: String?) -> Explanation {
        let site = host.map { "“\($0)”" } ?? "this site"
        if domain == "WebKitErrorDomain" {
            switch code {
            case 101: return Explanation(title: "That address can’t be opened here", advice: "The browser has no way to show this kind of address.")
            case 103: return Explanation(title: "That address uses a port that is kept closed", advice: "For safety, web pages are not loaded from this port.")
            default: return Explanation(title: "This page could not be loaded", advice: "Try again in a moment.")
            }
        }
        guard domain == "NSURLErrorDomain" else {
            return Explanation(title: "This page could not be loaded", advice: "Try again in a moment.")
        }
        switch code {
        case -1009: return Explanation(title: "You’re offline", advice: "Connect to the internet and try again.")
        case -1003, -1006: return Explanation(title: "Can’t find \(site)", advice: "Check the address for typos. If it is right, the site may be down, or its name may not be set up.")
        case -1004: return Explanation(title: "\(site.capitalizedFirst) refused the connection", advice: "The site is not answering on this address. Try again in a moment.")
        case -1001: return Explanation(title: "\(site.capitalizedFirst) took too long to respond", advice: "The site is slow or down. Try again in a moment.")
        case -1005: return Explanation(title: "The connection was lost", advice: "Something interrupted the connection. Try again.")
        case -1200, -1201, -1202, -1203, -1204, -1205, -1206: return Explanation(title: "Can’t make a secure connection to \(site)", advice: "The site’s certificate or its encryption could not be checked.")
        case -1022: return Explanation(title: "\(site.capitalizedFirst) is not secure", advice: "This site can only be opened over https.")
        case -1000: return Explanation(title: "That’s not a web address", advice: "Check the address and try again.")
        default: return Explanation(title: "This page could not be loaded", advice: "Try again in a moment.")
        }
    }

    /// The whole page. `detail` is the system's own wording, kept small.
    public static func html(explanation: Explanation, url: String, detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(explanation.title))</title>
        <meta name="color-scheme" content="light dark">
        <style>
          :root { color-scheme: light dark; --bg: #f5f5f7; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: rgba(128,128,128,.3); }
          @media (prefers-color-scheme: dark) { :root { --bg: #1e1e20; --card: #2c2c2e; --text: #f5f5f7; --muted: #98989d; } }
          @media (prefers-contrast: more) { :root { --muted: var(--text); --line: currentColor; } }
          @media (prefers-reduced-motion: no-preference) { a.try { transition: background .15s; } }
          body { margin: 0; background: var(--bg); color: var(--text); font: 15px -apple-system, system-ui; }
          main { max-width: 34em; margin: 18vh auto; padding: 0 24px; }
          h1 { font-size: 1.5em; margin: 0 0 8px; }
          p { margin: 0 0 12px; color: var(--muted); }
          code { word-break: break-all; color: var(--muted); font-size: .9em; }
          a.try { display: inline-block; margin-top: 16px; padding: 8px 18px; border-radius: 8px; border: 1px solid var(--line);
                  background: AccentColor; color: AccentColorText; text-decoration: none; font-weight: 600; }
          a.try:focus-visible { outline: 3px solid color-mix(in srgb, AccentColor 45%, transparent); outline-offset: 2px; }
          details { margin-top: 20px; color: var(--muted); }
        </style></head><body><main>
        <h1>\(escape(explanation.title))</h1>
        <p>\(escape(explanation.advice))</p>
        <a class="try" href="\(escape(url))">Try Again</a>
        <details><summary>Details</summary><p>\(escape(detail))</p><code>\(escape(url))</code></details>
        </main></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
