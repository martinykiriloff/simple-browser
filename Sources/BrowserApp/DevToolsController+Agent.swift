import AppKit
import WebKit
import AgentKit
import BrowserKit

/// The agent-native parts of DevTools:
///
/// - the Snapshot panel: the exact text the `snapshot` tool gives an agent
///   for this tab, its tokens, and the element behind each ref;
/// - actor tags: when the person last touched the page and when agent calls
///   ran, so console and network entries can say who caused them;
/// - the Agent panel's session header (id, elapsed time, waiting approvals);
/// - Storage's "Compare with…": cookies (and, when a page is open there,
///   localStorage) of another profile or an agent sandbox.
extension DevToolsController {

    static let agentViewMethods: Set<String> = [
        "Agent.snapshot", "Agent.spotlight", "Agent.clearSpotlight", "Agent.session",
        "Actors.get", "Storage.compareTargets", "Storage.compare",
    ]

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// The tab this DevTools inspects.
    var browser: BrowserWindowController? {
        app?.controllers.first { $0.devTools === self }
    }

    /// Called once the controller exists: human input in the page is
    /// passed to the UI as it happens (the UI keeps the times).
    func installActorHooks() {
        (page as? BrowserWebView)?.onHumanInput = { [weak self] time in
            self?.emit("Actors.humanInput", ["time": time])
        }
    }

    func removeActorHooks() {
        (page as? BrowserWebView)?.onHumanInput = nil
    }

    func handleAgentView(_ method: String, _ params: [String: Any]) async throws -> Any? {
        switch method {
        case "Agent.snapshot":      return try await agentSnapshot(interactiveOnly: params["interactiveOnly"] as? Bool ?? false)
        case "Agent.spotlight":
            guard let browser, let toolbox = app?.agentServer.toolbox, let ref = params["ref"] as? String else { throw DevToolsError.noPage }
            let result = try await toolbox.automation(browser, "spotlight", ["ref": .string(ref), "label": .string("\(ref) · DevTools")])
            return result.anyValue
        case "Agent.clearSpotlight":
            guard let browser, let toolbox = app?.agentServer.toolbox else { return false }
            _ = try? await toolbox.automation(browser, "clearSpotlight")
            return true
        case "Agent.session":       return agentSession() ?? NSNull()
        case "Actors.get":          return actorTimes()
        case "Storage.compareTargets": return compareTargets()
        case "Storage.compare":     return try await compare(target: params["target"] as? String ?? "")
        default:                    throw DevToolsError.unknownRequest
        }
    }

    // MARK: - Snapshot

    /// What `snapshot` returns to a paired agent for this tab: the toolbox's
    /// text, cut to the session's token budget, marked as untrusted page
    /// content. Taken without side effects on the agent's own state.
    private func agentSnapshot(interactiveOnly: Bool) async throws -> [String: Any] {
        guard let browser, let app else { throw DevToolsError.noPage }
        let toolbox = app.agentServer.toolbox
        var arguments: [String: JSONValue] = ["tabId": .string(AgentToolbox.shortID(browser))]
        if interactiveOnly { arguments["interactiveOnly"] = .bool(true) }

        // Not the agent's call: no "agent is controlling this tab" notice, and
        // the agent's `diff` baseline stays what it last saw.
        let hadState = browser.agentState != nil
        let state = browser.agentState ?? AgentTabState()
        browser.agentState = state
        let announced = state.announced
        let saved = state.snapshots
        state.announced = true
        defer {
            state.announced = announced
            state.snapshots = saved
            if !hadState && state.calls.isEmpty { browser.agentState = nil }
        }
        let raw = try await toolbox.snapshot(.object(arguments))
        var text = raw.text

        let live = app.agentTrust.live(for: browser)
        let budget = live?.session.budgets.snapshotTokens ?? Budgets.default.snapshotTokens
        let cut = TokenEstimate.truncate(text, toTokens: budget)
        text = cut.text
        var notes = ["(\(TokenEstimate.format(cut.tokens))\(cut.truncated ? ", cut to the session's budget" : ""))"]
        if let warning = InjectionScanner.warning(for: InjectionScanner.scan(text)) { notes.insert(warning, at: 0) }
        let origin = browser.currentURL.flatMap(Origin.of)
        let delivered = (notes + [Untrusted.wrap(text, origin: origin)]).joined(separator: "\n")

        // The page as a full-DOM dump would hand it over, for comparison.
        let sizeScript = """
        const s = document.documentElement ? document.documentElement.outerHTML : "";
        let other = 0;
        for (let i = 0; i < s.length; i++) if (s.charCodeAt(i) > 127) other++;
        return [s.length, other];
        """
        var domChars = 0, domTokens = 0
        if let pair = try? await toolbox.script(browser, sizeScript, arguments: [:], world: .defaultClient) as? [NSNumber], pair.count == 2 {
            domChars = pair[0].intValue
            let other = pair[1].intValue
            domTokens = max(1, Int((Double(domChars - other) / 4 + Double(other) / 1.5).rounded(.up)))
        }
        return [
            "text": delivered, "tokens": TokenEstimate.count(delivered), "treeTokens": cut.tokens, "truncated": cut.truncated,
            "budget": budget, "session": live?.session.id ?? NSNull(), "client": live?.session.clientName ?? NSNull(),
            "domChars": domChars, "domTokens": domTokens, "url": browser.currentURL?.absoluteString ?? "",
            "time": (Date().timeIntervalSince1970 * 1000).rounded(),
        ]
    }

    // MARK: - Agent session

    private func agentSession() -> [String: Any]? {
        guard let browser, let trust = app?.agentTrust, let live = trust.live(for: browser) else { return nil }
        let s = live.session
        let state: String
        switch s.state {
        case .running: state = "running"
        case .paused: state = "paused"
        case .needsHuman: state = "waiting"
        case .stopped: state = "stopped"
        }
        let waiting: [[String: Any]] = trust.approvals.filter { $0.sessionID == s.id }.map {
            ["tool": $0.tool, "target": $0.target, "ref": $0.ref ?? NSNull(), "time": ($0.created.timeIntervalSince1970 * 1000).rounded(),
             "fromPage": $0.pageInstruction != nil]
        }
        return [
            "id": s.id, "client": s.clientName, "mode": s.mode.kind.rawValue, "state": state,
            "started": (s.started.timeIntervalSince1970 * 1000).rounded(), "actions": s.actions,
            "budget": s.budgets.snapshotTokens, "waiting": waiting,
        ]
    }

    // MARK: - Actors

    private func actorTimes() -> [String: Any] {
        let human = (page as? BrowserWebView)?.humanInputTimes ?? []
        let calls: [[Double]] = (browser?.agentState?.calls ?? []).compactMap { call in
            guard let time = call["time"]?.double else { return nil }
            return [time, time + (call["ms"]?.double ?? 0)]
        }
        return ["human": human, "agent": calls]
    }

    // MARK: - Storage compare

    private func pageOrigin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }

