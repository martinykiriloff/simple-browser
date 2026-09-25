import Foundation

/// Human-readable renderings of events for list rows and detail panes.
/// Pure functions of the model, so the UI layer stays thin.
public enum InspectorEventFormatter {

    /// One-line description for a table row.
    public static func summary(_ event: InspectorEvent) -> String {
        switch event {
        case .console(let e):
            return e.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""

        case .network(let e):
            var parts: [String] = []
            if let method = e.method { parts.append(method) }
            if let status = e.statusCode { parts.append(String(status)) }
            else if e.failure != nil { parts.append("failed") }
            parts.append(e.url.absoluteString)
            if let duration = e.duration { parts.append("(\(milliseconds(duration)))") }
            if let bytes = e.bytesReceived { parts.append(byteCount(bytes)) }
            return parts.joined(separator: " ")

        case .dom(let e):
            var counts: [DOMMutation.Kind: Int] = [:]
            for m in e.mutations { counts[m.kind, default: 0] += 1 }
            var parts = [DOMMutation.Kind.childList, .attributes, .characterData]
                .compactMap { kind in counts[kind].map { "\($0) \(kind.rawValue)" } }
            if e.dropped > 0 { parts.append("\(e.dropped) dropped") }
            let targets = Set(e.mutations.prefix(20).map(\.target)).sorted().prefix(3)
            let where_ = targets.isEmpty ? "" : "  on " + targets.joined(separator: ", ")
            return "\(e.total) mutation\(e.total == 1 ? "" : "s"): " + parts.joined(separator: ", ") + where_

        case .performance(let e):
            switch e.entryType {
            case "layout-shift":
                return "layout shift \(String(format: "%.4f", e.value ?? 0))" + (e.detail.map { " (\($0))" } ?? "")
            case "largest-contentful-paint":
                return "LCP at \(milliseconds(e.startTime / 1000))" + (e.detail.map { " \($0)" } ?? "")
            case "paint":
                return "\(e.name) at \(milliseconds(e.startTime / 1000))"
            case "longtask":
                return "long task \(milliseconds(e.duration / 1000)) at \(milliseconds(e.startTime / 1000))"
            case "first-input":
                return "first input (\(e.name)) \(milliseconds(e.duration / 1000)) at \(milliseconds(e.startTime / 1000))"
            case "event":
                return "slow \(e.name) event \(milliseconds(e.duration / 1000))"
            default:
                return "\(e.entryType) \(e.name) \(milliseconds(e.duration / 1000))"
            }

        case .navigation(let e):
            let phase: String
            switch e.phase {
            case .started:    phase = "→ started"
            case .redirected: phase = "↪ redirected"
            case .committed:  phase = "✓ committed"
            case .finished:   phase = "✓ finished"
            case .failed:     phase = "✗ failed"
            case .agentReady: phase = "· agent ready"
            }
            return "\(phase)  \(e.url.absoluteString)" + (e.detail.map { "  (\($0))" } ?? "")
        }
    }

