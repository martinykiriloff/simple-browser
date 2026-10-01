import AppKit
import WebKit
import AgentKit
import InspectKit

/// The tools that reach into what DevTools can do: audits, request mocking,
/// heap snapshots, application data, what the person has selected, and the
/// one-call diagnosis agents should start with.
extension AgentToolbox {

    // MARK: - Plumbing

    /// DevTools for the tab, shown (blocking, overrides and rendering emulation
    /// apply only while it is, as in Chrome) and attached to the inspector
    /// protocol when that is available.
    func openTools(_ tab: BrowserWindowController, panel: String?) async throws -> DevToolsController {
        let fresh = tab.devTools == nil
        if !tab.isDevToolsVisible || panel != nil { tab.showDevTools(panel: panel) }
        guard let tools = tab.devTools else { throw ToolError("DevTools could not be opened for this tab") }
        if fresh { try await waitUntil(timeout: 10) { !tools.view.isLoading } }
        // The protocol attaches once the UI reports ready; a failed attach leaves a reason here.
        try? await waitUntil(timeout: 8) { tools.protocolState != "pending" }
        return tools
    }

    /// A method of the on-demand tools agent (audits, IndexedDB, caches,
    /// manifest, service workers, animations), loaded into the page first.
    func toolsAgent(_ tab: BrowserWindowController, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let source = try InspectorAgent.onDemandSource(.tools)
        let body = """
        if (!window.__sbAgent) return { __automationError: "The inspector agent is not in this page (it may still be loading)" };
        if (!window.__sbAgent.has("Tools.loaded")) { \(source) }
        try { return await window.__sbAgent.handle(method, params); }
        catch (e) { return { __automationError: String(e && e.message || e) }; }
        """
        let result = JSONValue(any: try await script(tab, body, arguments: ["method": method, "params": params.anyValue], world: world))
        if let failure = result["__automationError"]?.string { throw ToolError(failure) }
        return result
    }

