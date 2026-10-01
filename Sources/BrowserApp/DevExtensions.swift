import AppKit
import WebKit
import Security

/// The developer extensions that ship with the browser. They are built in
/// rather than installed: React DevTools, Clockwork and the rest are Chrome
/// extensions written against `chrome.devtools`, which WebKit's extension
/// API does not have, so each is reimplemented against our own DevTools.
/// Develop → Developer Extensions turns them on and off.
enum DevExtension: String, CaseIterable {
    case claude, dataLayer, react, php, node, colorPicker, jsonViewer

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .dataLayer: return "dataLayer Inspector"
        case .react: return "React Developer Tools"
        case .php: return "Laravel / PHP Debug"
        case .node: return "Node.js Debugger"
        case .colorPicker: return "Color Picker"
        case .jsonViewer: return "JSON Viewer"
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "devext." + rawValue) as? Bool ?? true }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: "devext." + rawValue)
            NotificationCenter.default.post(name: DevExtension.didChange, object: nil)
        }
    }

    static let didChange = Notification.Name("DevExtensionsDidChange")

    /// What the DevTools UI needs to know to show or hide each panel.
    static var states: [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.isEnabled) })
    }

    // MARK: - Page scripts

    private static func resource(_ name: String) -> String? {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "js", subdirectory: "DevExtensions") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Scripts are fixed when a tab's web view is made, so a change applies to tabs opened afterwards.
    static func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        if DevExtension.react.isEnabled || DevExtension.dataLayer.isEnabled, var source = resource("devext-hooks") {
            let flags = "{\"react\":\(DevExtension.react.isEnabled),\"dataLayer\":\(DevExtension.dataLayer.isEnabled)}"
            source = source.replacingOccurrences(of: "__SB_DEVEXT_FLAGS__", with: flags)
            // Page world, before the page's own scripts: React looks for the hook as it loads.
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if DevExtension.jsonViewer.isEnabled, let source = resource("json-viewer") {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                                  in: WKContentWorld.world(name: "SimpleBrowserJSONViewer")))
        }
    }

    // MARK: - Color picker

    /// The macOS screen sampler: any pixel on any screen, not only the page.
    @MainActor
    static func sampleColor() async -> NSColor? {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { color in continuation.resume(returning: color) }
        }
    }

    static func describe(_ color: NSColor) -> [String: Any] {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        let a = c.alphaComponent
        var h: CGFloat = 0, s: CGFloat = 0, l: CGFloat = 0
        let maxC = max(c.redComponent, c.greenComponent, c.blueComponent), minC = min(c.redComponent, c.greenComponent, c.blueComponent)
        l = (maxC + minC) / 2
        if maxC != minC {
            let d = maxC - minC
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            switch maxC {
            case c.redComponent: h = (c.greenComponent - c.blueComponent) / d + (c.greenComponent < c.blueComponent ? 6 : 0)
            case c.greenComponent: h = (c.blueComponent - c.redComponent) / d + 2
            default: h = (c.redComponent - c.greenComponent) / d + 4
            }
            h /= 6
        }
        let hex = String(format: "#%02X%02X%02X", r, g, b) + (a < 1 ? String(format: "%02X", Int((a * 255).rounded())) : "")
        return [
            "hex": hex,
            "rgb": a < 1 ? "rgb(\(r) \(g) \(b) / \(String(format: "%.2f", a)))" : "rgb(\(r), \(g), \(b))",
            "hsl": "hsl(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)",
            "swift": String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", c.redComponent, c.greenComponent, c.blueComponent),
        ]
    }

    /// Develop → Pick Color: sample, copy the hex, and say what it was.
    @MainActor
    static func pickColorToPasteboard(near window: NSWindow?) async {
        guard let color = await sampleColor() else { return }
        let info = describe(color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info["hex"] as? String ?? "", forType: .string)
        let alert = NSAlert()
        alert.messageText = "\(info["hex"] ?? "") copied"
        alert.informativeText = ["rgb", "hsl", "swift"].compactMap { info[$0] as? String }.joined(separator: "\n")
        alert.icon = swatch(color)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy RGB")
        alert.addButton(withTitle: "Copy HSL")
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            let key = response == .alertSecondButtonReturn ? "rgb" : response == .alertThirdButtonReturn ? "hsl" : nil
            if let key, let text = info[key] as? String {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: respond) } else { respond(alert.runModal()) }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12)
            color.setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
            return true
        }
    }
}

// MARK: - Claude

/// The Claude panel's API key, kept in the login keychain.
enum ClaudeKeychain {
    private static let service = "SimpleBrowser Claude API key"

    static var key: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Streams one reply from the Messages API. There is no official Swift SDK,
/// so this is the documented HTTP shape: SSE, `content_block_delta` events
/// carrying `text_delta`s, and server-side fallbacks on a policy decline.
final class ClaudeStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let model = "claude-opus-5-5"

    private var buffer = Data()
    private var task: URLSessionDataTask?
    private let onEvent: @Sendable (_ kind: String, _ payload: [String: Any]) -> Void
    private var finished = false

    init(onEvent: @escaping @Sendable (String, [String: Any]) -> Void) {
        self.onEvent = onEvent
    }

    func start(key: String, system: String, messages: [[String: Any]], effort: String) throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 600
        let body: [String: Any] = [
            "model": Self.model, "max_tokens": 32000, "stream": true,
            "system": system, "messages": messages,
            "output_config": ["effort": effort],
            "fallbacks": "default",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if let http = dataTask.response as? HTTPURLResponse, http.statusCode >= 400 { return }   // read whole in didComplete
        while let range = buffer.range(of: Data("\n\n".utf8)) {
            let chunk = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            let dataLines = chunk.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            guard let json = dataLines.joined().data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "message_start":
                let model = (event["message"] as? [String: Any])?["model"] as? String ?? Self.model
                onEvent("start", ["model": model])
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], block["type"] as? String == "fallback" {
                    onEvent("note", ["text": "Continued on \(((block["to"] as? [String: Any])?["model"] as? String) ?? "a fallback model") after a policy decline."])
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    onEvent("delta", ["text": text])
                }
            case "message_delta":
                if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String {
                    onEvent("stop", ["reason": reason, "usage": event["usage"] ?? [:]])
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "The API returned an error"
                finish("error", ["message": message])
            default: break
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        if let http = task.response as? HTTPURLResponse, http.statusCode >= 400 {
            let detail = (try? JSONSerialization.jsonObject(with: buffer) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            finish("error", ["message": "\(http.statusCode): \(detail)"])
            return
        }
        if let error = error as NSError?, error.code == NSURLErrorCancelled { finish("done", ["cancelled": true]); return }
        if let error { finish("error", ["message": error.localizedDescription]); return }
        finish("done", [:])
    }

    private func finish(_ kind: String, _ payload: [String: Any]) {
        guard !finished else { return }
        finished = true
        onEvent(kind, payload)
    }
}
