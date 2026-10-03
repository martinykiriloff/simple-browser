import AppKit
import WebKit
import AgentKit

/// WebMCP (AR-9, threat T5): `document.modelContext` for pages, bridged to
/// the agent server. Flag-gated (Settings → Agents & permissions, or
/// `--agent-webmcp` for scripted runs).
///
/// Three layers, so a page can offer tools but never reach native code:
/// - a page-world shim that defines `document.modelContext` (and the older
///   `navigator.modelContext`) and keeps each tool's `execute` in the page;
/// - a relay in a world of its own (`KeelWebMCP`), the only place the
///   message handler exists; the two talk through CustomEvents whose names
///   carry a nonce made fresh for each document, handed over before any page
///   script runs;
/// - this bridge, which parses what the page says with `PageTool.parse`
///   (caps, origin namespacing) and keeps it in `AgentTrust.webMCP` per tab.
@MainActor
final class WebMCPBridge: NSObject {
    static let shared = WebMCPBridge()
    static let worldName = "KeelWebMCP"
    static let handlerName = "keelWebMCP"
    /// A page tool that has not answered by then is given up on.
    static let callTimeout: Double = 30
    static let maxResultCharacters = 100 * 1024

    let world = WKContentWorld.world(name: worldName)

    /// One per tab: its content controller, and whether the scripts are in it.
    @MainActor
    final class TabHandler: NSObject, WKScriptMessageHandler {
        weak var tab: BrowserWindowController?
        weak var controller: WKUserContentController?
        /// The web view the page's last message came from: the one to run tools in.
        weak var webView: WKWebView?
        var scriptsInstalled = false
        var handlerInstalled = false
        /// The notice for this document is out, or about to be.
        var noticeScheduled = false
        var noticeShown = false

        init(tab: BrowserWindowController, controller: WKUserContentController) {
            self.tab = tab
            self.controller = controller
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            WebMCPBridge.shared.receive(message, from: self)
        }
    }

    private var handlers: [TabHandler] = []
    private var observer: NSObjectProtocol?

