import AppKit
import WebKit

/// Replies the developer-extension panels need from the app: things a page
/// cannot do (sample the screen, reach a Node inspector port, read a PHP
/// profiler's data without CORS, call Claude with a key the page never sees)
/// and calls into the page-world hooks for React and the dataLayer.
@MainActor
private var claudeStreams: [String: any ClaudeAnswer] = [:]

/// An answer being streamed in, by either backend.
protocol ClaudeAnswer: AnyObject { func cancel() }
extension ClaudeStream: ClaudeAnswer {}
extension ClaudeCodeStream: ClaudeAnswer {}

/// Which way the Claude panel reaches Claude: Claude Code on this Mac (the
/// person's own Claude login), or the Anthropic API with a key.
enum ClaudeBackend: String {
    case cli, api

    /// The person's choice; else Claude Code when it is installed, as it needs no key.
    static var current: ClaudeBackend {
        get {
            if let saved = UserDefaults.standard.string(forKey: "claude.backend").flatMap(ClaudeBackend.init) { return saved }
            return ClaudeCode.path() != nil ? .cli : .api
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "claude.backend") }
    }
}

extension DevToolsController {

    static func isExtensionMethod(_ method: String) -> Bool {
        ["Ext.", "ColorPicker.", "Node.", "PHP.", "Claude.", "React.", "DataLayer."].contains { method.hasPrefix($0) }
    }

