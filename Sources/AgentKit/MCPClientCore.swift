import Foundation

// The client side of the agent server, for the `keel` command-line tool:
// line framing for the stdio launcher, the session bookkeeping of
// Streamable HTTP, and replay plans. No networking here, so all of it is
// checkable in AgentKitChecks; the CLI does the I/O.

/// Splits a byte stream into newline-delimited messages (the MCP stdio
/// transport). Handles chunks that end mid-line, CRLF, and blank lines.
public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends a chunk and returns the complete lines in it, without their newline.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == 0x0D { line = line.dropLast() }
            if !Self.isBlank(line) { lines.append(Data(line)) }
        }
        return lines
    }

    /// What is left at end of input: a last line without a newline, if any.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        var rest = buffer
        if rest.last == 0x0D { rest = rest.dropLast() }
        return Self.isBlank(rest) ? nil : Data(rest)
    }

    /// One message as one line: JSON never needs a raw newline, so encoding
    /// without pretty-printing is always a single line.
    public static func frame(_ message: JSONValue) -> Data {
        message.encoded() + Data([0x0A])
    }

    static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }
}

/// What a JSON-RPC message (or batch) is, as far as the transport cares.
public enum MCPMessage {
    /// The requests in a message or batch: those with a method and an id.
    public static func requestIDs(_ message: JSONValue) -> [JSONValue] {
        let items = message.array ?? [message]
        return items.compactMap { item in
            guard item["method"]?.string != nil, let id = item["id"], !id.isNull else { return nil }
            return id
        }
    }

    /// The `initialize` request in a message or batch, if there is one.
    public static func initialize(in message: JSONValue) -> JSONValue? {
        (message.array ?? [message]).first { $0["method"]?.string == "initialize" }
    }

    public static func isInitialize(_ message: JSONValue) -> Bool { initialize(in: message) != nil }

    /// An error reply for every request in a message: one object, a batch,
    /// or nil when the message held only notifications.
    public static func errorReplies(for message: JSONValue, code: Int, message text: String) -> JSONValue? {
        let replies: [JSONValue] = requestIDs(message).map {
            ["jsonrpc": "2.0", "id": $0, "error": ["code": .number(Double(code)), "message": .string(text)]]
        }
        if replies.isEmpty { return nil }
        if message.array != nil { return .array(replies) }
        return replies[0]
    }

    public static func request(id: JSONValue, method: String, params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    }

    public static func notification(_ method: String, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }
}

/// The session state of one Streamable HTTP connection to the agent
/// server, and what to do with each answer it gives.
public struct MCPHTTPClientCore: Sendable {
    /// JSON-RPC error codes the launcher answers with when the server cannot.
    public enum ErrorCode {
        public static let serverUnavailable = -32002
        public static let unauthorized = -32003
        public static let sessionNotFound = -32001
    }

    public var token: String?
    /// Set by the server in its answer to `initialize`.
    public private(set) var sessionID: String?
    /// The client's own `initialize` params, kept to start over transparently.
    public private(set) var initializeParams: JSONValue?
    /// Bumped each time a new session starts, so concurrent callers that saw
    /// the same loss start over only once.
    public private(set) var generation = 0

    public init(token: String? = nil) { self.token = token }

    /// The headers for a POST carrying `message`.
    public func headers(for message: JSONValue) -> [(String, String)] {
        var headers = [("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")]
        if let token, !token.isEmpty { headers.append(("Authorization", "Bearer \(token)")) }
        // An initialize starts a new session; anything else rides the current one.
        if let sessionID, !MCPMessage.isInitialize(message) { headers.append(("Mcp-Session-Id", sessionID)) }
        return headers
    }

    /// Notes what the client sends, before it goes out.
    public mutating func willSend(_ message: JSONValue) {
        if let initialize = MCPMessage.initialize(in: message) {
            initializeParams = initialize["params"] ?? [:]
        }
    }

    public enum Action: Sendable, Equatable {
        /// Hand this body to the client.
        case reply(Data)
        /// 202: a notification was accepted; say nothing.
        case nothing
        /// 404 with -32001: the server forgot the session; initialize again and resend.
        case sessionLost
        /// 401: no token, or one that was revoked; pair and resend.
        case unauthorized(String)
        /// Anything else the server refused, with its explanation.
        case failed(status: Int, message: String)
    }

    /// Reads an HTTP answer to `message`. `headers` keys may be any case.
    public mutating func handle(status: Int, headers: [String: String], body: Data, for message: JSONValue) -> Action {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        if let id = lowered["mcp-session-id"], !id.isEmpty, (200..<300).contains(status), id != sessionID {
            sessionID = id
            generation += 1
        }
        switch status {
        case 202: return .nothing
        case 200..<300: return body.isEmpty ? .nothing : .reply(body)
        case 404:
            if let reply = try? JSONValue.decode(body), reply["error"]?["code"]?.int == ErrorCode.sessionNotFound {
                sessionID = nil
                return .sessionLost
            }
            return .failed(status: 404, message: Self.explanation(body) ?? "Not found")
        case 401:
            return .unauthorized(Self.explanation(body) ?? "The token was refused")
        default:
            return .failed(status: status, message: Self.explanation(body) ?? "HTTP \(status)")
        }
    }

