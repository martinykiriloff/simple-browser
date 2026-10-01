import AppKit
import WebKit
import InspectKit
import UniformTypeIdentifiers

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

    /// Rendering emulation in force (feature → value), undone while hidden.
    var rendering: [String: Any] = [:]

    /// What the inspector protocol says about a request beyond the request
    /// record itself, by protocol request id: initiator (with its stack),
    /// remote address, priority, connection, and where the response came
    /// from (network, memory or disk cache, service worker).
    var networkExtras: [String: [String: Any]] = [:]
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
        "Emulation.setRendering", "Page.captureScreenshot", "Storage.clearSiteData", "DevTools.saveFile",
        "Accessibility.getEngineProperties", "Network.getExtras", "DevTools.openFile",
    ]

    /// Isolated-world commands that live in the on-demand tools agent.
    static let toolsAgentPrefixes = ["Tools.", "Audit.", "Accessibility.", "IndexedDB.", "CacheStorage.", "Manifest.", "ServiceWorker.", "Animations.", "Rendering."]

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
        case "Emulation.setRendering":
            guard let feature = params["feature"] as? String else { throw DevToolsError.unknownRequest }
            let value = params["value"] ?? NSNull()
            try await applyRendering(feature, value)
            if Self.isRenderingDefault(value) { tools.rendering.removeValue(forKey: feature) } else { tools.rendering[feature] = value }
            return true
        case "Page.captureScreenshot":
            return try await captureScreenshot(params)
        case "Storage.clearSiteData":
            return try await clearSiteData()
        case "Accessibility.getEngineProperties":
            // WebKit's own accessibility object for the node: what VoiceOver gets.
            let node = try await protocolNodeId(for: params)
            let result = try await protocolBridge.send("DOM.getAccessibilityPropertiesForNode", ["nodeId": node])
            return result["properties"] ?? [:]
        case "DevTools.saveFile":
            // Reports and exports: the UI has the text (or, for a binary
            // response body, base64 bytes); the app asks where to put it.
            guard let window = view.window else { return false }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = params["name"] as? String ?? "devtools.txt"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
            if let base64 = params["base64"] as? String {
                guard let data = Data(base64Encoded: base64) else { throw DevToolsError.protocolUnavailable("invalid base64 data") }
                try data.write(to: url, options: .atomic)
            } else {
                try Data((params["text"] as? String ?? "").utf8).write(to: url, options: .atomic)
            }
            return url.path
        case "DevTools.openFile":
            // Import (a HAR file): the app asks which file, the UI gets its text.
            guard let window = view.window else { return NSNull() }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if let types = params["extensions"] as? [String] {
                panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
            }
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return NSNull() }
            let data = try Data(contentsOf: url)
            return ["name": url.lastPathComponent, "text": String(decoding: data, as: UTF8.self)]
        case "Network.getExtras":
            return tools.networkExtras
        default:
            throw DevToolsError.unknownRequest
        }
    }

    /// Keeps what the protocol tells about a request that the request
    /// record has no place for. Called for every `Network.*` event.
    func recordNetworkExtras(_ method: String, requestId: String, _ params: [String: Any]) {
        var extras = tools.networkExtras[requestId] ?? [:]
        switch method {
        case "Network.requestWillBeSent":
            if params["redirectResponse"] == nil { extras = [:] }
            if let initiator = params["initiator"] as? [String: Any] { extras["initiator"] = initiator }
            if let type = params["type"] as? String { extras["type"] = type }
            if let walltime = params["walltime"] as? Double { extras["walltime"] = walltime * 1000 }
            if let timestamp = params["timestamp"] as? Double { extras["requestTimestamp"] = timestamp }
            if let redirect = params["redirectResponse"] as? [String: Any], let status = redirect["status"] {
                var chain = extras["redirects"] as? [[String: Any]] ?? []
                chain.append(["status": status, "url": redirect["url"] ?? ""])
                extras["redirects"] = chain
            }
        case "Network.responseReceived":
            guard let response = params["response"] as? [String: Any] else { return }
            if let source = response["source"] as? String { extras["source"] = source }
            if let statusText = response["statusText"] as? String { extras["statusText"] = statusText }
            if let timestamp = params["timestamp"] as? Double { extras["responseTimestamp"] = timestamp }
            if let security = response["security"] as? [String: Any] { extras["security"] = security }
        case "Network.loadingFinished":
            if let timestamp = params["timestamp"] as? Double { extras["finishTimestamp"] = timestamp }
            guard let metrics = params["metrics"] as? [String: Any] else { break }
            for key in ["remoteAddress", "priority", "connectionIdentifier", "protocol", "isProxyConnection",
                        "requestHeaderBytesSent", "requestBodyBytesSent", "responseHeaderBytesReceived",
                        "responseBodyBytesReceived", "responseBodyDecodedSize"] {
                if let value = metrics[key] { extras[key] = value }
            }
        case "Network.loadingFailed":
            if let text = params["errorText"] as? String { extras["errorText"] = text }
            if let blocked = params["blockedReason"] as? String { extras["blockedReason"] = blocked }
        default:
            return
        }
        if tools.networkExtras.count > 3000 { tools.networkExtras.removeAll() }
        guard JSONSerialization.isValidJSONObject(extras) else { return }
        tools.networkExtras[requestId] = extras
    }

    /// A body the page-world hooks cut short ("…[truncated N chars]").
    static func isTruncatedByPageHooks(_ body: String) -> Bool {
        body.hasSuffix(" chars]") && body.suffix(64).contains("\u{2026}[truncated ")
    }

    /// Bodies the UI must treat as bytes, not text.
    static func isBinaryMime(_ mime: String) -> Bool {
        let mime = mime.lowercased()
        if mime.hasPrefix("font/") || mime.hasPrefix("audio/") || mime.hasPrefix("video/") { return true }
        return ["octet-stream", "font", "woff", "wasm", "zip", "gzip", "pdf", "protobuf", "msgpack", "x-tar", "x-7z", "x-rar", "vnd.ms-", "opentype", "truetype"]
            .contains { mime.contains($0) }
    }

    /// A body as a data URL, or nil past the size the UI can hold (~30 MB).
    static func binaryDataURL(base64: String, mime: String) -> String? {
        guard base64.utf8.count <= 40_000_000 else { return nil }
        return "data:\(mime.isEmpty ? "application/octet-stream" : mime);base64,\(base64)"
    }

    func toolsDidShow() {
        tools.isShown = true
        Task { try? await applyBlocking() }
        if !tools.overrides.isEmpty, protocolState == "attached" { Task { try? await syncInterceptions() } }
        for (feature, value) in tools.rendering { Task { try? await applyRendering(feature, value) } }
    }

    /// Like Chrome, blocking and overrides apply only while DevTools is open.
    func toolsDidHide() {
        tools.isShown = false
        if let controller = page?.configuration.userContentController {
            ContentBlocker.setPinnedLists([], for: controller)
        }
        if !tools.interceptions.isEmpty, protocolState == "attached" { Task { try? await syncInterceptions() } }
        // Rendering emulation too: the page goes back to how it really renders.
        for feature in tools.rendering.keys { Task { try? await applyRendering(feature, NSNull()) } }
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

    // MARK: - Rendering

    static func isRenderingDefault(_ value: Any) -> Bool {
        value is NSNull || (value as? Bool) == false || (value as? String) == ""
    }

    /// One Rendering-drawer feature, through the protocol. `NSNull`, false
    /// or "" puts the page back to normal.
    func applyRendering(_ feature: String, _ value: Any) async throws {
        let on = (value as? Bool) ?? false
        let text = (value as? String) ?? ""
        if feature == "fpsMeter" {
            // Drawn by the tools agent in the page; no protocol involved.
            _ = try await callIsolated("Rendering.setFPSMeter", ["enabled": on])
            return
        }
        if feature == "colorScheme", protocolState != "attached" {
            // Without the protocol the web view's appearance still drives prefers-color-scheme.
            page?.appearance = text == "dark" ? NSAppearance(named: .darkAqua) : text == "light" ? NSAppearance(named: .aqua) : nil
            return
        }
        guard protocolState == "attached" else {
            throw DevToolsError.protocolUnavailable("rendering emulation needs the inspector protocol (\(protocolState))")
        }
        func setting(_ name: String, _ value: Bool?) async throws {
            var params: [String: Any] = ["setting": name]
            if let value { params["value"] = value }          // no value: back to the page's own setting
            _ = try await protocolBridge.send("Page.overrideSetting", params)
        }
        func preference(_ name: String, _ value: String?) async throws {
            var params: [String: Any] = ["name": name]
            if let value { params["value"] = value }
            _ = try await protocolBridge.send("Page.overrideUserPreference", params)
        }
        switch feature {
        case "paintFlashing":     _ = try await protocolBridge.send("Page.setShowPaintRects", ["result": on])
        case "rulers":            _ = try await protocolBridge.send("Page.setShowRulers", ["result": on])
        case "layerBorders":      try await setting("ShowDebugBorders", on ? true : nil)
        case "repaintCounter":    try await setting("ShowRepaintCounter", on ? true : nil)
        case "disableJavaScript": try await setting("ScriptEnabled", on ? false : nil)
        case "disableImages":     try await setting("ImagesEnabled", on ? false : nil)
        case "media":             _ = try await protocolBridge.send("Page.setEmulatedMedia", ["media": text])
        case "colorScheme":       try await preference("PrefersColorScheme", ["light": "Light", "dark": "Dark"][text])
        case "reducedMotion":     try await preference("PrefersReducedMotion", ["reduce": "Reduce", "no-preference": "NoPreference"][text])
        case "contrast":          try await preference("PrefersContrast", ["more": "More", "no-preference": "NoPreference"][text])
        default: throw DevToolsError.protocolUnavailable("unknown rendering feature \(feature)")
        }
    }

    // MARK: - Screenshots

    /// `mode`: viewport, full or node. `destination`: downloads (default),
    /// clipboard, or none (only measured; for tests).
    private func captureScreenshot(_ params: [String: Any]) async throws -> Any? {
        guard let page else { throw DevToolsError.noPage }
        let mode = params["mode"] as? String ?? "viewport"
        var png: Data?
        if mode != "viewport", protocolState == "attached" {
            // The protocol renders the whole document, or one node, whatever is in view.
            let result: [String: Any]
            if mode == "node" {
                result = try await protocolBridge.send("Page.snapshotNode", ["nodeId": try await protocolNodeId(for: params)])
            } else {
                let info = try await callIsolated("Page.getInfo", [:]) as? [String: Any]
                let width = (info?["scrollWidth"] as? NSNumber)?.doubleValue ?? page.bounds.width
                let height = (info?["scrollHeight"] as? NSNumber)?.doubleValue ?? page.bounds.height
                result = try await protocolBridge.send("Page.snapshotRect",
                                                       ["x": 0, "y": 0, "width": width, "height": height, "coordinateSystem": "Page"])
            }
            if let url = result["dataURL"] as? String, let comma = url.firstIndex(of: ",") {
                png = Data(base64Encoded: String(url[url.index(after: comma)...]))
            }
        }
        if png == nil {
            if mode == "full" {
                throw DevToolsError.protocolUnavailable("a full size screenshot needs the inspector protocol (\(protocolState))")
            }
            let configuration = WKSnapshotConfiguration()
            if mode == "node" {
                // Without the protocol: the part of the node's box that is in view.
                let box = try await callIsolated("DOM.getBoxModel", params) as? [String: Any]
                let rect = box?["rect"] as? [String: Any]
                let value = { (key: String) in (rect?[key] as? NSNumber)?.doubleValue ?? 0 }
                configuration.rect = CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
                    .intersection(page.bounds)
            }
            let image = try await page.takeSnapshot(configuration: configuration)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
                throw DevToolsError.protocolUnavailable("the snapshot could not be encoded")
            }
            png = bitmap.representation(using: .png, properties: [:])
        }
        guard let png, let bitmap = NSBitmapImageRep(data: png) else { throw DevToolsError.protocolUnavailable("no image") }
        var result: [String: Any] = ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "bytes": png.count]
        switch params["destination"] as? String ?? "downloads" {
        case "clipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            result["copied"] = true
        case "none":
            break
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let host = page.url?.host() ?? "page"
            let suffix = mode == "full" ? " (full size)" : mode == "node" ? " (node)" : ""
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let file = downloads.appendingPathComponent("Screenshot \(host) \(formatter.string(from: Date()))\(suffix).png")
            try png.write(to: file, options: .atomic)
            result["path"] = file.path
        }
        return result
    }

    // MARK: - Clear site data

    /// Everything WebKit stores for the page's site in this profile: cookies,
    /// storage, IndexedDB, caches, service workers.
    private func clearSiteData() async throws -> Any? {
        guard let page, let host = page.url?.host()?.lowercased() else { throw DevToolsError.noPage }
        let store = page.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { record in
            let name = record.displayName.lowercased()
            return host == name || host.hasSuffix("." + name)
        }
        await store.removeData(ofTypes: types, for: records)
        // The live document keeps its storage areas in memory: empty those too.
        _ = try? await callIsolated("Storage.clear", ["area": "session"])
        _ = try? await callIsolated("Storage.clear", ["area": "local"])
        return ["records": records.map(\.displayName)]
    }
}