    /// Multi-line description for a detail pane.
    public static func detail(_ recorded: RecordedEvent) -> String {
        var lines: [String] = []
        lines.append("Recorded  \(timestamp(recorded.recordedAt))   #\(recorded.sequence)")

        switch recorded.event {
        case .console(let e):
            lines.append("Level     \(e.level.rawValue)" + (e.isUncaught ? "  (uncaught)" : ""))
            lines.append("")
            lines.append(e.message)
            if !e.stack.isEmpty {
                lines.append("")
                lines.append("Stack")
                for frame in e.stack { lines.append("  " + describe(frame)) }
            }

        case .network(let e):
            lines.append("Source    \(sourceLabel(e.source))")
            var request = e.method ?? "(method unknown)"
            request += "  " + e.url.absoluteString
            lines.append("")
            lines.append(request)
            if let initiator = e.initiator { lines.append("Initiator \(initiator)") }
            if let status = e.statusCode { lines.append("Status    \(status)") }
            if let failure = e.failure { lines.append("Failure   \(failure)") }
            if let duration = e.duration { lines.append("Duration  \(milliseconds(duration))") }
            if let bytes = e.bytesReceived { lines.append("Size      \(byteCount(bytes))") }
            if let proto = e.protocolName { lines.append("Protocol  \(proto)") }
            lines.append("Started   \(timestamp(e.startedAt))")
            if !e.requestHeaders.isEmpty {
                lines.append("")
                lines.append("Request headers")
                for (k, v) in e.requestHeaders.sorted(by: { $0.key < $1.key }) { lines.append("  \(k): \(v)") }
            }
            if let body = e.requestBody {
                lines.append("")
                lines.append("Request body")
                lines.append(body)
            }
            if !e.responseHeaders.isEmpty {
                lines.append("")
                lines.append("Response headers")
                for (k, v) in e.responseHeaders.sorted(by: { $0.key < $1.key }) { lines.append("  \(k): \(v)") }
            }
            lines.append("")
            if let body = e.responseBody {
                lines.append("Response body")
                lines.append(prettyJSONIfPossible(body))
            } else if e.source == .agent {
                lines.append("Response body not observable from resource timing. Open Web Inspector (⌥⌘I) or use the page-world hook event for the same URL.")
            } else {
                lines.append("Response body unavailable (binary, streaming, or not observable).")
            }

        case .dom(let e):
            lines.append("Mutations \(e.total)" + (e.dropped > 0 ? "  (\(e.dropped) dropped from this batch)" : ""))
            lines.append("")
            for m in e.mutations.prefix(200) {
                var line = "  \(m.kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(m.target)"
                if let attribute = m.attribute { line += "  [\(attribute)]" }
                if m.addedNodes > 0 || m.removedNodes > 0 { line += "  +\(m.addedNodes) −\(m.removedNodes)" }
                lines.append(line)
            }

        case .performance(let e):
            lines.append("Type      \(e.entryType)")
            lines.append("Name      \(e.name)")
            lines.append("Start     \(milliseconds(e.startTime / 1000)) after time origin")
            lines.append("Duration  \(milliseconds(e.duration / 1000))")
            if let value = e.value { lines.append("Value     \(value)") }
            if let detail = e.detail { lines.append("Detail    \(detail)") }

        case .navigation(let e):
            lines.append("Phase     \(e.phase.rawValue)")
            lines.append("URL       \(e.url.absoluteString)")
            if let detail = e.detail { lines.append("Detail    \(detail)") }
        }
        return lines.joined(separator: "\n")
    }

    public static func sourceLabel(_ source: EventSource) -> String {
        switch source {
        case .agent:              return "agent (isolated world, tamper-proof)"
        case .pageWorld:          return "page world hook (page script could tamper)"
        case .proxy:              return "proxy"
        case .navigationDelegate: return "navigation delegate"
        case .loader:             return "instrumented loader"
        case .user:               return "console input"
        case .inspector:          return "WebKit inspector protocol"
        }
    }

    public static func shortSourceLabel(_ source: EventSource) -> String {
        switch source {
        case .agent:              return "agent"
        case .pageWorld:          return "page"
        case .proxy:              return "proxy"
        case .navigationDelegate: return "nav"
        case .loader:             return "loader"
        case .user:               return "you"
        case .inspector:          return "webkit"
        }
    }

    /// The source that produced an event, for rows that need a label.
    public static func source(of event: InspectorEvent) -> EventSource? {
        switch event {
        case .network(let e): return e.source
        default:              return nil
        }
    }

    // MARK: - Pieces

    public static func describe(_ frame: StackFrame) -> String {
        var s = frame.functionName ?? "(anonymous)"
        if let url = frame.url {
            s += " @ \(url.absoluteString)"
            if frame.line > 0 { s += ":\(frame.line):\(frame.column)" }
        }
        return s
    }

    public static func milliseconds(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms >= 1000 { return String(format: "%.2f s", seconds) }
        if ms >= 10 { return String(format: "%.0f ms", ms) }
        return String(format: "%.1f ms", ms)
    }

    public static func byteCount(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func timestamp(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func prettyJSONIfPossible(_ text: String) -> String {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
              text.utf8.count < 512 * 1024,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }
}
