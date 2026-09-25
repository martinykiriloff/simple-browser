import Foundation

/// Turns one raw bridge payload -- the `body` of a script message, already
/// bridged to Foundation types -- into typed events.
///
/// The `source` is supplied by the caller from the *handler* the message
/// arrived on, never trusted from the payload: page script can post anything
/// it likes to the page-world handler, but it cannot reach the isolated one.
public enum InspectorMessageDecoder {

    public static func decode(_ body: Any, source: EventSource) -> [InspectorEvent] {
        guard let dict = body as? [String: Any],
              let kind = dict["kind"] as? String else { return [] }
        let timestamp = date(dict["t"]) ?? .now

        switch kind {
        case "console":
            return [.console(console(dict, timestamp: timestamp))]
        case "network":
            return network(dict, source: source, timestamp: timestamp).map { [.network($0)] } ?? []
        case "dom":
            return [.dom(dom(dict, timestamp: timestamp))]
        case "performance":
            return [.performance(performance(dict))]
        case "navigation":
            return navigation(dict, timestamp: timestamp).map { [.navigation($0)] } ?? []
        default:
            return []
        }
    }

    // MARK: - Per-kind

    private static func console(_ dict: [String: Any], timestamp: Date) -> ConsoleEntry {
        let level = (dict["level"] as? String).flatMap(ConsoleEntry.Level.init(rawValue:)) ?? .info
        var stack = (dict["stack"] as? [Any])?.compactMap { $0 as? String }.compactMap(parseFrame) ?? []
        // Uncaught errors from the isolated world carry a single location
        // rather than a stack.
        if stack.isEmpty, let line = int(dict["line"]) {
            stack = [StackFrame(url: (dict["url"] as? String).flatMap(URL.init(string:)),
                                line: line, column: int(dict["column"]) ?? 0)]
        }
        var args: [RemoteObject] = []
        if let raw = dict["args"] as? [Any], JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([RemoteObject].self, from: data) {
            args = decoded
        }
        var table: ConsoleTable?
        if let raw = dict["table"] as? [String: Any],
           let columns = raw["columns"] as? [String],
           let rows = raw["rows"] as? [[Any]] {
            table = ConsoleTable(
                columns: columns,
                rows: rows.map { $0.map { $0 as? String ?? "\($0)" } },
                truncatedRows: int(raw["truncated"]) ?? 0
            )
        }
        return ConsoleEntry(
            level: level,
            type: dict["type"] as? String ?? "log",
            message: dict["message"] as? String ?? "",
            args: args,
            stack: stack,
            timestamp: timestamp,
            isUncaught: dict["uncaught"] as? Bool ?? false,
            table: table
        )
    }

