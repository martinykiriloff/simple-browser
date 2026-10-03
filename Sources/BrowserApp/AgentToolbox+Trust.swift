import AppKit
import AgentKit
import BrowserKit

/// The session a tool call belongs to, for the length of the call.
enum AgentContext {
    @TaskLocal static var sessionID: String?
}

/// Every call from a paired client passes through here: the session's
/// state and budgets, the origin limits, the approval of consequential
/// actions, the marking of page content as untrusted, and the log.
extension AgentToolbox {

    /// Tools whose results carry text a page controls.
    static let pageContentTools: Set<String> = [
        "snapshot", "get_page_content", "evaluate", "console_messages", "network_requests", "network_request", "inspect_element",
        "application_data", "storage", "diagnose", "devtools_selection", "page_tools", "call_page_tool", "wait_for", "run_audit",
    ]

    /// Tools that act on an element and may be consequential because of it.
    static let elementTools: Set<String> = ["click", "fill", "type_text", "press_key", "fill_form", "drag"]

    func call(_ name: String, _ arguments: JSONValue, live: AgentTrust.Live, client: PairedClient) async -> MCPToolResult {
        await AgentContext.$sessionID.withValue(live.session.id) {
            await gatedCall(name, arguments, live: live, client: client)
        }
    }

    /// Calls made without the trust layer (the app's own self-tests).
    func call(_ name: String, _ arguments: JSONValue) async -> MCPToolResult {
        await callUntrusted(name, arguments)
    }