    /// Forgets the session, as after a DELETE.
    public mutating func endSession() { sessionID = nil }

    /// The initialize to send again after a session was lost, with the
    /// client's original params and an id the client never uses.
    public func reinitializeRequest() -> JSONValue? {
        guard let initializeParams else { return nil }
        return MCPMessage.request(id: .string("keel-reinit-\(generation + 1)"), method: "initialize", params: initializeParams)
    }

    /// The server's explanation in an error body: `{"error": "…"}` or a JSON-RPC error.
    public static func explanation(_ body: Data) -> String? {
        guard let value = try? JSONValue.decode(body) else {
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return value["error"]?.string ?? value["error"]?["message"]?.string
    }
}

/// One call in a replay export (`AuditLog.replay`).
public struct ReplayStep: Sendable, Equatable {
    public var tool: String
    public var arguments: JSONValue
    public var summary: String
    public var url: String?

    public init(tool: String, arguments: JSONValue = [:], summary: String = "", url: String? = nil) {
        self.tool = tool; self.arguments = arguments; self.summary = summary; self.url = url
    }
}

/// What `keel replay` will call, in order.
public struct ReplayPlan: Sendable, Equatable {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case notAReplay
        case unsupportedVersion(Int)
        case badStep(Int)

        public var description: String {
            switch self {
            case .notJSON: return "The file is not JSON."
            case .notAReplay: return "The file is not a Keel replay (no \"keelReplay\" key). Export one from the Agent panel."
            case .unsupportedVersion(let version): return "This replay is version \(version); this keel reads version 1."
            case .badStep(let index): return "Step \(index + 1) has no tool."
            }
        }
    }

    /// Tools that bring the tab to a page, so the plan needs no tab of its own first.
    public static let navigationTools: Set<String> = ["navigate", "new_tab"]

    public var steps: [ReplayStep]
    /// The session it was recorded in, for the header line.
    public var session: String?
    public var client: String?
    public var recorded: String?

    public init(steps: [ReplayStep], session: String? = nil, client: String? = nil, recorded: String? = nil) {
        self.steps = steps; self.session = session; self.client = client; self.recorded = recorded
    }

    public static func parse(_ data: Data) throws(ParseError) -> ReplayPlan {
        guard let value = try? JSONValue.decode(data) else { throw .notJSON }
        guard let version = value["keelReplay"]?.int else { throw .notAReplay }
        guard version == 1 else { throw .unsupportedVersion(version) }
        var steps: [ReplayStep] = []
        for (index, item) in (value["steps"]?.array ?? []).enumerated() {
            guard let tool = item["tool"]?.string, !tool.isEmpty else { throw .badStep(index) }
            var arguments = item["arguments"]?.object ?? [:]
            arguments["tabId"] = nil
            steps.append(ReplayStep(tool: tool, arguments: .object(arguments), summary: item["summary"]?.string ?? "",
                                    url: item["url"]?.string.flatMap { $0.isEmpty ? nil : $0 }))
        }
        func text(_ key: String) -> String? { value[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        return ReplayPlan(steps: steps, session: text("session"), client: text("client"), recorded: text("recorded"))
    }

    /// The calls to make: the steps, preceded by a `new_tab` at the first
    /// step's page when the first step does not open one itself. Replay
    /// acts in a tab of its own, never one the person was using.
    public var calls: [ReplayStep] {
        guard let first = steps.first else { return [] }
        if Self.navigationTools.contains(first.tool) { return steps }
        let arguments: JSONValue = first.url.map { ["url": .string($0)] } ?? [:]
        let opening = ReplayStep(tool: "new_tab", arguments: arguments,
                                 summary: "Opened a tab" + (first.url.map { " at \($0)" } ?? ""), url: first.url)
        return [opening] + steps
    }
}

/// Reading a `tools/call` reply for a person at a terminal.
public enum MCPToolOutcome {
    /// Whether the call succeeded, and the first line of what it said.
    public static func summarize(_ reply: JSONValue) -> (ok: Bool, line: String) {
        if let error = reply["error"] {
            return (false, error["message"]?.string ?? "JSON-RPC error")
        }
        let result = reply["result"] ?? [:]
        let failed = result["isError"]?.bool ?? false
        let text = result["content"]?.array?.first { $0["type"]?.string == "text" }?["text"]?.string ?? ""
        // Page content arrives wrapped in <untrusted-page-content> tags; the
        // first line worth showing is the first one inside.
        let line = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !($0.hasPrefix("<untrusted") || $0.hasPrefix("</untrusted")) }
            ?? (failed ? "Failed" : "Done")
        return (!failed, line)
    }

    /// The text parts of a `tools/call` reply, joined.
    public static func text(_ reply: JSONValue) -> String {
        (reply["result"]?["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
            .joined(separator: "\n")
    }

    /// The cursor `session_events` reports, for the next poll.
    public static func lastEventID(_ reply: JSONValue) -> Int? {
        reply["result"]?["structuredContent"]?["lastEventId"]?.int
    }
}
