import AppKit
import WebKit
import InspectKit

/// What the tools below keep between requests. One per DevTools.
@MainActor
final class DevToolsToolState {
    /// Network request blocking: Chrome-style patterns (`*` is a wildcard,
    /// otherwise a substring of the URL). Enforced only while DevTools shows.
    var blockedPatterns: [String] = []
    var isShown = false

    /// Local overrides, keyed by the regex given to `Network.addInterception`.
    var overrides: [LocalOverride] = []
    var interceptions: [String] = []
}

/// A response served instead of the network's, while DevTools is open.
struct LocalOverride {
    var pattern: String
    var regex: NSRegularExpression
    var status: Int
    var headers: [String: String]
    /// Nil: fetch the original body and serve it with these headers.
    var body: String?
    var mimeType: String?
}

extension DevToolsController {

    /// Requests answered in this file rather than by the agents.
    static let toolMethods: Set<String> = [
        "Network.setBlockedPatterns", "Network.setOverrides", "Network.getHAR",
    ]

    /// Isolated-world commands that live in the on-demand tools agent.
    static let toolsAgentPrefixes = ["Tools.", "Audit.", "Accessibility.", "IndexedDB.", "CacheStorage.", "Manifest.", "Animations.", "Rendering."]

    func handleTool(_ method: String, _ params: [String: Any]) async throws -> Any? {
        switch method {
        case "Network.setBlockedPatterns":
            tools.blockedPatterns = (params["patterns"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try await applyBlocking()
            return ["patterns": tools.blockedPatterns.count]
        case "Network.setOverrides":
            return try await setOverrides(params["overrides"] as? [[String: Any]] ?? [])
        case "Network.getHAR":
            let data = try HARExporter.export(networkLog.requests, pageURL: page?.url, pageTitle: page?.title)
            return String(decoding: data, as: UTF8.self)
        default:
            throw DevToolsError.unknownRequest
        }
    }

    func toolsDidShow() {
        tools.isShown = true
        Task { try? await applyBlocking() }
        if !tools.overrides.isEmpty, protocolState == "attached" { Task { try? await syncInterceptions() } }
    }

    /// Like Chrome, blocking and overrides apply only while DevTools is open.
    func toolsDidHide() {
        tools.isShown = false
        if let controller = page?.configuration.userContentController {
            ContentBlocker.setPinnedLists([], for: controller)
        }
        if !tools.interceptions.isEmpty, protocolState == "attached" { Task { try? await syncInterceptions() } }
    }

    // MARK: - Request blocking

    /// Compiles the patterns into a content rule list on the tab: WebKit then
    /// blocks matching loads in its network process, every resource type,
    /// with or without the inspector protocol.
    private func applyBlocking() async throws {
        guard let controller = page?.configuration.userContentController else { return }
        guard tools.isShown, !tools.blockedPatterns.isEmpty else {
            ContentBlocker.setPinnedLists([], for: controller)
            return
        }
        let rules = tools.blockedPatterns.map { pattern -> [String: Any] in
            ["trigger": ["url-filter": Self.urlFilter(for: pattern)], "action": ["type": "block"]]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        guard let store = WKContentRuleListStore.default() else { return }
        let list = try await store.compileContentRuleList(forIdentifier: "devtools-blocking-\(tab)", encodedContentRuleList: json)
        // A newer call may have cleared the patterns while this compiled.
        guard tools.isShown, !tools.blockedPatterns.isEmpty else { return }
        ContentBlocker.setPinnedLists(list.map { [$0] } ?? [], for: controller)
    }

    /// Chrome's pattern syntax → a WebKit `url-filter` regex: a substring
    /// match where `*` matches anything.
    static func urlFilter(for pattern: String) -> String {
        var out = ""
        for character in pattern {
            if character == "*" { out += ".*" }
            else if "\\.+?^$()[]{}|".contains(character) { out += "\\" + String(character) }
            else { out.append(character) }
        }
        return out
    }

    // MARK: - Local overrides

    private func setOverrides(_ list: [[String: Any]]) async throws -> Any? {
        guard protocolState == "attached" else {
            throw DevToolsError.protocolUnavailable("local overrides need the inspector protocol (\(protocolState))")
        }
        tools.overrides = list.compactMap { item in
            guard item["enabled"] as? Bool ?? true, let url = item["url"] as? String, !url.isEmpty else { return nil }
            let pattern = Self.overrideRegex(for: url)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let body = item["body"] as? String
            return LocalOverride(pattern: pattern, regex: regex,
                                 status: (item["status"] as? NSNumber)?.intValue ?? 200,
                                 headers: (item["headers"] as? [String: Any] ?? [:]).mapValues { "\($0)" },
                                 body: (body?.isEmpty ?? true) && item["keepBody"] as? Bool == true ? nil : (body ?? ""),
                                 mimeType: item["mimeType"] as? String)
        }
        try await syncInterceptions()
        return ["active": tools.overrides.count]
    }

    /// Makes the protocol's interceptions match the overrides while DevTools
    /// shows, and removes them while it is hidden.
    private func syncInterceptions() async throws {
        let wanted = tools.isShown ? Array(Set(tools.overrides.map(\.pattern))) : []
        for pattern in tools.interceptions where !wanted.contains(pattern) {
            _ = try? await protocolBridge.send("Network.removeInterception",
                                               ["url": pattern, "stage": "request", "isRegex": true, "caseSensitive": true])
        }
        tools.interceptions.removeAll { !wanted.contains($0) }
        guard !wanted.isEmpty else { return }
        // WebKit's own frontend may have switched interception on already; that is an error here, and harmless.
        _ = try? await protocolBridge.send("Network.setInterceptionEnabled", ["enabled": true])
        for pattern in wanted where !tools.interceptions.contains(pattern) {
            _ = try await protocolBridge.send("Network.addInterception",
                                              ["url": pattern, "stage": "request", "isRegex": true, "caseSensitive": true])
            tools.interceptions.append(pattern)
        }
    }

    /// The whole URL, with `*` as a wildcard.
    static func overrideRegex(for url: String) -> String {
        "^" + url.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
    }

    /// `Network.requestIntercepted`: answer with the override, or let it through.
    func handleInterceptedRequest(_ params: [String: Any]) {
        guard let requestId = params["requestId"] as? String else { return }
        let url = (params["request"] as? [String: Any])?["url"] as? String ?? ""
        let method = (params["request"] as? [String: Any])?["method"] as? String
        let range = NSRange(url.startIndex..., in: url)
        guard let override = tools.overrides.first(where: { $0.regex.firstMatch(in: url, range: range) != nil }) else {
            Task { _ = try? await protocolBridge.send("Network.interceptContinue", ["requestId": requestId, "stage": "request"]) }
            return
        }
        Task {
            var content = override.body ?? ""
            var mime = override.mimeType
            if override.body == nil, let target = URL(string: url) {
                // Headers-only override: serve the real body under the new headers.
                if let (text, fetchedMime, _) = try? await fetchNatively(target, method: method) {
                    content = text ?? ""
                    mime = mime ?? fetchedMime
                }
            }
            var headers = override.headers
            let mimeType = mime ?? headers.first { $0.key.lowercased() == "content-type" }?.value ?? "text/plain"
            if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = mimeType }
            do {
                _ = try await protocolBridge.send("Network.interceptRequestWithResponse", [
                    "requestId": requestId, "content": content, "base64Encoded": false,
                    "mimeType": mimeType.components(separatedBy: ";").first ?? mimeType,
                    "status": override.status, "statusText": HTTPURLResponse.localizedString(forStatusCode: override.status).capitalized,
                    "headers": headers,
                ])
            } catch {
                _ = try? await protocolBridge.send("Network.interceptContinue", ["requestId": requestId, "stage": "request"])
            }
        }
    }
}
