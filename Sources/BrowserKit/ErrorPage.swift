import Foundation

/// The page shown when a load fails: what went wrong in plain words, in the
/// system's light or dark look, with a way to try again.
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

    /// The whole page (Design D, G4-07): a light page in the system's light
    /// look (and a dark one for a person who keeps the system dark), the
    /// title, what it means, Try again, and the details for a developer.
    /// `detail` is the system's own wording, kept in Details.
    public static func html(explanation: Explanation, url: String, detail: String, diagnostics: [(String, String)] = []) -> String {
        let rows = ([("url", url)] + diagnostics).filter { !$0.1.isEmpty }
            .map { "<dt>\(escape($0.0))</dt><dd>\(escape($0.1))</dd>" }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(explanation.title))</title>
        <meta name="color-scheme" content="light dark">
        <style>
          :root { color-scheme: light dark; --page: #FFFFFF; --ink: #1B1D21; --muted: #5A606B; --line: #D7DAE0; --subtle: #F4F5F7;
                  --button: #1B1D21; --on-button: #FFFFFF; }
          @media (prefers-color-scheme: dark) { :root { --page: #12151B; --ink: #E6E8EC; --muted: #9AA1AD; --line: #262C36; --subtle: #171B22;
                  --button: #E6E8EC; --on-button: #0B0D11; } }
          @media (prefers-contrast: more) { :root { --muted: var(--ink); --line: currentColor; } }
          @media (prefers-reduced-motion: no-preference) { a.try { transition: opacity .15s; } }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--page); color: var(--ink); font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                 letter-spacing: -0.005em; }
          main { max-width: 600px; margin: 0 auto; padding: 14vh 24px 48px; }
          .mark { width: 44px; height: 44px; border-radius: 11px; background: var(--subtle); box-shadow: inset 0 0 0 1px var(--line);
                  display: grid; place-items: center; font-size: 20px; font-weight: 700; color: var(--muted); }
          h1 { font-size: 28px; font-weight: 700; letter-spacing: -0.02em; line-height: 1.2; margin: 22px 0 10px; }
          p { margin: 0; color: var(--muted); }
          .actions { display: flex; align-items: center; gap: 10px; margin-top: 24px; }
          .actions .space { flex: 1; }
          a.try { display: inline-flex; align-items: center; height: 36px; padding: 0 18px; border-radius: 8px; background: var(--button);
                  color: var(--on-button); font-weight: 600; font-size: 14px; text-decoration: none; }
          a.try:hover { opacity: .88; }
          a.try:focus-visible { outline: 3px solid color-mix(in srgb, var(--ink) 35%, transparent); outline-offset: 2px; }
          .kbd { font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--muted); border: 1px solid var(--line); border-radius: 5px; padding: 1px 6px; }
          details { margin-top: 28px; border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
          summary { height: 40px; display: flex; align-items: center; gap: 8px; padding: 0 14px; background: var(--subtle); font-weight: 600; font-size: 13px; cursor: default; }
          summary::-webkit-details-marker { display: none; }
          summary::before { content: "▸"; font-size: 10px; color: var(--muted); }
          details[open] summary::before { content: "▾"; }
          details > p { padding: 12px 14px 0; border-top: 1px solid var(--line); font-size: 13px; }
          dl { margin: 0; padding: 8px 14px 12px; display: grid; grid-template-columns: max-content 1fr; gap: 0 18px;
               font: 12px/1.7 ui-monospace, "SF Mono", Menlo, monospace; }
          dt { color: var(--muted); } dd { margin: 0; word-break: break-all; }
          code { word-break: break-all; }
        </style></head><body><main>
        <div class="mark" aria-hidden="true">!</div>
        <h1>\(escape(explanation.title))</h1>
        <p>\(escape(explanation.advice))</p>
        <div class="actions"><a class="try" href="\(escape(url))">Try Again</a><span class="space"></span><span class="kbd" title="Reload">⌘R</span></div>
        <details><summary>Details</summary><p>\(escape(detail))</p><dl>\(rows)</dl></details>
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