    private func compareTargets() -> [[String: Any]] {
        guard let app else { return [] }
        let current = browser
        var targets: [[String: Any]] = []
        for profile in app.profiles.profiles {
            if let current, !current.isPrivate, current.profile.dataStoreIdentifier == profile.dataStoreIdentifier { continue }
            targets.append(["id": "profile:" + profile.dataStoreIdentifier.uuidString, "label": "Profile · " + profile.name, "kind": "profile"])
        }
        for live in app.agentTrust.sessions.values.sorted(by: { $0.session.started < $1.session.started }) {
            guard let sandbox = live.sandbox, current?.privateSession !== sandbox else { continue }
            targets.append(["id": "session:" + live.session.id, "label": "Agent sandbox · session \(live.session.id) · \(live.session.clientName)", "kind": "sandbox"])
        }
        return targets
    }

    /// The other side's cookies for this page's host, and its localStorage
    /// for this origin when one of its tabs has that origin open.
    private func compare(target: String) async throws -> [String: Any] {
        guard let app, let url = page?.url else { throw DevToolsError.noPage }
        var store: WKWebsiteDataStore?
        var tabs: [BrowserWindowController] = []
        var label = target
        if target.hasPrefix("profile:"), let id = UUID(uuidString: String(target.dropFirst(8))) {
            store = WKWebsiteDataStore(forIdentifier: id)
            tabs = app.controllers.filter { !$0.isPrivate && $0.profile.dataStoreIdentifier == id }
            label = "Profile · " + (app.profiles.profiles.first { $0.dataStoreIdentifier == id }?.name ?? "?")
        } else if target.hasPrefix("session:"), let live = app.agentTrust.live(String(target.dropFirst(8))) {
            store = live.sandbox?.dataStore
            tabs = live.openTabs
            label = "Agent sandbox · session \(live.session.id)"
        }
        guard let store else { throw DevToolsError.protocolUnavailable("that profile or session is gone") }
        let host = url.host()?.lowercased() ?? ""
        let cookies = await store.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return host.isEmpty || host == bare || host.hasSuffix("." + bare)
        }.map { cookie -> [String: Any] in
            ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
             "expires": cookie.expiresDate.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
             "httpOnly": cookie.isHTTPOnly, "secure": cookie.isSecure, "sameSite": cookie.sameSitePolicy?.rawValue ?? ""]
        }
        var result: [String: Any] = ["label": label, "cookies": cookies]
        let origin = pageOrigin(url)
        if let other = tabs.first(where: { $0 !== browser && pageOrigin($0.currentURL) == origin && !$0.isHibernated }),
           let entries = try? await other.pageWebView.callAsyncJavaScript(
               "const out = []; for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); out.push([k, localStorage.getItem(k)]); } return out;",
               arguments: [:], in: nil, contentWorld: .defaultClient) {
            result["local"] = entries
            result["localSource"] = other.currentURL?.absoluteString ?? ""
        } else {
            result["local"] = NSNull()
        }
        return result
    }
}