    private func gatedCall(_ name: String, _ a: JSONValue, live: AgentTrust.Live, client: PairedClient) async -> MCPToolResult {
        guard let trust else { return await callUntrusted(name, a) }
        clientName = live.session.clientName
        let started = Date()
        let catalog = BrowserTools.tool(named: name)
        let pageTool = catalog == nil ? pageToolFor(name, live: live) : nil
        let readOnly = catalog?.readOnly ?? pageTool?.tool.readOnly ?? false
        let target = try? tab(a)
        var destination: URL?
        if name == "navigate", (a["action"]?.string ?? "goto") == "goto", let text = a["url"]?.string { destination = BrowserSettings.destination(for: text) }
        if name == "new_tab", let text = a["url"]?.string, !text.isEmpty { destination = BrowserSettings.destination(for: text) }

        func finish(_ result: MCPToolResult, outcome: AuditEntry.Outcome, code: String? = nil, summary: String? = nil) -> MCPToolResult {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            trust.audit(live, tool: name, arguments: a, url: target?.currentURL ?? destination, outcome: outcome, errorCode: code,
                        summary: summary, milliseconds: ms, resultTokens: TokenEstimate.count(result.text))
            onActivity?("\(live.session.clientName) · \(name)\(result.isError ? " ✗" : "") · \(ms) ms")
            return result
        }

        // Session state, time, budgets and origins.
        var session = live.session
        let admission = session.admit(.init(tool: name, readOnly: readOnly, pageURL: target?.currentURL, destination: destination))
        live.session = session
        if let refused = admission {
            target?.syncAgentChrome()
            return finish(refused.result, outcome: .blocked, code: refused.code.rawValue,
                          summary: refused.code == .originBlocked ? "Blocked: \(refused.message)" : nil)
        }

        // Consequential? Decide with what the page says about the target.
        if !readOnly, let decision = await approve(name, a, live: live, tab: target, pageTool: pageTool?.tool) {
            return finish(decision.result, outcome: decision.code == .approvalDenied || decision.code == .approvalTimeout ? .denied : .blocked,
                          code: decision.code.rawValue)
        }

        // Run it.
        let urlBefore = target?.currentURL
        var result: MCPToolResult
        do {
            if let pageTool {
                result = try await callPageTool(pageTool.tab, pageTool.tool, a)
            } else {
                result = try await performTrusted(name, a, live: live)
            }
        } catch let error as AgentError {
            result = error.result
        } catch {
            let message = Self.message(for: error)
            result = AgentError(AgentError.classify(message), message).result
        }
        if !result.isError {
            result = shape(result, tool: name, arguments: a, live: live, urlBefore: urlBefore)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        record(name, a, result, started: started, milliseconds: ms)
        if let tab = (try? tab(a)) ?? target, Self.elementTools.contains(name), !result.isError, let ref = a["ref"]?.string {
            flash(tab, ref: ref, label: "\(ref) · \(live.session.clientName)")
        }
        let code = result.structured?["error"]?["code"]?.string
        return finish(result, outcome: result.isError ? .error : .ok, code: code)
    }

    // MARK: - Approval

    /// Nil when the call may go ahead; else the refusal the agent gets.
    private func approve(_ name: String, _ a: JSONValue, live: AgentTrust.Live, tab: BrowserWindowController?, pageTool: PageTool?) async -> AgentError? {
        guard let trust else { return nil }
        var risk = ActionClassifier.risk(tool: name, arguments: a, mode: live.session.mode.kind)
        var targetText = ""
        var ref = a["ref"]?.string
        if let pageTool, pageTool.consequential {
            risk = .consequential(.send, reason: "Runs “\(pageTool.name)”, a tool the page provides that says it changes something.")
            targetText = "the page tool “\(pageTool.name)”"
        }
        if let tab, Self.elementTools.contains(name) {
            if name == "fill_form" {
                for field in a["fields"]?.array ?? [] {
                    guard let facts = try? await elementFacts(tab, field) else { continue }
                    let fieldRisk = ActionClassifier.risk(tool: "fill", element: facts, typedText: field["value"]?.string)
                    if fieldRisk != .safe { risk = fieldRisk; targetText = "“\(facts.name)” [ref=\(facts.ref ?? "?")]"; ref = facts.ref; break }
                }
            } else {
                // A target that cannot be found fails on its own, with its own error.
                guard let facts = try? await elementFacts(tab, Self.hasTarget(a) ? a : [:]) else { return nil }
                let typed = a["value"]?.string ?? a["text"]?.string ?? a["key"]?.string
                let elementRisk = ActionClassifier.risk(tool: name, element: facts, typedText: typed)
                if elementRisk != .safe { risk = elementRisk }
                targetText = facts.role == "document" ? "the page" : "\(facts.role) “\(facts.name)”" + (facts.ref.map { " [ref=\($0)]" } ?? "")
                ref = ref ?? facts.ref
                // Typing that submits a form with card or password fields.
                if a["submit"]?.bool == true, risk == .safe {
                    let submitRisk = ActionClassifier.risk(tool: "click", element: ElementFacts(role: "button", name: "submit", type: "submit",
                                                                                                formMethod: facts.formMethod, formFields: facts.formFields))
                    if submitRisk != .safe { risk = submitRisk }
                }
            }
        }
        if name == "handle_dialog", let tab, let dialog = tab.pageDialog, a["accept"]?.bool ?? true {
            let dialogRisk = ActionClassifier.risk(tool: "click", element: ElementFacts(role: "button", name: dialog.message))
            if dialogRisk != .safe { risk = dialogRisk; targetText = "OK in the dialog “\(dialog.message.prefix(80))”" }
        }
        if name == "upload_files" { targetText = (a["paths"]?.array?.compactMap(\.string).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).map { "\($0)" } ?? "files" }
        if name == "evaluate" { targetText = "JavaScript on the page" }
        if name == "storage" { targetText = "cookies or storage" }

        // Text on the page addressed to agents makes any acting step ask.
        let instruction = tab?.agentState?.injection
        if risk == .safe, instruction != nil, trust.settings.pageInstructionsAlwaysAsk, Self.elementTools.contains(name) {
            risk = .consequential(.send, reason: "This page contains text that tries to instruct AI agents, so every action on it asks first.")
        }
        guard risk != .safe else { return nil }
        let origin = tab?.currentURL.flatMap(Origin.of)
        if let refusal = live.session.refusal(risk, origin: origin, rules: trust.rules) { return refusal }
        guard live.session.needsApproval(risk, origin: origin, rules: trust.rules) else { return nil }
        if targetText.isEmpty { targetText = AuditSummary.describe(tool: name, arguments: a).lowercased() }

        if let tab, ref != nil || Self.hasTarget(a) {
            _ = try? await automation(tab, "spotlight", .object(Self.targetParams(a).object!.merging(["label": .string("\(ref ?? "") · \(live.session.clientName)"), "waiting": true]) { x, _ in x }))
        }
        let decision = await trust.requestApproval(live, tool: name, risk: risk, origin: origin, target: targetText, ref: ref, tab: tab, pageInstruction: instruction)
        if let tab { _ = try? await automation(tab, "clearSpotlight") }
        switch decision {
        case .allowOnce, .allowOnOrigin:
            trust.audit(live, tool: name, arguments: a, url: tab?.currentURL, outcome: .approved, summary: "You allowed: \(targetText)")
            return nil
        case .deny:
            return AgentError(.approvalDenied, "The person denied this action (\(risk.kind?.label ?? "a consequential action")). Do not retry it; tell them what you were trying to do, or continue another way.")
        case .timedOut:
            return AgentError(.approvalTimeout, "The person did not answer within \(trust.settings.approvalTimeoutSeconds) s, so the action was not taken. The tab stays paused at this step.")
        case .stop:
            return AgentError(.sessionStopped, "The person stopped this agent and revoked its access.")
        }
    }

    func elementFacts(_ tab: BrowserWindowController, _ a: JSONValue) async throws -> ElementFacts {
        let value = try await automation(tab, "facts", Self.targetParams(a))
        return ElementFacts(role: value["role"]?.string ?? "", name: value["name"]?.string ?? "", type: value["type"]?.string,
                            autocomplete: value["autocomplete"]?.string, formMethod: value["formMethod"]?.string,
                            formAction: value["formAction"]?.string, formFields: value["formFields"]?.array?.compactMap(\.string) ?? [],
                            ref: value["ref"]?.string)
    }

    /// The amber ring on what was just acted on, for a moment.
    private func flash(_ tab: BrowserWindowController, ref: String, label: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.automation(tab, "spotlight", ["ref": .string(ref), "label": .string(label)])
            try? await Task.sleep(for: .milliseconds(1400))
            _ = try? await self.automation(tab, "clearSpotlight")
        }
    }

