import AppKit

/// What the person sees of WebMCP: a page that offers tools to agents says so.
extension BrowserWindowController {
    /// Called by `WebMCPBridge` once per page, after it has registered its tools.
    func webMCPToolsChanged(count: Int) {
        guard count > 0 else { return }
        showNotice("This page offers \(count) tool\(count == 1 ? "" : "s") to agents")
    }
}
