import Foundation

/// Who caused something on a page: the page itself, the person, or an agent.
/// Console and network entries carry it (actor tags), and so does the log.
public enum Actor: String, Codable, Sendable, CaseIterable {
    case page, human, agent
}

/// One line of a session's append-only audit log.
public struct AuditEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case ok, error, denied, approved, blocked, waiting
    }

    /// Increasing, starting at 1, per log: the cursor of `afterId`.
    public var id: Int
    public var time: Date
    public var sessionID: String
    public var clientName: String
    public var tool: String
    /// The arguments as sent, with typed text kept: the log is the person's own record.
    public var arguments: JSONValue
    public var url: String?
    public var outcome: Outcome
    public var errorCode: String?
    /// A short human sentence: "Typed into Email", "Waiting for approval".
    public var summary: String
    public var milliseconds: Int
    /// Estimated tokens of the result the agent received.
    public var resultTokens: Int
    /// A screenshot taken for the record, as a file name in the log folder.
    public var screenshot: String?

    public init(id: Int, time: Date, sessionID: String, clientName: String, tool: String, arguments: JSONValue, url: String?,
                outcome: Outcome, errorCode: String? = nil, summary: String, milliseconds: Int, resultTokens: Int, screenshot: String? = nil) {
        self.id = id; self.time = time; self.sessionID = sessionID; self.clientName = clientName; self.tool = tool
        self.arguments = arguments; self.url = url; self.outcome = outcome; self.errorCode = errorCode; self.summary = summary
        self.milliseconds = milliseconds; self.resultTokens = resultTokens; self.screenshot = screenshot
    }
}

/// A session's log. Entries are only ever appended; nothing edits or
/// removes one, so the export is what happened.
public struct AuditLog: Sendable, Equatable {
    public private(set) var entries: [AuditEntry] = []

    public init(entries: [AuditEntry] = []) { self.entries = entries }

    public var lastID: Int { entries.last?.id ?? 0 }

    @discardableResult
    public mutating func append(time: Date = Date(), sessionID: String, clientName: String, tool: String, arguments: JSONValue,
                                url: String?, outcome: AuditEntry.Outcome, errorCode: String? = nil, summary: String,
                                milliseconds: Int = 0, resultTokens: Int = 0, screenshot: String? = nil) -> AuditEntry {
        let entry = AuditEntry(id: lastID + 1, time: time, sessionID: sessionID, clientName: clientName, tool: tool,
                               arguments: arguments, url: url, outcome: outcome, errorCode: errorCode, summary: summary,
                               milliseconds: milliseconds, resultTokens: resultTokens, screenshot: screenshot)
        entries.append(entry)
        return entry
    }

    /// Entries after a cursor (AR-8: poll with the last id you saw).
    public func after(_ id: Int, limit: Int = 100) -> [AuditEntry] {
        Array(entries.lazy.filter { $0.id > id }.prefix(limit))
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The whole log as JSON, for Export.
    public func exportJSON() -> Data {
        (try? Self.encoder.encode(entries)) ?? Data("[]".utf8)
    }

    /// One entry per line, for the log file that survives a crash.
    public static func jsonLine(_ entry: AuditEntry) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(entry)) ?? Data()) + Data("\n".utf8)
    }

    public static func parseLines(_ data: Data) -> [AuditEntry] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? decoder.decode(AuditEntry.self, from: Data($0.utf8))
        }
    }

    /// A replay (AR-10): the calls that acted, in order, that `keel replay`
    /// sends again. Calls that were refused or denied are left out, and so are
    /// reads, which change nothing.
    public func replay(readOnlyTools: Set<String>) -> JSONValue {
        let steps = entries.filter { ($0.outcome == .ok || $0.outcome == .approved) && !readOnlyTools.contains($0.tool) }
        return [
            "keelReplay": 1,
            "session": .string(entries.first?.sessionID ?? ""),
            "client": .string(entries.first?.clientName ?? ""),
            "recorded": .string(entries.first.map { ISO8601DateFormatter().string(from: $0.time) } ?? ""),
            "steps": .array(steps.map { entry in
                var arguments = entry.arguments.object ?? [:]
                arguments["tabId"] = nil   // tab ids do not survive; replay acts on its own tab
                return ["tool": .string(entry.tool), "arguments": .object(arguments), "summary": .string(entry.summary),
                        "url": entry.url.map(JSONValue.string) ?? .null]
            }),
        ]
    }
}

/// Short sentences for the timeline: "Typed into Email", "Clicked e14".
public enum AuditSummary {
    public static func describe(tool: String, arguments a: JSONValue) -> String {
        let target = a["element"]?.string ?? a["text"]?.string ?? a["ref"]?.string ?? a["selector"]?.string
        func on(_ verb: String) -> String { target.map { "\(verb) \($0)" } ?? verb }
        switch tool {
        case "snapshot": return "Read page snapshot"
        case "get_page_content": return "Read page content"
        case "screenshot": return "Took a screenshot"
        case "navigate":
            let action = a["action"]?.string ?? "goto"
            return action == "goto" ? "Opened \(a["url"]?.string ?? "a page")" : action.capitalized
        case "new_tab": return "Opened a tab" + (a["url"]?.string.map { " at \($0)" } ?? "")
        case "close_tab": return "Closed a tab"
        case "click": return on("Clicked")
        case "hover": return on("Hovered")
        case "fill", "type_text": return target.map { "Typed into \($0)" } ?? "Typed text"
        case "fill_form": return "Filled a form"
        case "press_key": return "Pressed \(a["key"]?.string ?? "a key")"
        case "select_option": return on("Chose an option in")
        case "upload_files": return on("Uploaded files to")
        case "evaluate": return "Ran JavaScript"
        case "request_human": return "Asked you to take over"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
