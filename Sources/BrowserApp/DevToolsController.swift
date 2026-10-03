import AppKit
import WebKit
import BrowserKit
import InspectKit

/// Hosts the DevTools UI (an HTML app in its own web view, the way Chrome's
/// is) and routes its requests to wherever they are answered:
///
/// - `DOM.*`, `CSS.*`, `Overlay.*`, `Storage.*`, `Page.getInfo`, `Sources.*`
///   → the isolated-world agent in the page (tamper-proof)
/// - `Runtime.*` → the page-world hooks (remote objects, evaluation)
/// - `Network.*`, `Console.*`, `Cookies.*`, `Settings.*`, `DevTools.*` → here
///
/// Events flow the other way from the recorder, so the panels show what was
/// recorded before they were opened.
@MainActor
final class DevToolsController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    let view: WKWebView
    private(set) weak var page: WKWebView?
    let recorder: InspectorRecorder
    let tab: TabID
    let networkLog = NetworkRequestLog()
    /// State of the tools in `DevToolsController+Tools.swift`.
    let tools = DevToolsToolState()
    private let isolatedWorld = WKContentWorld.world(name: InspectorAgent.isolatedWorldName)
    private var observation: UUID?
    private var isReady = false
    /// Console entries below this sequence were cleared by the user.
    private var consoleFloor = 0
    private var cachedUserAgent: String?

    /// WebKit Inspector Protocol access: the real debugger and resource
    /// contents. Nil-safe: everything else works without it.
    let protocolBridge: InspectorProtocolBridge
    /// `pending`, `attached`, or the reason it is unavailable.
    private(set) var protocolState = "pending"
    /// While the page is paused its JavaScript cannot run, so agent calls
    /// would hang until resume. They fail fast instead.
    private(set) var isPaused = false
    private var protocolRequests: [String: ProtocolRequest] = [:]
    /// Diagnostics: recent script calls into the page and how many are outstanding.
    private var pageCallLog: [String] = []
    private var pageCallsInFlight = 0
    private var webSockets: [String: WebSocketRecord] = [:]

    var onClose: (() -> Void)?
    var onDockSideChange: ((String) -> Void)?
    var onNavigate: ((URL) -> Void)?
    var onReload: (() -> Void)?
    /// Device mode: the device description from the UI, or nil to turn it off.
    var onEmulation: (([String: Any]?) -> Void)?
    var currentEmulation: (() -> [String: Any]?)?
    var dockSide: String {
        get { UserDefaults.standard.string(forKey: "devtools.dockSide") ?? "bottom" }
        set { UserDefaults.standard.set(newValue, forKey: "devtools.dockSide") }
    }

    private static let handlerName = "devtools"

    /// SwiftPM's `Bundle.module` only looks beside the executable, which is
    /// wrong inside an `.app`, where the packaging script puts resource
    /// bundles in `Contents/Resources`. Check there first.
    private static let resourceBundle: Bundle = {
        let name = "Keel_BrowserApp.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }()

    init(page: WKWebView, recorder: InspectorRecorder, tab: TabID, protocolBridge: InspectorProtocolBridge) {
        self.page = page
        self.recorder = recorder
        self.tab = tab
        self.protocolBridge = protocolBridge

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        configuration.userContentController.add(self, name: Self.handlerName)
        view.navigationDelegate = self
        view.isInspectable = true
        // Private: probed, so a WebKit without it leaves the background drawn instead of crashing.
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) || view.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            view.setValue(false, forKey: "drawsBackground")
        }

        for recorded in recorder.events where recorded.tab == tab {
            if case .network(let event) = recorded.event { networkLog.ingest(event) }
        }
        observation = recorder.observe { [weak self] change in self?.handle(change) }
        installActorHooks()

        if let url = Self.resourceBundle.url(forResource: "devtools", withExtension: "html", subdirectory: "DevToolsUI") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.loadHTMLString("<body style='font:13px system-ui;padding:2em'>DevTools UI resources are missing from the bundle.</body>", baseURL: nil)
        }
    }

    func tearDown() {
        if let token = observation { recorder.removeObserver(token); observation = nil }
        removeActorHooks()
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        view.navigationDelegate = nil
        didHide()
        protocolBridge.onEvent = nil
    }

    /// DevTools closed: a page must never stay frozen on a breakpoint nobody
    /// can see, so breakpoints go inactive and execution resumes.
    func didHide() {
        let wasPaused = isPaused
        isPaused = false
        toolsDidHide()
        Task {
            if protocolState == "attached" {
                _ = try? await protocolBridge.send("Debugger.setBreakpointsActive", ["active": false])
                // "Disable cache" means while DevTools is open, as in Chrome.
                _ = try? await protocolBridge.send("Network.setResourceCachingDisabled", ["disabled": false])
                if wasPaused { _ = try? await protocolBridge.send("Debugger.resume") }
            }
            _ = try? await callIsolated("Overlay.hideHighlight", [:])
        }
    }

    func didShow() {
        toolsDidShow()
        guard protocolState == "attached" else { return }
        emit("Protocol.shown", [:])
    }

    // MARK: - Driving the UI

    func showPanel(_ panel: String) {
        emit("DevTools.showPanel", ["panel": panel])
    }

    func startInspectMode() {
        emit("DevTools.startInspectMode", [:])
    }

    /// "Inspect Element" from the page's context menu.
    func inspectElement(atPagePoint point: CGPoint) {
        Task {
            guard let id = try? await callIsolated("DOM.elementFromPoint", ["x": point.x, "y": point.y]),
                  !(id is NSNull) else { return }
            emit("Overlay.inspectNodeRequested", ["nodeId": id])
        }
    }

    /// Messages from the agent that are not recorder events.
    func handleAuxiliary(kind: String, body: [String: Any]) {
        switch kind {
        case "inspect":
            if let id = body["nodeId"] { emit("Overlay.inspectNodeRequested", ["nodeId": id]) }
        case "inspectCancelled":
            emit("Overlay.inspectModeCanceled", [:])
        case "copy":
            if let text = body["text"] as? String { copyToPasteboard(text) }
        default:
            break
        }
    }

    /// Developer aid: run a script inside the DevTools UI and get its value.
    func evaluateInUI(_ script: String) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else { return }
        let id = body["id"]
        let params = body["params"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                let result = try await self.handle(method, params)
                self.reply(id: id, result: result)
            } catch {
                self.reply(id: id, error: Self.describe(error))
            }
        }
    }

    // MARK: - Request routing

    private func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        switch method {
        case "DevTools.ready":
            isReady = true
            var info: [String: Any] = [
                "dockSide": dockSide,
                "theme": UserDefaults.standard.string(forKey: "devtools.theme") ?? "system",
                "webkitInspectorAvailable": page.map { WebInspectorSPI.isAvailable(for: $0) } ?? false,
            ]
            if let page { info["url"] = page.url?.absoluteString ?? ""; info["title"] = page.title ?? "" }
            info["protocolState"] = protocolState
            if let emulation = currentEmulation?() { info["emulation"] = emulation }
            if let saved = UserDefaults.standard.string(forKey: "devtools.breakpoints") { info["breakpoints"] = saved }
            if protocolState != "attached" { Task { await attachProtocol() } }
            return info

        case "SourceMaps.fetch":
            // Maps are fetched by the app, not the page: no CORS, and with the profile's cookies.
            guard let raw = params["url"] as? String, let url = URL(string: raw) else { throw DevToolsError.unknownRequest }
            let (text, _, status) = try await fetchNatively(url)
            guard let text, (200..<300).contains(status) || status == 0 else { throw DevToolsError.protocolUnavailable("source map returned \(status)") }
            return ["text": text]

        case "Emulation.setDevice":
            onEmulation?(params); return true
        case "Emulation.clear":
            onEmulation?(nil); return true

        case "Protocol.send":
            guard let command = params["method"] as? String else { throw DevToolsError.protocolUnavailable("no method") }
            guard protocolState == "attached" else { throw DevToolsError.protocolUnavailable(protocolState) }
            return try await protocolBridge.send(command, params["params"] as? [String: Any] ?? [:])
        case "Protocol.scripts":
            guard protocolState == "attached" else { return [] as [Any] }
            return await protocolBridge.knownScripts()
        case "Protocol.evaluateInFrontend":
            // Diagnostics only: run script inside WebKit's hidden inspector frontend.
            return await protocolBridge.evaluateInFrontend(params["script"] as? String ?? "") ?? NSNull()
        case "Protocol.diagnose":
            var report = await protocolBridge.diagnose()
            report["pageCalls"] = Array(pageCallLog.suffix(25))
            report["pageCallsInFlight"] = pageCallsInFlight
            report["now"] = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000
            return report
        case "Protocol.state":
            return ["state": protocolState, "paused": isPaused,
                    "webkitInspectorVisible": page.map { WebInspectorSPI.isVisible($0) } ?? false]
        case "DevTools.close":
            onClose?(); return true
        case "DevTools.setDockSide":
            let side = params["side"] as? String ?? "bottom"
            dockSide = side
            onDockSideChange?(side)
            return true
        case "DevTools.openWebKitInspector":
            if let page { WebInspectorSPI.show(page) }
            return true
        case "Settings.set":
            if let key = params["key"] as? String {
                UserDefaults.standard.set(params["value"], forKey: "devtools." + key)
            }
            return true
        case "Settings.get":
            guard let key = params["key"] as? String else { return NSNull() }
            return UserDefaults.standard.object(forKey: "devtools." + key) ?? NSNull()
        case "Clipboard.write":
            copyToPasteboard(params["text"] as? String ?? "")
            return true
        case "DevTools.snapshot":
            // A picture of DevTools itself, as a PNG data URL: lets a driver
            // (or an assistant) see what the panels show, in either theme.
            let image = try await view.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw DevToolsError.protocolUnavailable("no image") }
            return ["dataURL": "data:image/png;base64," + png.base64EncodedString(), "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]

        case "Page.reload":
            onReload?(); return true
        case "Page.navigate":
            if let raw = params["url"] as? String, let url = BrowserSettings.destination(for: raw) { onNavigate?(url) }
            return true

        case "Console.getEntries":
            return consoleEntries()
        case "Console.clear":
            consoleFloor = recorder.events.last.map { $0.sequence + 1 } ?? 0
            _ = try? await callPage("Runtime.releaseObjects", [:])
            return true
        case "Console.evaluate":
            if let frame = params["callFrameId"] as? String, isPaused {
                return try await evaluateOnCallFrame(params["expression"] as? String ?? "", callFrameId: frame)
            }
            return try await evaluate(params["expression"] as? String ?? "")

        case "Network.getRequests":
            return try networkLog.requests.map(Self.jsonObject)
        case "Network.clear":
            networkLog.clear(); return true
        case "Network.getResponseBody", "Network.refetch":
            guard let raw = params["id"] as? String, let id = UUID(uuidString: raw),
                  let request = networkLog.request(id: id) else { throw DevToolsError.unknownRequest }
            if method == "Network.getResponseBody" {
                // The page hooks cut bodies at 256 KB; the engine has them whole.
                if let body = request.responseBody, !(request.protocolRequestID != nil && Self.isTruncatedByPageHooks(body)) {
                    return try Self.jsonObject(request)
                }
                if let body = await protocolResponseBody(request),
                   let updated = networkLog.setResponseBody(body, refetched: false, for: request.id) {
                    return try Self.jsonObject(updated)
                }
                // Not retrievable without asking the server again; the UI offers that explicitly.
                return try Self.jsonObject(request)
            }
            return try Self.jsonObject(try await refetch(request))
        case "Network.getWebSocketFrames":
            guard let raw = params["id"] as? String, let id = UUID(uuidString: raw),
                  let requestId = networkLog.request(id: id)?.protocolRequestID else { return [] as [Any] }
            return webSockets[requestId]?.frames ?? []
        case "Network.exportHAR":
            try await exportHAR(); return true

        case "Performance.getEntries":
            return performanceEntries()

        case "Cookies.list":
            return try await cookies().map(Self.cookieJSON)
        case "Cookies.delete":
            let store = try cookieStore()
            for cookie in try await cookies() where
                cookie.name == params["name"] as? String &&
                cookie.domain == params["domain"] as? String &&
                cookie.path == params["path"] as? String {
                await store.deleteCookie(cookie)
            }
            return true
        case "Cookies.clear":
            let store = try cookieStore()
            for cookie in try await cookies() { await store.deleteCookie(cookie) }
            return true

        case _ where Self.agentViewMethods.contains(method):
            return try await handleAgentView(method, params)
        case _ where Self.toolMethods.contains(method):
            return try await handleTool(method, params)
        case _ where Self.isExtensionMethod(method):
            return try await handleExtension(method, params)

        // Features that only the inspector protocol has. Our tree's node ids
        // are the agent's, so each call first finds the protocol's id.
        case "DOM.getEventListeners":
            let node = try await protocolNodeId(for: params)
            var result = try await protocolBridge.send("DOM.getEventListenersForNode", ["nodeId": node])
            result["nodeId"] = node   // so the UI can tell the node's own listeners from its ancestors'
            return result
        case "CSS.forcePseudoState":
            let node = try await protocolNodeId(for: params)
            return try await protocolBridge.send("CSS.forcePseudoState", ["nodeId": node, "forcedPseudoClasses": params["classes"] as? [String] ?? []])
        case "DOMDebugger.setDOMBreakpoint", "DOMDebugger.removeDOMBreakpoint":
            let node = try await protocolNodeId(for: params)
            _ = try await protocolBridge.send(method, ["nodeId": node, "type": params["type"] as? String ?? "subtree-modified"])
            return ["nodeId": node]   // a pause names the node by this id

        case "Sources.fetch":
            // The protocol returns the bytes the engine actually loaded, which
            // is what breakpoint line numbers refer to.
            if let content = await protocolResourceContent(params) { return content }
            do { return try await callIsolated(method, params) }
            catch {
                guard let raw = params["url"] as? String, let url = URL(string: raw) else { throw error }
                let (text, _, _) = try await fetchNatively(url)
                return ["text": text ?? "", "refetched": true]
            }

        default:
            if method.hasPrefix("Runtime.") {
                // Object ids minted by the protocol are JSON; ours are "o12".
                if let objectId = params["objectId"] as? String, objectId.hasPrefix("{") {
                    return try await protocolRuntime(method, objectId: objectId, params: params)
                }
                return try await callPage(method, params)
            }
            return try await callIsolated(method, params)
        }
    }

    // MARK: - Inspector protocol (debugger, resource contents)

    private func attachProtocol() async {
        guard protocolState != "attached", protocolState != "attaching" else { return }
        protocolState = "attaching"
        do {
            try await protocolBridge.attach()
            protocolBridge.onEvent = { [weak self] method, params in self?.handleProtocolEvent(method, params) }
            // Our injected agents are user scripts; stepping must never land in them.
            _ = try? await protocolBridge.send("Debugger.setShouldBlackboxURL",
                                               ["url": "^user-script:", "shouldBlackbox": true, "caseSensitive": true, "isRegex": true])
            _ = try? await protocolBridge.send("Debugger.setBreakpointsActive", ["active": true])
            protocolState = "attached"
            emit("Protocol.attached", ["scripts": await protocolBridge.knownScripts()])
        } catch {
            protocolState = error.localizedDescription
            emit("Protocol.unavailable", ["reason": protocolState])
        }
    }

    private func handleProtocolEvent(_ method: String, _ params: [String: Any]) {
        switch method {
        case "Debugger.paused":
            isPaused = true
            pageCallLog.append("\(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000) == PAUSED inFlight=\(pageCallsInFlight)")
        case "Debugger.resumed", "Debugger.globalObjectCleared":
            isPaused = false
        default:
            break
        }
        if method == "Network.requestIntercepted" { handleInterceptedRequest(params); return }
        if method.hasPrefix("Network.") { handleNetworkEvent(method, params); return }
        guard ["Debugger.", "ScriptProfiler.", "Timeline.", "Heap.", "Memory.", "Animation."].contains(where: method.hasPrefix) else { return }
        emit("Protocol.event", ["method": method, "params": params])
    }

    // MARK: - Network over the protocol

    /// A request the protocol has announced but not finished.
    private struct ProtocolRequest {
        var url: URL
        var method: String?
        var requestHeaders: [String: String] = [:]
        var requestBody: String?
        var type: String?
        var startedAt: Date
        var startTimestamp: Double
        var statusCode: Int?
        var responseHeaders: [String: String] = [:]
        var protocolName: String?
    }

    private func handleNetworkEvent(_ method: String, _ params: [String: Any]) {
        guard let requestId = params["requestId"] as? String else { return }
        recordNetworkExtras(method, requestId: requestId, params)
        if method.hasPrefix("Network.webSocket") { handleWebSocketEvent(method, requestId: requestId, params); return }
        switch method {
        case "Network.requestWillBeSent":
            // A redirect reuses the request id: what we have so far is a
            // finished request in its own right.
            if let redirect = params["redirectResponse"] as? [String: Any], var previous = protocolRequests[requestId] {
                Self.apply(response: redirect, to: &previous)
                finish(requestId: requestId, request: previous, timestamp: params["timestamp"] as? Double, metrics: nil, failure: nil)
            }
            guard let request = params["request"] as? [String: Any],
                  let raw = request["url"] as? String, let url = URL(string: raw) else { return }
            if protocolRequests.count > 2000 { protocolRequests.removeAll() }
            protocolRequests[requestId] = ProtocolRequest(
                url: url,
                method: request["method"] as? String,
                requestHeaders: Self.stringDictionary(request["headers"]),
                requestBody: request["postData"] as? String,
                type: params["type"] as? String,
                startedAt: (params["walltime"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .now,
                startTimestamp: params["timestamp"] as? Double ?? 0
            )
        case "Network.responseReceived":
            guard var pending = protocolRequests[requestId], let response = params["response"] as? [String: Any] else { return }
            Self.apply(response: response, to: &pending)
            if let type = params["type"] as? String { pending.type = type }
            protocolRequests[requestId] = pending
        case "Network.loadingFinished":
            guard let pending = protocolRequests.removeValue(forKey: requestId) else { return }
            finish(requestId: requestId, request: pending, timestamp: params["timestamp"] as? Double,
                   metrics: params["metrics"] as? [String: Any], failure: nil)
        case "Network.loadingFailed":
            guard let pending = protocolRequests.removeValue(forKey: requestId) else { return }
            let canceled = params["canceled"] as? Bool ?? false
            finish(requestId: requestId, request: pending, timestamp: params["timestamp"] as? Double, metrics: nil,
                   failure: (params["errorText"] as? String ?? "Failed") + (canceled ? " (canceled)" : ""))
        default:
            break
        }
    }

    private func finish(requestId: String, request: ProtocolRequest, timestamp: Double?, metrics: [String: Any]?, failure: String?) {
        let types = ["Document": "document", "StyleSheet": "stylesheet", "Image": "image", "Font": "font", "Script": "script",
                     "XHR": "xhr", "Fetch": "fetch", "Ping": "ping", "Beacon": "ping", "WebSocket": "websocket",
                     "EventSource": "fetch", "Media": "media", "Other": "other"]
        var requestHeaders = request.requestHeaders
        if let sent = metrics?["requestHeaders"] { requestHeaders.merge(Self.stringDictionary(sent)) { _, new in new } }
        let received = (metrics?["responseBodyBytesReceived"] as? NSNumber)?.int64Value
        let headerBytes = (metrics?["responseHeaderBytesReceived"] as? NSNumber)?.int64Value
        recorder.record(.network(NetworkEvent(
            source: .inspector,
            method: request.method,
            url: request.url,
            statusCode: request.statusCode,
            requestHeaders: requestHeaders,
            responseHeaders: request.responseHeaders,
            requestBody: request.requestBody,
            bodyUnavailable: true,
            failure: failure,
            startedAt: request.startedAt,
            duration: timestamp.map { max(0, $0 - request.startTimestamp) },
            bytesReceived: received.map { $0 + (headerBytes ?? 0) },
            decodedBodySize: (metrics?["responseBodyDecodedSize"] as? NSNumber)?.int64Value,
            protocolName: (metrics?["protocol"] as? String) ?? request.protocolName,
            protocolRequestID: requestId,
            resourceTypeHint: request.type.flatMap { types[$0] }
        )), tab: tab)
    }

    // MARK: - WebSockets

    private struct WebSocketRecord {
        var url: URL
        var startedAt = Date()
        var requestHeaders: [String: String] = [:]
        var frames: [[String: Any]] = []
        var recorded = false
    }

    private func handleWebSocketEvent(_ method: String, requestId: String, _ params: [String: Any]) {
        switch method {
        case "Network.webSocketCreated":
            guard let raw = params["url"] as? String, let url = URL(string: raw) else { return }
            if webSockets.count > 200 { webSockets.removeAll() }
            webSockets[requestId] = WebSocketRecord(url: url)
        case "Network.webSocketWillSendHandshakeRequest":
            if let request = params["request"] as? [String: Any] {
                webSockets[requestId]?.requestHeaders = Self.stringDictionary(request["headers"])
            }
        case "Network.webSocketHandshakeResponseReceived":
            guard var socket = webSockets[requestId], !socket.recorded else { return }
            socket.recorded = true
            webSockets[requestId] = socket
            let response = params["response"] as? [String: Any] ?? [:]
            var headers: [String: String] = [:]
            for (key, value) in Self.stringDictionary(response["headers"]) { headers[key.lowercased()] = value }
            recorder.record(.network(NetworkEvent(
                source: .inspector, method: "GET", url: socket.url,
                statusCode: (response["status"] as? NSNumber)?.intValue ?? 101,
                requestHeaders: socket.requestHeaders, responseHeaders: headers,
                bodyUnavailable: true, startedAt: socket.startedAt,
                protocolRequestID: requestId, resourceTypeHint: "websocket"
            )), tab: tab)
        case "Network.webSocketFrameSent", "Network.webSocketFrameReceived", "Network.webSocketFrameError":
            var frame: [String: Any] = ["time": Date().timeIntervalSince1970 * 1000]
            if method.hasSuffix("Error") {
                frame["direction"] = "error"
                frame["data"] = params["errorMessage"] as? String ?? "error"
            } else {
                let payload = params["response"] as? [String: Any] ?? [:]
                let data = payload["payloadData"] as? String ?? ""
                frame["direction"] = method.hasSuffix("Sent") ? "sent" : "received"
                frame["opcode"] = (payload["opcode"] as? NSNumber)?.intValue ?? 1
                frame["length"] = (payload["payloadLength"] as? NSNumber)?.intValue ?? data.utf8.count
                frame["data"] = data.count > 65_536 ? String(data.prefix(65_536)) + "\u{2026}" : data
            }
            appendFrame(frame, to: requestId)
        case "Network.webSocketClosed":
            appendFrame(["time": Date().timeIntervalSince1970 * 1000, "direction": "closed", "data": "Connection closed"], to: requestId)
        default:
            break
        }
    }

    private func appendFrame(_ frame: [String: Any], to requestId: String) {
        guard webSockets[requestId] != nil else { return }
        webSockets[requestId]?.frames.append(frame)
        if let count = webSockets[requestId]?.frames.count, count > 2000 { webSockets[requestId]?.frames.removeFirst(count - 2000) }
        emit("Network.webSocketFrame", ["requestId": requestId, "frame": frame])
    }

    private static func apply(response: [String: Any], to request: inout ProtocolRequest) {
        request.statusCode = (response["status"] as? NSNumber)?.intValue
        var headers: [String: String] = [:]
        for (key, value) in stringDictionary(response["headers"]) { headers[key.lowercased()] = value }
        request.responseHeaders = headers
        if let sent = response["requestHeaders"] { request.requestHeaders.merge(stringDictionary(sent)) { _, new in new } }
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.mapValues { $0 as? String ?? "\($0)" }
    }

    /// The body exactly as the page received it, by protocol request id.
    private func protocolResponseBody(_ request: NetworkRequest) async -> String? {
        guard protocolState == "attached", let requestId = request.protocolRequestID,
              let result = try? await protocolBridge.send("Network.getResponseBody", ["requestId": requestId]),
              let body = result["body"] as? String else { return nil }
        guard result["base64Encoded"] as? Bool == true else { return body }
        let mime = request.mimeType ?? "application/octet-stream"
        // Images, fonts, media and other binary bodies travel to the UI as
        // data URLs, so the Preview can render them and show their bytes.
        if mime.hasPrefix("image/") || Self.isBinaryMime(mime) { return Self.binaryDataURL(base64: body, mime: mime) }
        if let data = Data(base64Encoded: body), let text = String(data: data, encoding: .utf8) { return text }
        return Self.binaryDataURL(base64: body, mime: mime)
    }

    private func protocolResourceContent(_ params: [String: Any]) async -> [String: Any]? {
        guard protocolState == "attached" else { return nil }
        if let scriptId = params["scriptId"] as? String,
           let result = try? await protocolBridge.send("Debugger.getScriptSource", ["scriptId": scriptId]),
           let text = result["scriptSource"] as? String {
            return ["text": text, "original": true]
        }
        guard let url = params["url"] as? String,
              let tree = try? await protocolBridge.send("Page.getResourceTree"),
              let frameTree = tree["frameTree"] as? [String: Any] else { return nil }
        for frameId in Self.frameIds(in: frameTree, containing: url) {
            guard let result = try? await protocolBridge.send("Page.getResourceContent", ["frameId": frameId, "url": url]),
                  let content = result["content"] as? String else { continue }
            if result["base64Encoded"] as? Bool == true {
                guard let data = Data(base64Encoded: content), let text = String(data: data, encoding: .utf8) else { continue }
                return ["text": text, "original": true]
            }
            return ["text": content, "original": true]
        }
        return nil
    }

    /// Frames whose document or resources include `url`, main frame first.
    private static func frameIds(in tree: [String: Any], containing url: String) -> [String] {
        var ids: [String] = []
        if let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String {
            let resources = (tree["resources"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            if frame["url"] as? String == url || resources.contains(url) { ids.append(id) }
        }
        for child in tree["childFrames"] as? [[String: Any]] ?? [] { ids += frameIds(in: child, containing: url) }
        return ids
    }

    private func evaluateOnCallFrame(_ expression: String, callFrameId: String) async throws -> Any? {
        recorder.record(.console(ConsoleEntry(level: .info, type: "command", message: expression)), tab: tab)
        do {
            let result = try await protocolBridge.send("Debugger.evaluateOnCallFrame", [
                "callFrameId": callFrameId, "expression": expression, "objectGroup": "console",
                "includeCommandLineAPI": true, "returnByValue": false, "generatePreview": true,
            ])
            let object = Self.normalize(protocolObject: result["result"] as? [String: Any] ?? [:])
            let args = Self.decodeRemoteObjects([object]) ?? []
            let thrown = result["wasThrown"] as? Bool ?? false
            recorder.record(.console(ConsoleEntry(level: thrown ? .error : .info, type: "result",
                                                  message: (thrown ? "Uncaught " : "") + (args.first?.description ?? "undefined"),
                                                  args: thrown ? [] : args)), tab: tab)
            return thrown ? ["exceptionDetails": ["text": args.first?.description ?? "error"]] : ["result": object]
        } catch {
            recorder.record(.console(ConsoleEntry(level: .error, type: "result", message: Self.describe(error))), tab: tab)
            return NSNull()
        }
    }

    private func protocolRuntime(_ method: String, objectId: String, params: [String: Any]) async throws -> Any? {
        switch method {
        case "Runtime.getProperties":
            let result = try await protocolBridge.send("Runtime.getProperties",
                                                       ["objectId": objectId, "ownProperties": true, "generatePreview": true])
            var out: [[String: Any]] = []
            for property in result["properties"] as? [[String: Any]] ?? [] {
                var entry: [String: Any] = [
                    "name": property["name"] as? String ?? "",
                    "isOwn": property["isOwn"] as? Bool ?? true,
                    "enumerable": property["enumerable"] as? Bool ?? true,
                ]
                if let value = property["value"] as? [String: Any] {
                    entry["value"] = Self.normalize(protocolObject: value)
                } else {
                    entry["isAccessor"] = true
                    entry["value"] = ["type": "accessor", "description": "(...)"]
                }
                if entry["name"] as? String == "__proto__" { entry["name"] = "[[Prototype]]"; entry["isInternal"] = true }
                out.append(entry)
            }
            for property in result["internalProperties"] as? [[String: Any]] ?? [] {
                guard let value = property["value"] as? [String: Any] else { continue }
                out.append(["name": "[[" + (property["name"] as? String ?? "") + "]]", "isOwn": false, "enumerable": false,
                            "isInternal": true, "value": Self.normalize(protocolObject: value)])
            }
            return out
        case "Runtime.invokeGetter":
            let result = try await protocolBridge.send("Runtime.callFunctionOn", [
                "objectId": objectId, "functionDeclaration": "function(name) { return this[name]; }",
                "arguments": [["value": params["name"] as? String ?? ""]], "generatePreview": true,
            ])
            return Self.normalize(protocolObject: result["result"] as? [String: Any] ?? [:])
        case "Runtime.revealNode", "Runtime.highlightNode":
            // The isolated world listens for these on the node itself (dom-agent.js).
            let event = method == "Runtime.revealNode" ? "__sbReveal" : "__sbHighlight"
            _ = try await protocolBridge.send("Runtime.callFunctionOn", [
                "objectId": objectId, "returnByValue": true, "arguments": [["value": event]],
                "functionDeclaration": "function(type) { if (this && this.nodeType) this.dispatchEvent(new CustomEvent(type)); return true; }",
            ])
            return true
        case "Runtime.storeAsGlobal", "Runtime.getFunctionSource", "Runtime.copy":
            let declarations = [
                "Runtime.storeAsGlobal": "function() { var i = 1; while (('temp' + i) in window) i++; window['temp' + i] = this; return { name: 'temp' + i }; }",
                "Runtime.getFunctionSource": "function() { return { source: Function.prototype.toString.call(this), name: this.name || '' }; }",
                "Runtime.copy": "function() { try { return this && this.nodeType ? this.outerHTML : JSON.stringify(this, null, 2); } catch (e) { return String(this); } }",
            ]
            let result = try await protocolBridge.send("Runtime.callFunctionOn", [
                "objectId": objectId, "returnByValue": true, "functionDeclaration": declarations[method] ?? "",
            ])
            return (result["result"] as? [String: Any])?["value"] ?? NSNull()
        default:
            throw DevToolsError.protocolUnavailable("\(method) is not supported for debugger objects")
        }
    }

    /// WebKit's RemoteObject → the shape the UI's object tree renders:
    /// a `description` is always present, and arrays say their length.
    private static func normalize(protocolObject object: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["type": object["type"] as? String ?? "undefined"]
        for key in ["subtype", "className", "objectId"] { if let value = object[key] as? String { out[key] = value } }
        var description = object["description"] as? String
        if description == nil, let value = object["value"] {
            description = value is NSNull ? "null" : "\(value)"
        }
        if let preview = object["preview"] as? [String: Any] {
            if out["subtype"] as? String == "array", let size = preview["size"] as? Int { description = "Array(\(size))" }
            let properties = (preview["properties"] as? [[String: Any]] ?? []).map { property -> [String: Any] in
                var p: [String: Any] = ["name": property["name"] as? String ?? "", "type": property["type"] as? String ?? "",
                                        "value": property["value"] as? String ?? ""]
                if let subtype = property["subtype"] as? String { p["subtype"] = subtype }
                // A nested object comes as its own preview, without a value: name it as Chrome does.
                if property["value"] == nil, let nested = property["valuePreview"] as? [String: Any] {
                    let description = nested["description"] as? String ?? ""
                    if property["subtype"] as? String == "array", let size = nested["size"] as? Int { p["value"] = "Array(\(size))" }
                    else { p["value"] = description.isEmpty || description == "Object" ? "{…}" : description }
                }
                if property["type"] as? String == "function", property["value"] == nil { p["value"] = "ƒ" }
                if p["type"] as? String == "string" { p["value"] = "\"\(p["value"] as? String ?? "")\"" }
                return p
            }
            out["preview"] = ["properties": properties, "overflow": preview["overflow"] as? Bool ?? false]
        }
        if out["subtype"] as? String == "null" { description = "null" }
        out["description"] = description ?? (out["type"] as? String == "undefined" ? "undefined" : "")
        return out
    }

    /// The protocol's node id for a node in our tree: the agent marks the
    /// node, the page world remembers it, and the protocol resolves that.
    func protocolNodeId(for params: [String: Any]) async throws -> Int {
        guard protocolState == "attached" else { throw DevToolsError.protocolUnavailable(protocolState) }
        guard let agentNode = (params["nodeId"] as? NSNumber)?.intValue else { throw DevToolsError.unknownRequest }
        _ = try await callIsolated("DOM.mark", ["nodeId": agentNode])
        let evaluated = try await protocolBridge.send("Runtime.evaluate", ["expression": "window.__sbInspector && window.__sbInspector.marked", "objectGroup": "sb-node"])
        defer { Task { _ = try? await protocolBridge.send("Runtime.releaseObjectGroup", ["objectGroup": "sb-node"]) } }
        guard let objectId = (evaluated["result"] as? [String: Any])?["objectId"] as? String else {
            throw DevToolsError.protocolUnavailable("the node is no longer in the document")
        }
        let requested = try await protocolBridge.send("DOM.requestNode", ["objectId": objectId])
        guard let node = (requested["nodeId"] as? NSNumber)?.intValue, node > 0 else {
            throw DevToolsError.protocolUnavailable("the node is no longer in the document")
        }
        return node
    }

    // MARK: - Agents

    func callIsolated(_ method: String, _ params: [String: Any]) async throws -> Any? {
        if Self.toolsAgentPrefixes.contains(where: method.hasPrefix) { try await loadToolsAgent() }
        return try await call(global: "__sbAgent", world: isolatedWorld, method, params)
    }

    /// The tools agent is injected on first use, not at document start: pages
    /// pay nothing for the audits, a11y, storage and animation tools until
    /// someone opens them.
    private func loadToolsAgent() async throws {
        guard let page else { throw DevToolsError.noPage }
        if isPaused { throw DevToolsError.pausedInDebugger }
        let source = try InspectorAgent.onDemandSource(.tools)
        _ = try await page.callAsyncJavaScript(
            "if (window.__sbAgent && !window.__sbAgent.has(\"Tools.loaded\")) { \(source) }\nreturn true;",
            arguments: [:], in: nil, contentWorld: isolatedWorld)
    }

    func callPage(_ method: String, _ params: [String: Any]) async throws -> Any? {
        try await call(global: "__sbInspector", world: .page, method, params)
    }

    private func call(global: String, world: WKContentWorld, _ method: String, _ params: [String: Any]) async throws -> Any? {
        guard let page else { throw DevToolsError.noPage }
        pageCallLog.append("\(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000) \(method) paused=\(isPaused) inFlight=\(pageCallsInFlight)")
        if pageCallLog.count > 300 { pageCallLog.removeFirst(100) }
        if isPaused { throw DevToolsError.pausedInDebugger }
        pageCallsInFlight += 1
        defer { pageCallsInFlight -= 1 }
        let body = """
        if (!window.\(global)) throw new Error("The inspector agent is not loaded in this document. Reload the page.");
        return window.\(global).handle(method, params);
        """
        return try await page.callAsyncJavaScript(body, arguments: ["method": method, "params": params], in: nil, contentWorld: world)
    }

    private func evaluate(_ expression: String) async throws -> Any? {
        recorder.record(.console(ConsoleEntry(level: .info, type: "command", message: expression)), tab: tab)
        let outcome: Any?
        do {
            outcome = try await callPage("Runtime.evaluate", ["expression": expression])
        } catch {
            recorder.record(.console(ConsoleEntry(level: .error, type: "result", message: Self.describe(error))), tab: tab)
            return NSNull()
        }
        guard let dict = outcome as? [String: Any] else { return NSNull() }
        if let exception = dict["exceptionDetails"] as? [String: Any] {
            var args: [RemoteObject] = []
            if let raw = exception["exception"], let decoded = Self.decodeRemoteObjects([raw]) { args = decoded }
            recorder.record(.console(ConsoleEntry(level: .error, type: "result",
                                                  message: "Uncaught " + (exception["text"] as? String ?? "error"),
                                                  args: args)), tab: tab)
        } else if let raw = dict["result"], let args = Self.decodeRemoteObjects([raw]) {
            recorder.record(.console(ConsoleEntry(level: .info, type: "result",
                                                  message: args.first?.description ?? "undefined",
                                                  args: args)), tab: tab)
        }
        return dict
    }

    private static func decodeRemoteObjects(_ raw: [Any]) -> [RemoteObject]? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([RemoteObject].self, from: data)
    }

    // MARK: - Recorder → UI

    private func handle(_ change: InspectorRecorder.Change) {
        switch change {
        case .cleared:
            networkLog.clear()
            emit("Recorder.cleared", [:])
        case .appended(let recorded):
            guard recorded.tab == tab else { return }
            switch recorded.event {
            case .console(let entry):
                guard let json = try? Self.jsonObject(entry) else { return }
                emit("Console.entryAdded", ["entry": json, "source": Self.source(of: recorded.event).rawValue,
                                            "sequence": recorded.sequence])
            case .network(let event):
                switch networkLog.ingest(event) {
                case .added(let request):
                    if let json = try? Self.jsonObject(request) { emit("Network.requestAdded", ["request": json]) }
                case .updated(let request):
                    if let json = try? Self.jsonObject(request) { emit("Network.requestUpdated", ["request": json]) }
                }
            case .dom(let batch):
                if let json = try? Self.jsonObject(batch) as? [String: Any] { emit("DOM.mutated", json) }
            case .performance(let entry):
                if let json = try? Self.jsonObject(entry) {
                    emit("Performance.entryAdded", ["entry": json, "sequence": recorded.sequence])
                }
            case .navigation(let nav):
                emit("Page.navigated", ["url": nav.url.absoluteString, "phase": nav.phase.rawValue,
                                        "sequence": recorded.sequence, "title": page?.title ?? ""])
                if nav.phase == .agentReady { emit("DOM.documentUpdated", [:]) }
            }
        }
    }

    private func consoleEntries() -> [[String: Any]] {
        recorder.events.compactMap { recorded -> [String: Any]? in
            guard recorded.tab == tab, recorded.sequence >= consoleFloor,
                  case .console(let entry) = recorded.event,
                  let json = try? Self.jsonObject(entry) else { return nil }
            return ["entry": json, "source": Self.source(of: recorded.event).rawValue, "sequence": recorded.sequence]
        }
    }

    private func performanceEntries() -> [[String: Any]] {
        recorder.events.compactMap { recorded -> [String: Any]? in
            guard recorded.tab == tab else { return nil }
            switch recorded.event {
            case .performance(let entry):
                guard let json = try? Self.jsonObject(entry) else { return nil }
                return ["kind": "performance", "entry": json, "sequence": recorded.sequence]
            case .navigation(let nav):
                return ["kind": "navigation", "url": nav.url.absoluteString, "phase": nav.phase.rawValue,
                        "sequence": recorded.sequence, "timestamp": nav.timestamp.timeIntervalSince1970 * 1000]
            default:
                return nil
            }
        }
    }

    private static func source(of event: InspectorEvent) -> EventSource {
        switch event {
        case .console(let e):
            if e.type == "command" || e.type == "result" { return .user }
            return e.isUncaught && e.args.isEmpty ? .agent : .pageWorld
        case .network(let e):    return e.source
        case .dom, .performance: return .agent
        case .navigation(let e): return e.phase == .agentReady ? .agent : .navigationDelegate
        }
    }

    // MARK: - Network extras

    private func refetch(_ request: NetworkRequest) async throws -> NetworkRequest {
        let (text, mime, _) = try await fetchNatively(request.url, method: request.method, binaryAsDataURL: true)
        return networkLog.setResponseBody(text, refetched: true, for: request.id).map { updated in
            var copy = updated
            if copy.mimeType == nil { copy.mimeType = mime }
            return copy
        } ?? request
    }

    /// Fetches with the profile's cookies and the page's user agent, from the
    /// app rather than the page: no CORS, but also no guarantee the server
    /// returns what the page originally received.
    func fetchNatively(_ url: URL, method: String? = nil, binaryAsDataURL: Bool = false) async throws -> (String?, String?, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method == "POST" ? "GET" : (method ?? "GET")
        // Only this profile's cookies, set below. `URLSession.shared` keeps
        // one jar for the whole app: left to handle cookies it would add
        // another profile's and store this response's for the next one.
        request.httpShouldHandleCookies = false
        if let ua = await userAgent() { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let store = try? cookieStore() {
            let cookies = await store.allCookies().filter { Self.cookie($0, applies: url) }
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let mime = response.mimeType?.lowercased() ?? ""
        let textual = mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml")
            || mime.contains("javascript") || mime.contains("css") || mime.contains("svg") || mime.isEmpty
        if textual {
            var encoding = String.Encoding.utf8
            if let name = response.textEncodingName {
                let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                if cf != kCFStringEncodingInvalidId {
                    encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                }
            }
            return (String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self), mime, http?.statusCode ?? 0)
        }
        if mime.hasPrefix("image/") || binaryAsDataURL {
            return (Self.binaryDataURL(base64: data.base64EncodedString(), mime: mime), mime, http?.statusCode ?? 0)
        }
        return (nil, mime, http?.statusCode ?? 0)
    }

    private func userAgent() async -> String? {
        if let ua = page?.customUserAgent, !ua.isEmpty { return ua }
        if let cached = cachedUserAgent { return cached }
        let ua = try? await page?.evaluateJavaScript("navigator.userAgent") as? String
        cachedUserAgent = ua
        return ua
    }

    private func exportHAR() async throws {
        guard let window = view.window else { return }
        let data = try HARExporter.export(networkLog.requests, pageURL: page?.url, pageTitle: page?.title)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(page?.url?.host() ?? "page").har"
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Cookies

    func cookieStore() throws -> WKHTTPCookieStore {
        guard let page else { throw DevToolsError.noPage }
        return page.configuration.websiteDataStore.httpCookieStore
    }

    private func cookies() async throws -> [HTTPCookie] {
        let all = try await cookieStore().allCookies()
        guard let url = page?.url, url.host() != nil else { return all }
        return all.filter { Self.cookie($0, matchesHostOf: url) }
    }

    private static func cookie(_ cookie: HTTPCookie, matchesHostOf url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == bare || host.hasSuffix("." + bare)
    }

    private static func cookie(_ cookie: HTTPCookie, applies url: URL) -> Bool {
        guard cookie.isSecure == false || url.scheme == "https" else { return false }
        return self.cookie(cookie, matchesHostOf: url) && url.path.hasPrefix(cookie.path)
    }

    private static func cookieJSON(_ cookie: HTTPCookie) -> [String: Any] {
        [
            "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
            "expires": cookie.expiresDate.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "size": cookie.name.utf8.count + cookie.value.utf8.count,
            "httpOnly": cookie.isHTTPOnly, "secure": cookie.isSecure,
            "sameSite": cookie.sameSitePolicy?.rawValue ?? "",
        ]
    }

    // MARK: - Plumbing

    private func reply(id: Any?, result: Any?) {
        guard let id else { return }
        send(["id": id, "result": result ?? NSNull()])
    }

    private func reply(id: Any?, error: String) {
        guard let id else { return }
        send(["id": id, "error": error])
    }

    func emit(_ method: String, _ params: Any) {
        guard isReady else { return }
        send(["method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.DevTools && DevTools.dispatch(\(json))") { _, _ in }
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String { return message }
        return error.localizedDescription
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - WKNavigationDelegate (links inside the UI open in the page)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            onNavigate?(url)
            return .cancel
        }
        return .allow
    }
}

enum DevToolsError: LocalizedError {
    case noPage
    case unknownRequest
    case pausedInDebugger
    case protocolUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noPage:                       return "No page is loaded."
        case .unknownRequest:               return "That request is no longer in the log."
        case .pausedInDebugger:             return "The page is paused in the debugger. Resume to inspect the live page."
        case .protocolUnavailable(let why): return "Debugger unavailable: \(why)"
        }
    }
}
