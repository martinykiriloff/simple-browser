import AppKit
import WebKit

/// Design D ("Slim console"): what the restyled pages and panels need from
/// the app.
extension AppDelegate {

    func configureRestyle() {
        // The start page's "Recent agent sessions", from the trust layer.
        StartPageSchemeHandler.agentSessions = { [weak self] in self?.agentTrust.history ?? [] }
        // The tab a start page is loading in: its profile, and whether it is
        // an agent's sandbox.
        StartPageSchemeHandler.browserForWebView = { [weak self] webView in
            self?.browserControllers.first { $0.pageWebView === webView }
        }
        // The command palette's Agents group and agent tabs.
        CommandPaletteController.agentTabID = { [weak self] tabID in
            self?.browserControllers.first { "tab:\($0.tab)" == tabID }?.agentSessionID
        }
        CommandPaletteController.runningAgents = { [weak self] in
            self?.agentTrust.sessions.values.filter { $0.session.state != .stopped }.count ?? 0
        }
    }
}
