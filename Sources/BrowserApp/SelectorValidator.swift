import WebKit

/// Asks WebKit's own CSS parser which selectors it accepts.
///
/// WebKit compiles a hiding rule without looking at its selector; a selector
/// its parser rejects then makes the rule hide nothing, along with every
/// selector sharing the rule (measured). So before selectors are put
/// together, each is tried with `querySelector` in a page that has nothing
/// in it and can reach nothing: no network, no storage, its own process.
@MainActor
final class SelectorValidator {
    private var webView: WKWebView?

    /// The selectors WebKit refuses; nil if it could not be asked.
    func refused(among selectors: [String]) async -> Set<String>? {
        guard !selectors.isEmpty else { return [] }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        defer { self.webView = nil }
        webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        for _ in 0..<100 where webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }

        var refused: Set<String> = []
        // In batches: one call carrying a megabyte of selectors is a call
        // that can fail whole.
        for start in stride(from: 0, to: selectors.count, by: 2_000) {
            let batch = Array(selectors[start ..< min(start + 2_000, selectors.count)])
            let script = """
            const bad = [];
            for (let i = 0; i < selectors.length; i++) {
              try { document.querySelector(selectors[i]); } catch (e) { bad.push(i); }
            }
            return bad;
            """
            guard let indexes = try? await webView.callAsyncJavaScript(script, arguments: ["selectors": batch], in: nil, contentWorld: .defaultClient) as? [NSNumber] else {
                return nil
            }
            for index in indexes where batch.indices.contains(index.intValue) { refused.insert(batch[index.intValue]) }
        }
        return refused
    }
}