    // MARK: - Results

    /// Page text marked untrusted, snapshots held to the budget, injection
    /// warnings, and the structured outcome.
    private func shape(_ result: MCPToolResult, tool: String, arguments a: JSONValue, live: AgentTrust.Live, urlBefore: URL?) -> MCPToolResult {
        var shaped = result
        let tab = try? tab(a)
        let origin = tab?.currentURL.flatMap(Origin.of)
        if Self.pageContentTools.contains(tool) || tool.hasPrefix("webmcp__") {
            var text = result.text
            var notes: [String] = []
            if tool == "snapshot" {
                let budget = a["maxTokens"]?.int ?? live.session.budgets.snapshotTokens
                let cut = TokenEstimate.truncate(text, toTokens: budget)
                text = cut.text
                notes.append("(\(TokenEstimate.format(cut.tokens))\(cut.truncated ? ", cut to the session's budget" : ""))")
            }
            if tool == "snapshot" || tool == "get_page_content" {
                let findings = InjectionScanner.scan(text)
                if let warning = InjectionScanner.warning(for: findings) {
                    notes.insert(warning, at: 0)
                    tab?.agentState?.injection = findings.first?.excerpt
                    if let tab { trust?.reportInjection(live, tab: tab, findings: findings) }
                } else if a["ref"] == nil, a["selector"] == nil {
                    tab?.agentState?.injection = nil
                }
            }
            var content: [MCPToolResult.Content] = notes.map { .text($0) }
            content.append(.text(Untrusted.wrap(text, origin: origin)))
            content.append(contentsOf: result.content.filter { if case .image = $0 { return true } else { return false } })
            shaped = MCPToolResult(content, isError: false, structured: result.structured)
        }
        var structured: [String: JSONValue] = (result.structured?.object) ?? [:]
        structured["ok"] = true
        if let tab {
            structured["tabId"] = .string(Self.shortID(tab))
            if let url = tab.currentURL?.absoluteString { structured["url"] = .string(url) }
            structured["navigated"] = .bool(urlBefore != nil && tab.currentURL != urlBefore)
            if let dialog = tab.pageDialog { structured["dialog"] = .string(dialog.kind.rawValue) }
        }
        structured["actionsLeft"] = .number(Double(live.session.actionsLeft))
        structured["tokens"] = .number(Double(TokenEstimate.count(shaped.text)))
        shaped.structured = .object(structured)
        return shaped
    }

    // MARK: - Session tools

    func performTrusted(_ name: String, _ a: JSONValue, live: AgentTrust.Live) async throws -> MCPToolResult {
        switch name {
        case "session_info": return sessionInfo(live)
        case "session_events": return sessionEvents(live, a)
        case "request_human": return try await requestHuman(live, a)
        case "page_tools": return try pageTools(live)
        case "call_page_tool":
            guard let found = pageToolFor(a["name"]?.string ?? "", live: live) else {
                throw AgentError(.invalidArguments, "No page in your tabs offers a tool named \(a["name"]?.string ?? ""). Call page_tools.")
            }
            return try await callPageTool(found.tab, found.tool, a["arguments"] ?? [:])
        default:
            return try await perform(name, a)
        }
    }

    private func sessionInfo(_ live: AgentTrust.Live) -> MCPToolResult {
        let s = live.session
        let state: String
        switch s.state {
        case .running: state = "running"
        case .paused: state = "paused"
        case .needsHuman(let reason): state = "waiting for the person: \(reason)"
        case .stopped: state = "stopped"
        }
        let identity = s.mode.kind == .sandbox
            ? "sandbox: a fresh in-memory profile with none of the person's cookies, logins or history; wiped when the session ends"
            : "borrowed: the person's signed-in session, on \(s.mode.origins.joined(separator: ", ")) only"
        let lines = [
            "Session \(s.id) · \(s.clientName) · \(state)",
            "Identity: \(identity)",
            s.allowedOrigins.isEmpty ? "Origins: any (sandbox)" : "Allowlist: \(s.allowedOrigins.joined(separator: ", "))",
            "Actions: \(s.actions) of \(s.budgets.maxActions) · navigations ≤ \(s.budgets.navigationsPerMinute)/min · snapshots ≤ \(s.budgets.snapshotTokens) tokens",
            "Tabs: \(live.openTabs.count) of \(s.budgets.maxTabs) · expires \(s.expires.formatted(date: .omitted, time: .shortened))",
            "Approvals: \(s.policy.label) · \(s.approved) allowed, \(s.denied) denied",
        ]
        return MCPToolResult([.text(lines.joined(separator: "\n"))], structured: [
            "ok": true, "session": .string(s.id), "mode": .string(s.mode.kind.rawValue), "state": .string(state),
            "origins": .array(s.mode.origins.map(JSONValue.string)), "actionsLeft": .number(Double(s.actionsLeft)),
            "expires": .string(ISO8601DateFormatter().string(from: s.expires)), "lastEventId": .number(Double(live.log.lastID)),
        ])
    }

    private func sessionEvents(_ live: AgentTrust.Live, _ a: JSONValue) -> MCPToolResult {
        let entries = live.log.after(a["afterId"]?.int ?? 0, limit: min(a["limit"]?.int ?? 50, 200))
        let lines = entries.map { "#\($0.id) \($0.time.formatted(date: .omitted, time: .standard)) \($0.outcome.rawValue) \($0.summary)" }
        return MCPToolResult([.text(lines.isEmpty ? "No new events." : lines.joined(separator: "\n"))], structured: [
            "ok": true, "lastEventId": .number(Double(entries.last?.id ?? live.log.lastID)),
            "events": .array(entries.map { ["id": .number(Double($0.id)), "tool": .string($0.tool), "outcome": .string($0.outcome.rawValue),
                                            "summary": .string($0.summary), "errorCode": $0.errorCode.map(JSONValue.string) ?? .null] }),
        ])
    }

    private func requestHuman(_ live: AgentTrust.Live, _ a: JSONValue) async throws -> MCPToolResult {
        guard let trust else { throw AgentError(.internalError, "No trust layer") }
        let tab = try? tab(a)
        let message = String((a["message"]?.string ?? "Please take over.").prefix(200))
        let reason = a["reason"]?.string ?? "other"
        trust.audit(live, tool: "request_human", arguments: a, url: tab?.currentURL, outcome: .waiting, summary: "Asked you to take over: \(message)")
        let note = await trust.handOver(live, reason: reason, message: message, tab: tab, timeout: Double(a["timeoutMs"]?.int ?? 300_000) / 1000)
        if note == "timeout" {
            throw AgentError(.needsHuman, "The person has not handed control back yet. Call request_human again or wait.")
        }
        return .text("The person handed control back. " + (tab.map { pageLine($0) } ?? ""))
    }

    // MARK: - WebMCP

    func pageToolFor(_ name: String, live: AgentTrust.Live) -> (tab: BrowserWindowController, tool: PageTool)? {
        guard let trust, trust.webMCPEnabled else { return nil }
        let tabs = live.openTabs
        guard let found = trust.webMCP.find(name, in: tabs.map { $0.tab.rawValue.uuidString }),
              let tab = tabs.first(where: { $0.tab.rawValue.uuidString == found.tab }) else { return nil }
        return (tab, found.tool)
    }

    private func pageTools(_ live: AgentTrust.Live) throws -> MCPToolResult {
        guard let trust, trust.webMCPEnabled else {
            throw AgentError(.unsupported, "WebMCP is off. The person can turn it on in Settings → Agents & permissions.")
        }
        var lines: [String] = []
        for tab in live.openTabs {
            for tool in trust.webMCP.all(in: [tab.tab.rawValue.uuidString]) {
                lines.append("- \(tool.qualifiedName) (tab \(Self.shortID(tab)), \(tool.readOnly ? "read-only" : "asks first")): \(tool.description)")
            }
        }
        return .text(lines.isEmpty ? "No page in your tabs offers WebMCP tools." : lines.joined(separator: "\n"))
    }

    func callPageTool(_ tab: BrowserWindowController, _ tool: PageTool, _ arguments: JSONValue) async throws -> MCPToolResult {
        guard let bridge = webMCPCall else { throw AgentError(.unsupported, "WebMCP is not available in this build.") }
        let output = try await bridge(tab, tool, arguments)
        return .text("Result of \(tool.name) from \(tool.origin):\n" + output)
    }
}

extension AgentTrust {
    /// Text on a page that tries to instruct agents: logged, and shown to the person (G2-07).
    func reportInjection(_ live: Live, tab: BrowserWindowController, findings: [InjectionScanner.Finding]) {
        guard let first = findings.first, tab.agentState?.injectionShown != first.excerpt else { return }
        tab.agentState?.injectionShown = first.excerpt
        audit(live, tool: "untrusted_content", arguments: ["phrase": .string(first.phrase)], url: tab.currentURL, outcome: .blocked,
              summary: "Instruction in page content flagged: “\(first.phrase)”")
        tab.showAgentInjectionNotice(first, client: live.session.clientName)
    }
}