    private static func network(_ dict: [String: Any], source: EventSource, timestamp: Date) -> NetworkEvent? {
        guard let raw = dict["url"] as? String, let url = URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            return nil
        }
        let bytes = int64(dict["bytes"]) ?? int64(dict["transferSize"]) ?? int64(dict["encodedBodySize"])
        var timing: NetworkTiming?
        if let t = dict["timing"] as? [String: Any] {
            timing = NetworkTiming(
                fetchStart: double(t["fetchStart"]) ?? 0,
                domainLookupStart: double(t["domainLookupStart"]) ?? 0,
                domainLookupEnd: double(t["domainLookupEnd"]) ?? 0,
                connectStart: double(t["connectStart"]) ?? 0,
                secureConnectionStart: double(t["secureConnectionStart"]) ?? 0,
                connectEnd: double(t["connectEnd"]) ?? 0,
                requestStart: double(t["requestStart"]) ?? 0,
                responseStart: double(t["responseStart"]) ?? 0,
                responseEnd: double(t["responseEnd"]) ?? 0
            )
        }
        return NetworkEvent(
            source: source,
            method: dict["method"] as? String,
            url: url,
            initiator: dict["initiator"] as? String,
            statusCode: int(dict["status"]),
            requestHeaders: headers(dict["requestHeaders"]),
            responseHeaders: headers(dict["responseHeaders"]),
            requestBody: dict["requestBody"] as? String,
            responseBody: dict["responseBody"] as? String,
            bodyUnavailable: dict["bodyUnavailable"] as? Bool ?? (dict["responseBody"] == nil),
            failure: dict["failure"] as? String,
            startedAt: date(dict["startedAt"]) ?? timestamp,
            duration: double(dict["duration"]).map { $0 / 1000 },
            bytesReceived: bytes,
            decodedBodySize: int64(dict["decodedBodySize"]),
            protocolName: dict["protocol"] as? String,
            timing: timing
        )
    }

    private static func dom(_ dict: [String: Any], timestamp: Date) -> DOMMutationBatch {
        let mutations = (dict["mutations"] as? [Any])?.compactMap { item -> DOMMutation? in
            guard let m = item as? [String: Any],
                  let kind = (m["kind"] as? String).flatMap(DOMMutation.Kind.init(rawValue:)) else { return nil }
            return DOMMutation(
                nodeID: int(m["nodeID"]) ?? 0,
                kind: kind,
                target: m["target"] as? String ?? "",
                attribute: m["attribute"] as? String,
                addedNodes: int(m["added"]) ?? 0,
                removedNodes: int(m["removed"]) ?? 0
            )
        } ?? []
        return DOMMutationBatch(mutations: mutations, dropped: int(dict["dropped"]) ?? 0, timestamp: timestamp)
    }

    private static func performance(_ dict: [String: Any]) -> PerformanceEntry {
        var detail: [String] = []
        if let size = int(dict["size"]) { detail.append("size \(size)") }
        if let url = dict["url"] as? String, !url.isEmpty { detail.append(url) }
        if dict["hadRecentInput"] as? Bool == true { detail.append("had recent input") }
        return PerformanceEntry(
            name: dict["name"] as? String ?? "",
            entryType: dict["entryType"] as? String ?? "",
            startTime: double(dict["startTime"]) ?? 0,
            duration: double(dict["duration"]) ?? 0,
            value: double(dict["value"]),
            detail: detail.isEmpty ? nil : detail.joined(separator: " · ")
        )
    }

    private static func navigation(_ dict: [String: Any], timestamp: Date) -> NavigationEvent? {
        guard let raw = dict["url"] as? String, let url = URL(string: raw),
              let phase = (dict["phase"] as? String).flatMap(NavigationEvent.Phase.init(rawValue:)) else { return nil }
        return NavigationEvent(url: url, phase: phase, timestamp: timestamp)
    }

    // MARK: - Stack frames

    /// JavaScriptCore stack lines look like `name@https://host/a.js:12:34`,
    /// `global code@…`, or `@https://…` for anonymous frames.
    static func parseFrame(_ line: String) -> StackFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // V8-style "    at fn (url:line:col)" is not produced by JSC, but a
        // page may have re-thrown one; keep it as an opaque frame.
        guard let at = trimmed.firstIndex(of: "@") else {
            return StackFrame(functionName: trimmed, line: 0, column: 0)
        }
        let name = String(trimmed[..<at])
        let location = String(trimmed[trimmed.index(after: at)...])
        let parts = location.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let column = Int(parts[parts.count - 1]),
              let lineNumber = Int(parts[parts.count - 2]) else {
            return StackFrame(functionName: name.isEmpty ? nil : name,
                              url: URL(string: location), line: 0, column: 0)
        }
        let urlString = parts[..<(parts.count - 2)].joined(separator: ":")
        return StackFrame(functionName: name.isEmpty ? nil : name,
                          url: URL(string: urlString), line: lineNumber, column: column)
    }

    // MARK: - Scalars

    private static func headers(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict { out[k] = v as? String ?? "\(v)" }
        return out
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n.isFinite ? n : nil
        case let n as Int:    return Double(n)
        case let s as String: return Double(s)
        default:              return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int:    return n
        case let n as Double: return n.isFinite ? Int(n) : nil
        case let s as String: return Int(s)
        default:              return nil
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        int(value).map(Int64.init)
    }

    /// Milliseconds since the epoch, as `Date.now()` produces.
    private static func date(_ value: Any?) -> Date? {
        double(value).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