    /// Lines removed and added between two snapshots, in the new one's order.
    static func lineDiff(old: String, new: String) -> [String] {
        var remaining: [String: Int] = [:]
        for line in old.split(separator: "\n", omittingEmptySubsequences: false) { remaining[String(line), default: 0] += 1 }
        var added: [String] = []
        for line in new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let count = remaining[line], count > 0 { remaining[line] = count - 1 } else { added.append("+ " + line) }
        }
        var removed: [String] = []
        for line in old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let count = remaining[line], count > 0 { remaining[line] = count - 1; removed.append("- " + line) }
        }
        return removed + added
    }

    static func pretty(_ value: JSONValue, limit: Int = 40_000) -> String {
        let text = String(decoding: value.encoded(pretty: true), as: UTF8.self)
        return text.count > limit ? String(text.prefix(limit)) + "\n…(truncated)" : text
    }

    // MARK: - diagnose

    func diagnose(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let tabArgument: JSONValue = ["tabId": .string(Self.shortID(tab))]
        var sections: [String] = ["# Diagnosis — \(title(of: tab).isEmpty ? "(untitled)" : title(of: tab))", tab.currentURL?.absoluteString ?? ""]
        var summary: [String] = []

        // Console errors of the current document, grouped.
        var groups: [(message: String, count: Int, uncaught: Bool, location: String, firstID: Int)] = []
        var warnings = 0
        for recorded in recorder.events where recorded.tab == tab.tab {
            switch recorded.event {
            case .navigation(let event) where event.phase == .committed:
                groups = []; warnings = 0
            case .console(let entry) where entry.type != "command" && entry.type != "result":
                if entry.level == .warn { warnings += 1 }
                guard entry.level == .error else { continue }
                let message = String(entry.message.prefix(300))
                if let index = groups.firstIndex(where: { $0.message == message }) { groups[index].count += 1; continue }
                let frame = entry.stack.first { $0.url != nil }
                groups.append((message, 1, entry.isUncaught, frame.map { InspectorEventFormatter.describe($0) } ?? "", recorded.sequence))
            default: break
            }
        }
        let errorCount = groups.reduce(0) { $0 + $1.count }
        summary.append("\(errorCount) console error\(errorCount == 1 ? "" : "s")\(groups.count < errorCount ? " (\(groups.count) distinct)" : "")")
        if !groups.isEmpty {
            sections.append("\n## Console errors")
            for group in groups.prefix(15) {
                sections.append("- \(group.uncaught && !group.message.hasPrefix("Uncaught") ? "**Uncaught** " : "")\(group.message)\(group.count > 1 ? " ×\(group.count)" : "")\(group.location.isEmpty ? "" : "\n  at \(group.location)") (console #\(group.firstID))")
            }
        }

        // Requests of the current page.
        let requests = requestLog(tab, sinceNavigation: true)
        let failed = requests.filter(\.isFailure)
        let slow = requests.filter { ($0.duration ?? 0) > 1 && !$0.isFailure }.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        let large = requests.filter { ($0.transferSize ?? $0.bodySize ?? 0) > 1_000_000 }
        let pageIsSecure = tab.currentURL?.scheme == "https"
        let mixed = pageIsSecure ? requests.filter { $0.url.scheme == "http" } : []
        summary.append("\(failed.count) failed request\(failed.count == 1 ? "" : "s") of \(requests.count)")
        if !failed.isEmpty {
            sections.append("\n## Failed requests")
            for request in failed.prefix(15) {
                let status = request.failure.map { "failed: \($0)" } ?? request.statusCode.map(String.init) ?? "?"
                sections.append("- \(request.method ?? "GET") \(status) \(request.url.absoluteString.prefix(200)) (id \(Self.requestID(request)))")
            }
        }
        if !slow.isEmpty {
            summary.append("\(slow.count) slow (>1 s)")
            sections.append("\n## Slow requests (over 1 s)")
            for request in slow.prefix(8) {
                sections.append("- \(InspectorEventFormatter.milliseconds(request.duration ?? 0)) \(request.resourceType) \(request.url.absoluteString.prefix(200)) (id \(Self.requestID(request)))")
            }
        }
        if !large.isEmpty {
            sections.append("\n## Large responses (over 1 MB)")
            for request in large.prefix(8) {
                sections.append("- \(InspectorEventFormatter.byteCount(request.transferSize ?? request.bodySize ?? 0)) \(request.url.absoluteString.prefix(200))")
            }
        }
        if !mixed.isEmpty {
            summary.append("\(mixed.count) insecure (http) load\(mixed.count == 1 ? "" : "s") on an https page")
            sections.append("\n## Mixed content")
            for request in mixed.prefix(8) { sections.append("- \(request.url.absoluteString.prefix(200))") }
        }

        // Vitals, as performance_metrics reports them.
        if let vitals = try? await performanceMetrics(tabArgument), case .text(let text) = vitals.content.first {
            let lines = text.components(separatedBy: "\n")
            if let start = lines.firstIndex(where: { $0.hasPrefix("Core Web Vitals") }) {
                let block = lines[start...].prefix { !$0.isEmpty }
                sections.append("\n## " + block.joined(separator: "\n"))
                if block.contains(where: { $0.contains("— poor") }) { summary.append("poor Core Web Vitals") }
            }
        }

        // The audits' worst failures.
        if a["includeAudits"]?.bool ?? true {
            do {
                let report = try await toolsAgent(tab, "Audit.run")
                var scores: [String] = []
                var worst: [(weight: Double, line: String)] = []
                for (key, name) in Self.auditCategories {
                    guard let audits = report[key]?.array else { continue }
                    if let score = Self.categoryScore(audits) { scores.append("\(name) \(score)") }
                    for audit in audits where audit["passed"]?.bool == false && audit["notApplicable"]?.bool != true {
                        let items = audit["items"]?.array ?? []
                        let example = items.first.map { " e.g. `\($0["selector"]?.string ?? "")`" } ?? ""
                        worst.append((audit["weight"]?.double ?? 0, "- [\(name)] \(audit["failureTitle"]?.string ?? audit["title"]?.string ?? "") — \(audit["total"]?.int ?? items.count) element(s)\(example)"))
                    }
                }
                if !scores.isEmpty { summary.append("audit scores: " + scores.joined(separator: ", ")) }
                if !worst.isEmpty {
                    sections.append("\n## Top audit failures (run_audit for every element and the fix)")
                    sections.append(contentsOf: worst.sorted { $0.weight > $1.weight }.prefix(10).map(\.line))
                }
            } catch {
                sections.append("\n(Audits could not run: \(Self.message(for: error)))")
            }
        }
        if warnings > 0 { summary.append("\(warnings) console warning\(warnings == 1 ? "" : "s")") }
        if let dialog = tab.pageDialog { sections.insert(dialog.summary, at: 2) }

        var next: [String] = []
        if !groups.isEmpty { next.append("console_messages level error for stacks") }
        if !failed.isEmpty { next.append("network_request id … for the failing requests' bodies") }
        next.append("snapshot to act on the page")
        sections.insert("\n**Summary:** " + summary.joined(separator: " · "), at: 2)
        sections.append("\nNext: " + next.joined(separator: "; ") + ".")
        return .text(sections.joined(separator: "\n"))
    }

    static let auditCategories: [(String, String)] = [("accessibility", "Accessibility"), ("seo", "SEO"), ("bestPractices", "Best practices")]

    /// Lighthouse's arithmetic: the weighted share of applicable audits that pass, 0–100.
    static func categoryScore(_ audits: [JSONValue]) -> Int? {
        var total = 0.0, earned = 0.0
        for audit in audits where audit["notApplicable"]?.bool != true {
            let weight = audit["weight"]?.double ?? 0
            guard weight > 0 else { continue }
            total += weight
            if audit["passed"]?.bool == true { earned += weight }
        }
        return total > 0 ? Int((earned / total * 100).rounded()) : nil
    }

    // MARK: - run_audit

    func runAudit(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let wanted = Set(a["categories"]?.array?.compactMap(\.string) ?? ["accessibility", "seo", "bestPractices", "performance"])
        let includePassed = a["includePassed"]?.bool ?? false
        let report = try await toolsAgent(tab, "Audit.run")
        var lines = ["# Audits — \(report["title"]?.string ?? "") — \(report["url"]?.string ?? "")"]
        var scores: [String] = []
        var body: [String] = []
        for (key, name) in Self.auditCategories where wanted.contains(key) {
            guard let audits = report[key]?.array else { continue }
            let score = Self.categoryScore(audits)
            if let score { scores.append("\(name) \(score)") }
            body.append("\n## \(name)\(score.map { " — \($0)/100" } ?? "")")
            let failing = audits.filter { $0["passed"]?.bool == false && $0["notApplicable"]?.bool != true }
                .sorted { ($0["weight"]?.double ?? 0) > ($1["weight"]?.double ?? 0) }
            if failing.isEmpty { body.append("Every applicable check passes.") }
            for audit in failing {
                let items = audit["items"]?.array ?? []
                let total = audit["total"]?.int ?? items.count
                body.append("✗ **\(audit["failureTitle"]?.string ?? audit["title"]?.string ?? "")** [\(audit["id"]?.string ?? "")]\(total > 0 ? " — \(total) element\(total == 1 ? "" : "s")" : "")")
                if let description = audit["description"]?.string { body.append("  Why: \(description)") }
                for item in items.prefix(8) {
                    var line = "  - `\(item["selector"]?.string ?? "")`"
                    if let detail = item["detail"]?.string, !detail.isEmpty { line += " — \(detail)" }
                    if let snippet = item["snippet"]?.string, !snippet.isEmpty { line += "\n    \(snippet.prefix(200))" }
                    body.append(line)
                }
                if total > 8 { body.append("  - …and \(total - 8) more") }
            }
            if includePassed {
                for audit in audits where audit["passed"]?.bool == true { body.append("✓ \(audit["title"]?.string ?? "")") }
                for audit in audits where audit["notApplicable"]?.bool == true { body.append("– \(audit["title"]?.string ?? "") (not applicable)") }
            }
        }
        if wanted.contains("performance"), let facts = report["performance"] {
            body.append("\n## Performance")
            if let vitals = try? await performanceMetrics(["tabId": .string(Self.shortID(tab))]), case .text(let text) = vitals.content.first {
                let block = text.components(separatedBy: "\n").drop { !$0.hasPrefix("Core Web Vitals") }.prefix { !$0.isEmpty }
                body.append(contentsOf: block)
            }
            let blocking = facts["renderBlocking"]?.array ?? []
            body.append(blocking.isEmpty ? "✓ No render-blocking scripts or stylesheets in <head>." : "✗ **Render-blocking resources** — \(blocking.count):")
            for item in blocking.prefix(10) { body.append("  - \(item["kind"]?.string ?? "") \(item["url"]?.string ?? "")") }
            let oversized = facts["oversizedImages"]?.array ?? []
            body.append(oversized.isEmpty ? "✓ Images are not larger than shown." : "✗ **Images larger than displayed** — \(oversized.count):")
            for item in oversized.prefix(10) { body.append("  - `\(item["selector"]?.string ?? "")` \(item["detail"]?.string ?? "") \(item["url"]?.string ?? "")") }
            if let dom = facts["domSize"]?.int { body.append("\(dom > 1500 ? "✗" : "✓") DOM size: \(dom) elements\(dom > 1500 ? " (Lighthouse warns above 1,500)" : "").") }
        }
        if !scores.isEmpty { lines.append("**Scores:** " + scores.joined(separator: " · ")) }
        lines.append(contentsOf: body)
        lines.append("\nElements are given as CSS selectors: pass them to inspect_element, screenshot or devtools.")
        return .text(lines.joined(separator: "\n"))
    }

    // MARK: - mock_network

    func mockNetwork(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let state = tab.agentState ?? AgentTabState()
        tab.agentState = state
        let action = a["action"]?.string ?? "list"
        let tools = try await openTools(tab, panel: action == "list" ? nil : "network")

        func describeActive() -> String {
            var lines: [String] = []
            let blocked = tools.tools.blockedPatterns
            lines.append(blocked.isEmpty ? "Blocked: nothing." : "Blocked (\(blocked.count)): " + blocked.joined(separator: ", "))
            if state.mocks.isEmpty { lines.append("Overrides: none.") }
            for mock in state.mocks { lines.append("Override: \(mock.pattern) → \(mock.status)\(mock.body == nil ? " (real body)" : ", \(mock.body!.count) chars of \(mock.contentType)")") }
            return lines.joined(separator: "\n")
        }

        switch action {
        case "list":
            return .text(describeActive())
        case "clear":
            _ = try await tools.handleTool("Network.setBlockedPatterns", ["patterns": [String]()])
            state.mocks = []
            if tools.protocolState == "attached" { _ = try await tools.handleTool("Network.setOverrides", ["overrides": [[String: Any]]()]) }
        case "block":
            guard let pattern = a["pattern"]?.string, !pattern.isEmpty else { throw ToolError("block needs a pattern") }
            var patterns = tools.tools.blockedPatterns
            if !patterns.contains(pattern) { patterns.append(pattern) }
            _ = try await tools.handleTool("Network.setBlockedPatterns", ["patterns": patterns])
        case "override":
            guard let pattern = a["pattern"]?.string, !pattern.isEmpty else { throw ToolError("override needs a pattern: the URL, * as wildcard") }
            guard tools.protocolState == "attached" else {
                throw ToolError("Overrides need the inspector protocol, which is not available in this build (\(tools.protocolState)). Blocking works.")
            }
            let body = a["body"]?.string
            let isJSON = body.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed)) != nil } ?? false
            let mock = AgentTabState.Mock(pattern: pattern, status: a["status"]?.int ?? 200, body: body,
                                          contentType: a["contentType"]?.string ?? (isJSON ? "application/json" : "text/plain"),
                                          headers: (a["headers"]?.object ?? [:]).compactMapValues { $0.string ?? $0.jsonString })
            state.mocks.removeAll { $0.pattern == pattern }
            state.mocks.append(mock)
            let list: [[String: Any]] = state.mocks.map { mock in
                var item: [String: Any] = ["url": mock.pattern, "status": mock.status, "headers": mock.headers, "mimeType": mock.contentType, "enabled": true]
                if let body = mock.body { item["body"] = body } else { item["keepBody"] = true }
                return item
            }
            _ = try await tools.handleTool("Network.setOverrides", ["overrides": list])
        default:
            throw ToolError("Unknown action \(action)")
        }
        var text = describeActive()
        if a["reload"]?.bool == true {
            let since = recorder.events.last?.sequence ?? -1
            tab.reload(nil)
            try await waitForLoad(tab, timeout: 30)
            text += "\nReloaded.\n" + navigationReport(tab, since: since)
        }
        return .text(text + "\nThese apply while DevTools is open; closing DevTools suspends them.")
    }

    // MARK: - heap_snapshot

    func heapSnapshot(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let bridge = tab.protocolBridge
        do { _ = try await bridge.send("Heap.gc") } catch {
            throw ToolError("Heap snapshots need the inspector protocol: \(Self.message(for: error))")
        }
        let result = try await bridge.send("Heap.snapshot", [:], timeout: .seconds(90))
        guard let data = (result["snapshotData"] as? String).map({ Data($0.utf8) }) else { throw ToolError("The engine returned no snapshot") }
        let classes = try await Task.detached(priority: .userInitiated) { try Self.heapClasses(data) }.value
        let state = tab.agentState ?? AgentTabState()
        tab.agentState = state
        let previous = state.heap
        state.heap = classes
        let filter = a["filter"]?.string?.lowercased()
        let limit = min(max(a["limit"]?.int ?? 30, 1), 300)
        let totalCount = classes.values.reduce(0) { $0 + $1.count }, totalSize = classes.values.reduce(0) { $0 + $1.size }
        var lines = ["Heap after garbage collection: \(totalCount) objects, \(InspectorEventFormatter.byteCount(Int64(totalSize))) (shallow sizes)."]
        func matches(_ name: String) -> Bool { filter.map { name.lowercased().contains($0) } ?? true }
        if a["compare"]?.bool == true {
            guard let previous else {
                lines.append("No earlier snapshot of this tab to compare with: this one is now the baseline. Do the suspect action, then call again with compare: true.")
                return .text(lines.joined(separator: "\n"))
            }
            let oldCount = previous.values.reduce(0) { $0 + $1.count }, oldSize = previous.values.reduce(0) { $0 + $1.size }
            lines.append("Since the previous snapshot: \(totalCount - oldCount >= 0 ? "+" : "")\(totalCount - oldCount) objects, \(totalSize - oldSize >= 0 ? "+" : "−")\(InspectorEventFormatter.byteCount(Int64(abs(totalSize - oldSize)))).")
            let deltas = Set(classes.keys).union(previous.keys).filter(matches).map { name -> (String, Int, Int) in
                (name, (classes[name]?.count ?? 0) - (previous[name]?.count ?? 0), (classes[name]?.size ?? 0) - (previous[name]?.size ?? 0))
            }.filter { $0.1 != 0 || $0.2 != 0 }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 > $1.1 }
            lines.append("\nClass — Δcount — Δsize (largest growth first):")
            for (name, count, size) in deltas.prefix(limit) {
                lines.append("  \(name) — \(count >= 0 ? "+" : "")\(count) — \(size >= 0 ? "+" : "−")\(InspectorEventFormatter.byteCount(Int64(abs(size))))")
            }
            if deltas.isEmpty { lines.append("  (no change)") }
            lines.append("\nSteady growth of the same classes across repeated actions points at a leak; DevTools' Memory panel shows retainers.")
        } else {
            lines.append("\nClass — count — shallow size (largest first):")
            for (name, value) in classes.filter({ matches($0.key) }).sorted(by: { $0.value.size > $1.value.size }).prefix(limit) {
                lines.append("  \(name) — \(value.count) — \(InspectorEventFormatter.byteCount(Int64(value.size)))")
            }
            lines.append("\nThis is now the baseline: call again with compare: true after an action to see what grew.")
        }
        return .text(lines.joined(separator: "\n"))
    }

    /// JavaScriptCore's snapshot: `nodes` are [id, size, classNameIndex, flags].
    nonisolated static func heapClasses(_ data: Data) throws -> [String: (count: Int, size: Int)] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = object["nodes"] as? [NSNumber], let names = object["nodeClassNames"] as? [String] else {
            throw ToolError("The heap snapshot is not in the format this build understands")
        }
        var out: [String: (count: Int, size: Int)] = [:]
        var index = 0
        while index + 3 < nodes.count {
            let size = nodes[index + 1].intValue, classIndex = nodes[index + 2].intValue
            let name = names.indices.contains(classIndex) ? names[classIndex] : "(unknown)"
            let current = out[name] ?? (0, 0)
            out[name] = (current.count + 1, current.size + size)
            index += 4
        }
        return out
    }

    // MARK: - application_data

    func applicationData(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let limit = min(max(a["limit"]?.int ?? 50, 1), 500)
        switch a["kind"]?.string ?? "" {
        case "indexeddb":
            if let database = a["database"]?.string, let store = a["store"]?.string {
                let records = try await toolsAgent(tab, "IndexedDB.records", ["database": .string(database), "store": .string(store), "limit": .number(Double(limit))])
                return .text("IndexedDB \(database) › \(store):\n" + Self.pretty(records))
            }
            if let database = a["database"]?.string {
                return .text("IndexedDB \(database):\n" + Self.pretty(try await toolsAgent(tab, "IndexedDB.database", ["name": .string(database)])))
            }
            let databases = try await toolsAgent(tab, "IndexedDB.databases")
            return .text((databases.array?.isEmpty ?? true) ? "No IndexedDB databases for this origin." : "IndexedDB databases (pass database to see stores):\n" + Self.pretty(databases))
        case "cache":
            if let cache = a["cache"]?.string {
                let entries = try await toolsAgent(tab, "CacheStorage.entries", ["cache": .string(cache)])
                let list = entries.array.map { JSONValue.array(Array($0.prefix(limit))) } ?? entries
                return .text("Cache \(cache):\n" + Self.pretty(list))
            }
            let caches = try await toolsAgent(tab, "CacheStorage.caches")
            return .text((caches.array?.isEmpty ?? true) ? "No Cache Storage caches for this origin." : "Caches (pass cache to list entries):\n" + Self.pretty(caches))
        case "manifest":
            let manifest = try await toolsAgent(tab, "Manifest.get")
            return .text(manifest.isNull ? "This page links no web app manifest." : "Web app manifest:\n" + Self.pretty(manifest))
        case "service_workers":
            let workers = try await toolsAgent(tab, "ServiceWorker.list")
            return .text((workers.array?.isEmpty ?? false) ? "No service workers are registered for this origin." : "Service workers:\n" + Self.pretty(workers))
        case "animations":
            let animations = try await toolsAgent(tab, "Animations.list")
            return .text((animations.array?.isEmpty ?? true) ? "No animations are running." : "Animations:\n" + Self.pretty(animations))
        default:
            throw ToolError("kind must be indexeddb, cache, manifest, service_workers or animations")
        }
    }

    // MARK: - devtools_selection

    func devtoolsSelection(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        guard let tools = tab.devTools, tab.isDevToolsVisible else {
            return .text("DevTools is not open in tab \(Self.shortID(tab)). Ask the person to open it (⌥⌘I) and select the element or request, or open it yourself with the devtools tool.")
        }
        var lines: [String] = []
        let selection = JSONValue(any: try? await tools.evaluateInUI("""
            const el = DevTools.panels.elements, net = DevTools.panels.network;
            const r = net && net.selectedId != null && net.requests ? net.requests.get(net.selectedId) : null;
            return { panel: DevTools.activePanel || null, nodeId: el ? el.selectedId : null,
                     request: r ? { url: r.url, method: r.method || "GET", status: r.statusCode ?? null } : null };
            """))
        if let panel = selection["panel"]?.string { lines.append("DevTools is showing the \(panel) panel.") }
        if let nodeId = selection["nodeId"]?.int {
            let selector = try? await script(tab, "return await window.__sbAgent.handle('DOM.uniqueSelector', { nodeId });",
                                             arguments: ["nodeId": nodeId], world: world) as? String
            if let selector, !selector.isEmpty {
                lines.append("\n## Selected element: `\(selector)`")
                if let detail = try? await inspectElement(["tabId": .string(Self.shortID(tab)), "selector": .string(selector)]),
                   case .text(let text) = detail.content.first {
                    lines.append(text)
                }
            }
        } else {
            lines.append("No element is selected in Elements.")
        }
        if let request = selection["request"], let url = request["url"]?.string {
            let method = request["method"]?.string ?? "GET"
            if let match = requestLog(tab, sinceNavigation: false).last(where: { $0.url.absoluteString == url && ($0.method ?? "GET") == method }),
               let detail = try? await networkRequest(["tabId": .string(Self.shortID(tab)), "id": .string(Self.requestID(match)), "maxBodyLength": 8000]),
               case .text(let text) = detail.content.first {
                lines.append("\n## Selected request (id \(Self.requestID(match)))")
                lines.append(text)
            } else {
                lines.append("\n## Selected request\n\(method) \(url) (status \(request["status"]?.int.map(String.init) ?? "?"))")
            }
        } else {
            lines.append("No request is selected in Network.")
        }
        return .text(lines.joined(separator: "\n"))
    }
}

extension AgentTabState {
    /// A response the agent asked DevTools to serve instead of the network's.
    struct Mock {
        var pattern: String
        var status: Int
        var body: String?
        var contentType: String
        var headers: [String: String]
    }
}