    override private init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: .agentTrustDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WebMCPBridge.shared.settingsMayHaveChanged() }
        }
    }

    // MARK: - The flag

    private var trust: AgentTrust? { (NSApp.delegate as? AppDelegate)?.agentTrust }

    /// On when the person switched WebMCP on, or a scripted run asked for it.
    var enabled: Bool {
        guard let trust else { return false }
        return trust.webMCPEnabled
    }

    // MARK: - Installation

    /// Called once from the tab's init. The scripts go in only while WebMCP
    /// is on; switching it on later adds them for the tab's next page.
    func install(into configuration: WKWebViewConfiguration, tab: BrowserWindowController) {
        handlers.removeAll { $0.tab == nil || $0.controller == nil }
        let handler = TabHandler(tab: tab, controller: configuration.userContentController)
        handlers.append(handler)
        if enabled { addScripts(handler) }
    }

    private func addScripts(_ handler: TabHandler) {
        guard let controller = handler.controller, !handler.scriptsInstalled else { return }
        if !handler.handlerInstalled {
            // Only the relay's world can post to native code.
            controller.add(handler, contentWorld: world, name: Self.handlerName)
            handler.handlerInstalled = true
        }
        // Order matters: the relay listens before the shim says hello.
        controller.addUserScript(WKUserScript(source: Self.relaySource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: Self.pageSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        handler.scriptsInstalled = true
    }

    private func settingsMayHaveChanged() {
        guard let trust else { return }
        if enabled {
            handlers.removeAll { $0.tab == nil || $0.controller == nil }
            for handler in handlers where !handler.scriptsInstalled { addScripts(handler) }
        } else if !trust.webMCP.tools.isEmpty {
            // Switched off: no page's tools stay listed. Scripts already in a
            // tab stay until it closes, but nothing they send is taken.
            trust.webMCP = WebMCPRegistry()
            NotificationCenter.default.post(name: .agentTrustDidChange, object: trust)
        }
    }

    // MARK: - Tab lifecycle (called by BrowserWindowController)

    /// A new document in the main frame: the old page's tools go with it.
    func didCommitMainFrame(_ tab: BrowserWindowController) {
        if let handler = handler(for: tab) { handler.noticeScheduled = false; handler.noticeShown = false }
        clear(tab)
    }

    func tabClosed(_ tab: BrowserWindowController) {
        clear(tab)
        if let handler = handler(for: tab), handler.handlerInstalled {
            handler.controller?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
            handler.handlerInstalled = false
        }
        handlers.removeAll { $0.tab == nil || $0.tab === tab }
    }

    private func clear(_ tab: BrowserWindowController) {
        guard let trust else { return }
        let id = tab.tab.rawValue.uuidString
        guard trust.webMCP.tools[id] != nil else { return }
        trust.webMCP.clear(tab: id)
        NotificationCenter.default.post(name: .agentTrustDidChange, object: trust)
    }

    private func handler(for tab: BrowserWindowController) -> TabHandler? {
        handlers.first { $0.tab === tab }
    }

    // MARK: - Registrations from the page

    fileprivate func receive(_ message: WKScriptMessage, from handler: TabHandler) {
        guard enabled, let trust, let tab = handler.tab, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let origin = Self.origin(of: message.frameInfo.securityOrigin)
        // A message from a document the tab has already left is not taken.
        guard let current = tab.currentURL.flatMap(Origin.of), Origin.normalize(origin) == current else { return }
        handler.webView = message.webView
        let id = tab.tab.rawValue.uuidString
        switch kind {
        case "register":
            guard let text = body["tool"] as? String, let value = try? JSONValue.decode(Data(text.utf8)) else { return }
            guard case .success(let tool) = PageTool.parse(value, origin: origin) else { return }
            if trust.webMCP.register(tool, tab: id) != nil { return }
        case "unregister":
            guard let name = body["name"] as? String else { return }
            trust.webMCP.unregister(name, tab: id)
        case "clear":
            trust.webMCP.clear(tab: id)
        default:
            return
        }
        NotificationCenter.default.post(name: .agentTrustDidChange, object: trust)
        scheduleNotice(handler)
    }

    /// The person sees that the page offers tools: once per page, after the
    /// page has had a moment to register them all.
    private func scheduleNotice(_ handler: TabHandler) {
        guard !handler.noticeShown, !handler.noticeScheduled else { return }
        handler.noticeScheduled = true
        Task { @MainActor [weak handler] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let handler, handler.noticeScheduled, !handler.noticeShown, let tab = handler.tab, let trust = self.trust else { return }
            handler.noticeScheduled = false
            let count = trust.webMCP.tools[tab.tab.rawValue.uuidString]?.count ?? 0
            guard count > 0 else { return }
            handler.noticeShown = true
            tab.webMCPToolsChanged(count: count)
        }
    }

    static func origin(of origin: WKSecurityOrigin) -> String {
        let defaultPort = origin.protocol == "https" ? 443 : origin.protocol == "http" ? 80 : 0
        let port = origin.port == 0 || origin.port == defaultPort ? "" : ":\(origin.port)"
        return "\(origin.protocol)://\(origin.host)\(port)"
    }

    // MARK: - Running a tool

    /// `AgentToolbox.webMCPCall`: runs the tool's `execute` in the page and
    /// returns what it gave back, as text. The toolbox marks it untrusted.
    func call(_ tab: BrowserWindowController, _ tool: PageTool, _ arguments: JSONValue) async throws -> String {
        guard enabled else { throw AgentError(.unsupported, "WebMCP is off.") }
        guard let handler = handler(for: tab), let webView = handler.webView else {
            throw AgentError(.noTab, "That tab no longer has the page that offered \(tool.name).")
        }
        guard tab.currentURL.flatMap(Origin.of) == tool.origin else {
            throw AgentError(.navigationFailed, "The tab has left \(tool.origin), so its tool \(tool.name) is gone. Call page_tools.")
        }
        let args = arguments.object == nil ? "{}" : arguments.jsonString
        let script = "return await window.__keelWebMCP.run(name, args, timeout);"
        let parameters: [String: Any] = ["name": tool.name, "args": args, "timeout": Int(Self.callTimeout * 1000) + 1000]
        let reply: Reply = try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            webView.callAsyncJavaScript(script, arguments: parameters, in: nil, in: world) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value):
                        let object = value as? [String: Any] ?? [:]
                        once.resume(.success(Reply(ok: object["ok"] as? Bool == true, value: object["value"] as? String ?? "",
                                                   error: object["error"] as? String ?? "The page gave no answer.",
                                                   timedOut: object["timeout"] as? Bool == true)))
                    case .failure(let error):
                        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                        once.resume(.failure(AgentError(.scriptError, "The page's tool \(tool.name) failed: \(message)")))
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.callTimeout))
                once.resume(.failure(AgentError(.timeout, "The page's tool \(tool.name) did not answer within \(Int(Self.callTimeout)) s.")))
            }
        }
        if reply.ok { return String(reply.value.prefix(Self.maxResultCharacters)) }
        if reply.timedOut {
            throw AgentError(.timeout, "The page's tool \(tool.name) did not answer within \(Int(Self.callTimeout)) s.")
        }
        throw AgentError(.scriptError, "The page's tool \(tool.name) failed: \(reply.error.prefix(2_000))")
    }

    private struct Reply: Sendable {
        var ok: Bool
        var value: String
        var error: String
        var timedOut: Bool
    }

    /// Resumes a continuation the first time only: the answer or the timeout.
    @MainActor
    private final class Once {
        private var continuation: CheckedContinuation<Reply, Error>?
        init(_ continuation: CheckedContinuation<Reply, Error>) { self.continuation = continuation }
        func resume(_ result: Result<Reply, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