    func handleExtension(_ method: String, _ params: [String: Any]) async throws -> Any? {
        switch method {
        case "Ext.state":
            return DevExtension.states

        case "ColorPicker.sample":
            guard let color = await DevExtension.sampleColor() else { return NSNull() }
            return DevExtension.describe(color)

        case "React.call", "DataLayer.call":
            return try await callDevExtHooks(params["method"] as? String ?? "", params["params"] as? [String: Any] ?? [:])

        case "Node.targets":
            return await nodeTargets(ports: (params["ports"] as? [NSNumber])?.map(\.intValue) ?? [9229, 9230, 9231])

        case "PHP.fetch":
            // Clockwork's and Laravel Debugbar's data, fetched as the page's origin would with its cookies.
            guard let raw = params["url"] as? String, let url = URL(string: raw) else { throw DevToolsError.unknownRequest }
            let (text, mime, status) = try await fetchNatively(url)
            return ["text": text ?? "", "mime": mime ?? "", "status": status]
        case "PHP.xdebug":
            return try await xdebugCookies()
        case "PHP.setXdebug":
            return try await setXdebug(mode: params["mode"] as? String ?? "debug", on: params["on"] as? Bool ?? false,
                                       ideKey: params["ideKey"] as? String ?? "PHPSTORM")

        case "Claude.state":
            let cli = ClaudeCode.path()
            return ["hasKey": ClaudeKeychain.key != nil, "model": ClaudeStream.model, "backend": ClaudeBackend.current.rawValue,
                    "cliPath": cli ?? NSNull(), "cliVersion": cli == nil ? NSNull() : (ClaudeCode.version() ?? "") as Any]
        case "Claude.setBackend":
            if (params["backend"] as? String) == "cli" { ClaudeCode.rescan() }
            ClaudeBackend.current = ClaudeBackend(rawValue: params["backend"] as? String ?? "") ?? .api
            return ["backend": ClaudeBackend.current.rawValue]
        case "Claude.setKey":
            ClaudeKeychain.set((params["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            return ["hasKey": ClaudeKeychain.key != nil]
        case "Claude.send" where ClaudeBackend.current == .cli:
            guard let path = ClaudeCode.path() else {
                throw DevToolsError.protocolUnavailable("Claude Code is not installed on this Mac. Install it (claude.com/code), or switch to the API.")
            }
            let id = params["id"] as? String ?? UUID().uuidString
            let stream = ClaudeCodeStream { [weak self] kind, payload in
                let box = SendablePayload(payload)
                Task { @MainActor in
                    self?.emit("Claude.event", ["id": id, "kind": kind, "payload": box.value])
                    if kind == "done" || kind == "error" { claudeStreams[id] = nil }
                }
            }
            claudeStreams[id] = stream
            try stream.start(path: path, system: params["system"] as? String ?? "", messages: params["messages"] as? [[String: Any]] ?? [],
                             effort: params["effort"] as? String ?? "medium")
            return ["id": id]
        case "Claude.send":
            guard let key = ClaudeKeychain.key else { throw DevToolsError.protocolUnavailable("Add your Anthropic API key first") }
            let id = params["id"] as? String ?? UUID().uuidString
            let stream = ClaudeStream { [weak self] kind, payload in
                let box = SendablePayload(payload)
                Task { @MainActor in
                    self?.emit("Claude.event", ["id": id, "kind": kind, "payload": box.value])
                    if kind == "done" || kind == "error" { claudeStreams[id] = nil }
                }
            }
            claudeStreams[id] = stream
            try stream.start(key: key, system: params["system"] as? String ?? "", messages: params["messages"] as? [[String: Any]] ?? [],
                             effort: params["effort"] as? String ?? "medium")
            return ["id": id]
        case "Claude.cancel":
            if let id = params["id"] as? String { claudeStreams[id]?.cancel() }
            return true

        default:
            throw DevToolsError.unknownRequest
        }
    }

    /// `window.__sbDevExt` in the page world, installed at document start when React or dataLayer is on.
    private func callDevExtHooks(_ method: String, _ params: [String: Any]) async throws -> Any? {
        guard let page else { throw DevToolsError.noPage }
        if isPaused { throw DevToolsError.pausedInDebugger }
        let body = """
        if (!window.__sbDevExt) return { __missing: true };
        return window.__sbDevExt.handle(method, params);
        """
        return try await page.callAsyncJavaScript(body, arguments: ["method": method, "params": params], in: nil, contentWorld: .page)
    }

    // MARK: - Node

    /// What `node --inspect` advertises on each port, as chrome://inspect finds it.
    private func nodeTargets(ports: [Int]) async -> [[String: Any]] {
        var found: [[String: Any]] = []
        for port in ports where (1...65535).contains(port) {
            guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 0.8)
            request.httpShouldHandleCookies = false
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            var version: String?
            if let versionURL = URL(string: "http://127.0.0.1:\(port)/json/version"),
               let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: versionURL, timeoutInterval: 0.8)),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                version = info["Browser"] as? String
            }
            for var target in list {
                target["port"] = port
                if let version { target["version"] = version }
                found.append(target)
            }
        }
        return found
    }

    // MARK: - Xdebug

    private static let xdebugCookieNames = ["debug": "XDEBUG_SESSION", "profile": "XDEBUG_PROFILE", "trace": "XDEBUG_TRACE"]

    /// Like the Xdebug helper extensions: the trigger cookies for this site.
    private func xdebugCookies() async throws -> [String: Any] {
        guard let host = page?.url?.host() else { return [:] }
        let cookies = try await cookieStore().allCookies().filter { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host }
        var state: [String: Any] = ["host": host]
        for (mode, name) in Self.xdebugCookieNames {
            if let cookie = cookies.first(where: { $0.name == name }) { state[mode] = cookie.value }
        }
        return state
    }

    private func setXdebug(mode: String, on: Bool, ideKey: String) async throws -> [String: Any] {
        guard let url = page?.url, let host = url.host(), let name = Self.xdebugCookieNames[mode] else { throw DevToolsError.noPage }
        let store = try cookieStore()
        for cookie in await store.allCookies() where cookie.name == name && cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host {
            await store.deleteCookie(cookie)
        }
        if on, let cookie = HTTPCookie(properties: [.name: name, .value: ideKey.isEmpty ? "PHPSTORM" : ideKey, .domain: host, .path: "/"]) {
            await store.setCookie(cookie)
        }
        return try await xdebugCookies()
    }
}

/// A JSON payload crossing from URLSession's queue to the main actor.
private struct SendablePayload: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
