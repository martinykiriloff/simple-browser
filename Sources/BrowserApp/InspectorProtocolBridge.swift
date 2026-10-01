import WebKit

/// Raw access to the WebKit Inspector Protocol for one page, by borrowing the
/// connection of WebKit's own (hidden) inspector frontend.
///
/// `_WKInspector.connect` creates the frontend page without showing it. That
/// page is an ordinary web view whose script owns the protocol connection to
/// the inspected page, so a small shim evaluated in it can send our commands
/// and copy every backend message to us. This is what gives the DevTools a
/// real JavaScriptCore debugger and real network data; everything here is
/// private API, reached by selector with runtime probes, and the DevTools
/// degrade to the agent-only feature set when it is unavailable.
@MainActor
final class InspectorProtocolBridge: NSObject, WKScriptMessageHandler {

    enum BridgeError: LocalizedError {
        case unavailable(String)
        case commandFailed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why):   return "Inspector protocol unavailable: \(why)"
            case .commandFailed(let why): return why
            case .timedOut(let method):   return "\(method) timed out"
            }
        }
    }

    private weak var page: WKWebView?
    private weak var frontend: WKWebView?
    /// Results travel as JSON `Data`, which is `Sendable`; dictionaries of `Any` are not.
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private(set) var isAttached = false
    private var attachTask: Task<Void, any Error>?

    /// Every protocol event from the inspected page: method name and params.
    var onEvent: ((String, [String: Any]) -> Void)?

    private static let handlerName = "sbProtocol"

    init(page: WKWebView) {
        self.page = page
    }

    // MARK: - Attaching

    /// Connects the hidden frontend and installs the shim. Safe to call
    /// repeatedly; concurrent callers share one attempt.
    func attach() async throws {
        if isAttached { return }
        if let attachTask { return try await attachTask.value }
        let task = Task { @MainActor in try await self.performAttach() }
        attachTask = task
        defer { attachTask = nil }
        try await task.value
    }

    private func performAttach() async throws {
        guard let page else { throw BridgeError.unavailable("no page") }
        guard let inspector = Self.object(page, "_inspector") else {
            throw BridgeError.unavailable("WKWebView has no _inspector")
        }
        guard inspector.responds(to: NSSelectorFromString("connect")) else {
            throw BridgeError.unavailable("_WKInspector has no connect")
        }
        _ = inspector.perform(NSSelectorFromString("connect"))

        // The frontend web view appears once the frontend page is created.
        var frontendView: WKWebView?
        for _ in 0..<100 {
            if let view = Self.object(inspector, "inspectorWebView") as? WKWebView { frontendView = view; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let frontendView else { throw BridgeError.unavailable("inspectorWebView never appeared") }
        frontend = frontendView

        let controller = frontendView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        controller.add(self, name: Self.handlerName)

        // Wait for the frontend application to finish booting.
        var state = ""
        for _ in 0..<200 {
            state = (try? await frontendView.evaluateJavaScript(Self.readinessProbe) as? String) ?? "error"
            if state == "ready" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard state == "ready" else { throw BridgeError.unavailable("frontend not ready (\(state))") }

        let installed = try await frontendView.evaluateJavaScript(Self.shim) as? String
        guard installed == "installed" || installed == "already" else {
            throw BridgeError.unavailable("shim failed: \(installed ?? "nil")")
        }
        isAttached = true
    }

    func detach() {
        frontend?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        for (_, continuation) in pending { continuation.resume(throwing: BridgeError.unavailable("detached")) }
        pending.removeAll()
        isAttached = false
    }

    // MARK: - Commands

    /// Sends one protocol command to the inspected page and returns `result`.
    func send(_ method: String, _ params: [String: Any] = [:], timeout: Duration = .seconds(10)) async throws -> [String: Any] {
        try await attach()
        guard let frontend else { throw BridgeError.unavailable("no frontend") }
        let payload = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let json = String(decoding: payload, as: UTF8.self)
        let raw = try await frontend.evaluateJavaScript("window.__sbProtocol ? window.__sbProtocol.send(\(json)) : -1")
        guard let id = (raw as? NSNumber)?.intValue, id >= 0 else {
            isAttached = false
            throw BridgeError.unavailable("shim is gone")
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if let waiting = self.pending.removeValue(forKey: id) {
                    waiting.resume(throwing: BridgeError.timedOut(method))
                }
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Evaluates script in WebKit's inspector frontend itself, to read state
    /// it collected before the shim was installed.
    func evaluateInFrontend(_ script: String) async -> Any? {
        guard let frontend else { return nil }
        return try? await frontend.evaluateJavaScript(script)
    }

    /// What the relay looks like right now; for diagnosing stalls.
    func diagnose() async -> [String: Any] {
        let script = """
        (function () {
          var out = {};
          try {
            out.shim = typeof window.__sbProtocol;
            out.stats = window.__sbProtocol && window.__sbProtocol.stats;
            out.mainTarget = WI.mainTarget && WI.mainTarget.identifier;
            out.targets = Array.from(WI.targets || []).map(function (t) { return t.identifier + ":" + t.type; });
            out.frontendThinksPaused = !!(WI.debuggerManager && WI.debuggerManager.paused);
          } catch (e) { out.error = String(e); }
          return JSON.stringify(out);
        })()
        """
        var report: [String: Any] = ["pendingIds": pending.keys.sorted(), "attached": isAttached]
        if let json = await evaluateInFrontend(script) as? String, let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) { report["frontend"] = object }
        else { report["frontend"] = "no answer from the frontend web view" }
        return report
    }

    /// Scripts the backend reported before we were listening. The frontend
    /// keeps them per target; the field names are WebKit internals, so every
    /// access is guarded and an empty list is a valid answer.
    func knownScripts() async -> [[String: Any]] {
        let script = """
        (function () {
          var out = [];
          try {
            var maps = [];
            var dm = WI.debuggerManager;
            if (dm._scriptIdMap) maps.push(dm._scriptIdMap);
            if (dm._targetDebuggerDataMap) dm._targetDebuggerDataMap.forEach(function (data) {
              if (data._scriptIdMap) maps.push(data._scriptIdMap);
            });
            maps.forEach(function (m) { m.forEach(function (s) {
              out.push({ scriptId: String(s.id), url: s.url || "", sourceURL: s.sourceURL || "",
                         sourceMapURL: s.sourceMapURL || s._sourceMapURL || s.sourceMappingURL || s._sourceMappingURL || "",
                         startLine: s.range ? s.range.startLine : 0, endLine: s.range ? s.range.endLine : 0 });
            }); });
          } catch (e) {}
          return JSON.stringify(out);
        })()
        """
        guard let json = await evaluateInFrontend(script) as? String, let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = (object["id"] as? NSNumber)?.intValue {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: BridgeError.commandFailed(error["message"] as? String ?? "protocol error"))
            } else {
                let result = object["result"] as? [String: Any] ?? [:]
                continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8))
            }
        } else if let method = object["method"] as? String {
            onEvent?(method, object["params"] as? [String: Any] ?? [:])
        }
    }

    // MARK: - SPI plumbing

    private static func object(_ target: NSObject, _ selectorName: String) -> NSObject? {
        let selector = NSSelectorFromString(selectorName)
        guard target.responds(to: selector), let value = target.perform(selector) else { return nil }
        return value.takeUnretainedValue() as? NSObject
    }

    /// For diagnostics: the Objective-C API surface of `_WKInspector`.
    static func inspectorSelectors(for page: WKWebView) -> [String] {
        guard let inspector = object(page, "_inspector") else { return [] }
        var names: [String] = []
        var cls: AnyClass? = type(of: inspector)
        while let current = cls, NSStringFromClass(current) != "NSObject" {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(current, &count) {
                for index in 0..<Int(count) { names.append(NSStringFromSelector(method_getName(methods[index]))) }
                free(methods)
            }
            cls = class_getSuperclass(current)
        }
        return names.sorted()
    }

    private static let readinessProbe = """
    (function () {
      try {
        if (typeof InspectorBackend === "undefined") return "no InspectorBackend";
        if (typeof WI === "undefined") return "no WI";
        if (!WI.mainTarget) return "no mainTarget";
        if (!WI.mainTarget.connection) return "no connection";
        return "ready";
      } catch (e) { return "error: " + e; }
    })()
    """

    /// Runs in WebKit's inspector frontend. Commands go out on whatever the
    /// current main target's connection is (it changes across process swaps);
    /// every incoming message is copied to the native side, and responses to
    /// our own ids are kept away from the frontend, which does not know them.
    private static let shim = """
    (function () {
      if (window.__sbProtocol) return "already";
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) return "no message handler";
      var BASE = 1000000000, next = BASE;

      // Returns true when the frontend must not see the message.
      function inspect(inner) {
        if (!inner) return false;
        if (typeof inner.id === "number" && inner.id >= BASE) { handler.postMessage(JSON.stringify(inner)); return true; }
        if (inner.method && inner.method.indexOf("Target.") !== 0) {
          handler.postMessage(JSON.stringify(inner));
          // WebKit's frontend raises its own window when the debugger
          // pauses. Pauses belong to our UI, so it never hears about them.
          if (inner.method === "Debugger.paused" || inner.method === "Debugger.resumed") return true;
          // Profiles and timelines are only ever started by us; the frontend
          // did not ask for them and asserts when they turn up.
          if (inner.method.indexOf("ScriptProfiler.") === 0 || inner.method.indexOf("Timeline.") === 0) return true;
          // Same for memory and animation tracking.
          if (["Heap.tracking", "Memory.tracking", "Animation.tracking"].some(function (p) { return inner.method.indexOf(p) === 0; })) return true;
          // Intercepted requests are answered by us; the frontend would
          // continue them unchanged, racing our override.
          if (inner.method === "Network.requestIntercepted" || inner.method === "Network.responseIntercepted") return true;
        }
        return false;
      }
      function intercept(message) {
        var object = message;
        try { if (typeof message === "string") object = JSON.parse(message); } catch (e) { return false; }
        try {
          // Page-level traffic arrives wrapped for its target.
          if (object && object.method === "Target.dispatchMessageFromTarget" && object.params && typeof object.params.message === "string") {
            return inspect(JSON.parse(object.params.message));
          }
          return inspect(object);
        } catch (e) { return false; }
      }

      // Hook the native entry point rather than the frontend's dispatcher:
      // the frontend queues messages behind a setTimeout, and timers in a
      // page that is never shown are throttled, so this keeps our replies
      // off that path.
      var api = window.InspectorFrontendAPI;
      var hooked = false;
      ["dispatchMessageAsync", "dispatchMessage"].forEach(function (name) {
        if (!api || typeof api[name] !== "function") return;
        var original = api[name];
        api[name] = function (message) {
          if (intercept(message)) return;
          return original.apply(this, arguments);
        };
        hooked = true;
      });
      if (!hooked) {
        var proto = InspectorBackend.Connection && InspectorBackend.Connection.prototype;
        if (!proto || typeof proto.dispatch !== "function") return "no dispatch hook";
        var originalDispatch = proto.dispatch;
        proto.dispatch = function (message) {
          var object = message;
          try { if (typeof message === "string") object = JSON.parse(message); } catch (e) {}
          try { if (inspect(object)) return; } catch (e) {}
          return originalDispatch.call(this, message);
        };
      }
      var stats = { sent: 0, responses: 0, events: 0, lastSent: null, lastResponseId: null, sendErrors: [] };
      var originalInspect = inspect;
      inspect = function (inner) {
        if (inner && typeof inner.id === "number" && inner.id >= BASE) { stats.responses++; stats.lastResponseId = inner.id; }
        else if (inner && inner.method) stats.events++;
        return originalInspect(inner);
      };
      window.__sbProtocol = {
        stats: stats,
        send: function (command) {
          var id = next++;
          var connection = WI.mainTarget && WI.mainTarget.connection;
          if (!connection) return -1;
          stats.sent++; stats.lastSent = id + " " + command.method;
          try { connection.sendMessageToBackend(JSON.stringify({ id: id, method: command.method, params: command.params || {} })); }
          catch (e) { stats.sendErrors.push(String(e)); }
          return id;
        }
      };
      return "installed";
    })()
    """
}
