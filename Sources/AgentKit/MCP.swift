import Foundation

/// A tool as `tools/list` describes it.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// Reads only: no navigation, no input, no change to the page.
    public var readOnly: Bool
    /// May lose something the person had (closing a tab, clearing storage).
    public var destructive: Bool
    /// Extra annotations (WebMCP's consequential and untrusted-content hints).
    public var extraAnnotations: [String: JSONValue]

    public init(name: String, title: String, description: String, inputSchema: JSONValue,
                readOnly: Bool = false, destructive: Bool = false, extraAnnotations: [String: JSONValue] = [:]) {
        self.name = name; self.title = title; self.description = description
        self.inputSchema = inputSchema; self.readOnly = readOnly; self.destructive = destructive
        self.extraAnnotations = extraAnnotations
    }

    public var listing: JSONValue {
        let annotations: [String: JSONValue] = [
            "title": .string(title),
            "readOnlyHint": .bool(readOnly),
            "destructiveHint": .bool(destructive),
            "openWorldHint": true,
        ].merging(extraAnnotations) { _, extra in extra }
        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object(annotations),
        ]
    }
}

/// What a tool call produces: text for the model, and images where a
/// picture says it better.
public struct MCPToolResult: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        case image(base64: String, mimeType: String)
    }

    public var content: [Content]
    public var isError: Bool
    /// Machine-readable outcome (AR-5): `ok`, `navigated`, `changedRefs`,
    /// `error: {code, message, retryable}`. Sent as `structuredContent`.
    public var structured: JSONValue?

    public init(_ content: [Content], isError: Bool = false, structured: JSONValue? = nil) {
        self.content = content; self.isError = isError; self.structured = structured
    }

    /// The text parts joined, for logs and token counts.
    public var text: String {
        content.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n")
    }

    public static func text(_ text: String) -> MCPToolResult { MCPToolResult([.text(text)]) }
    public static func error(_ text: String) -> MCPToolResult { MCPToolResult([.text(text)], isError: true) }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "content": .array(content.map {
                switch $0 {
                case .text(let text): return ["type": "text", "text": .string(text)]
                case .image(let data, let mime): return ["type": "image", "data": .string(data), "mimeType": .string(mime)]
                }
            }),
            "isError": .bool(isError),
        ]
        if let structured { object["structuredContent"] = structured }
        return .object(object)
    }
}

/// A prompt template: clients such as Claude Code offer these as slash
/// commands (`/mcp__keel__debug_page`).
public struct MCPPrompt: Sendable {
    public struct Argument: Sendable {
        public var name: String
        public var description: String
        public var required: Bool
        public init(_ name: String, _ description: String, required: Bool = false) {
            self.name = name; self.description = description; self.required = required
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]
    /// The text sent as the user's message; `{name}` is replaced by the argument.
    public var template: String

    public init(name: String, title: String, description: String, arguments: [Argument] = [], template: String) {
        self.name = name; self.title = title; self.description = description; self.arguments = arguments; self.template = template
    }

    var listing: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] })]
    }

    /// The template with arguments filled in; missing optional ones read as "the current page".
    public func render(_ values: [String: String]) -> String {
        var text = template
        for argument in arguments {
            let value = values[argument.name].flatMap { $0.isEmpty ? nil : $0 } ?? "(not given: use the current tab)"
            text = text.replacingOccurrences(of: "{\(argument.name)}", with: value)
        }
        return text
    }
}

/// The client that introduced itself in `initialize`.
public struct MCPClientInfo: Sendable, Equatable {
    public var name: String
    public var version: String?
    public var protocolVersion: String
}

/// MCP over JSON-RPC 2.0, transport-agnostic: one message in, at most one
/// message out. The Streamable HTTP transport around it lives in the app.
public struct MCPDispatcher: Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// The version of the tool contract (AR-11). Minor versions only add
    /// tools or optional arguments; a removal or rename is a major version.
    public static let toolSchemaVersion = "1.1.0"

    public var serverName: String
    public var serverVersion: String
    public var instructions: String
    public var tools: [MCPTool]
    public var prompts: [MCPPrompt]

    public init(serverName: String, serverVersion: String, instructions: String, tools: [MCPTool], prompts: [MCPPrompt] = []) {
        self.serverName = serverName; self.serverVersion = serverVersion
        self.instructions = instructions; self.tools = tools; self.prompts = prompts
    }

    public enum Outcome: Sendable, Equatable {
        /// A response to send back (HTTP 200).
        case reply(JSONValue)
        /// A notification or response from the client: nothing to answer (HTTP 202).
        case accepted
    }

    public typealias ToolCall = @Sendable (_ name: String, _ arguments: JSONValue) async -> MCPToolResult

    /// Handles one message (or a batch, which older clients may still send).
    /// `onInitialize` hears who connected.
    public func handle(_ data: Data, onInitialize: (@Sendable (MCPClientInfo) async -> Void)? = nil,
                       call: ToolCall) async -> Outcome {
        guard let message = try? JSONValue.decode(data) else {
            return .reply(Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for item in batch {
                if case .reply(let reply) = await handle(item, onInitialize: onInitialize, call: call) { replies.append(reply) }
            }
            return replies.isEmpty ? .accepted : .reply(.array(replies))
        }
        return await handle(message, onInitialize: onInitialize, call: call)
    }

    func handle(_ message: JSONValue, onInitialize: (@Sendable (MCPClientInfo) async -> Void)?, call: ToolCall) async -> Outcome {
        guard case .object = message, message["jsonrpc"]?.string == "2.0" else {
            return .reply(Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request"))
        }
        guard let method = message["method"]?.string else {
            return .accepted   // A response to something we never send; nothing to say.
        }
        guard let id = message["id"], !id.isNull else {
            return .accepted   // notifications/initialized, notifications/cancelled, …
        }
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? Self.supportedVersions[0]
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            let client = MCPClientInfo(name: params["clientInfo"]?["name"]?.string ?? "an MCP client",
                                       version: params["clientInfo"]?["version"]?.string, protocolVersion: version)
            await onInitialize?(client)
            return .reply(Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false], "logging": [:]],
                "serverInfo": ["name": .string(serverName), "title": "Keel", "version": .string(serverVersion)],
                "_meta": ["keel/toolSchemaVersion": .string(Self.toolSchemaVersion)],
                "instructions": .string(instructions),
            ]))
        case "ping":
            return .reply(Self.result(id: id, [:]))
        case "tools/list":
            return .reply(Self.result(id: id, ["tools": .array(tools.map(\.listing)),
                                               "_meta": ["keel/toolSchemaVersion": .string(Self.toolSchemaVersion)]]))
        case "tools/call":
            guard let name = params["name"]?.string else {
                return .reply(Self.error(id: id, code: -32602, message: "tools/call needs a name"))
            }
            guard tools.contains(where: { $0.name == name }) else {
                return .reply(Self.error(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            let arguments = params["arguments"] ?? [:]
            if let problem = Self.validate(arguments, against: tools.first { $0.name == name }!.inputSchema) {
                return .reply(Self.result(id: id, AgentError(.invalidArguments, "Invalid arguments for \(name): \(problem)").result.json))
            }
            let result = await call(name, arguments)
            return .reply(Self.result(id: id, result.json))
        case "resources/list":
            return .reply(Self.result(id: id, ["resources": []]))
        case "resources/templates/list":
            return .reply(Self.result(id: id, ["resourceTemplates": []]))
        case "prompts/list":
            return .reply(Self.result(id: id, ["prompts": .array(prompts.map(\.listing))]))
        case "prompts/get":
            guard let name = params["name"]?.string, let prompt = prompts.first(where: { $0.name == name }) else {
                return .reply(Self.error(id: id, code: -32602, message: "Unknown prompt: \(params["name"]?.string ?? "")"))
            }
            let values = (params["arguments"]?.object ?? [:]).compactMapValues(\.string)
            if let missing = prompt.arguments.first(where: { $0.required && (values[$0.name] ?? "").isEmpty }) {
                return .reply(Self.error(id: id, code: -32602, message: "Prompt \(name) needs \(missing.name)"))
            }
            return .reply(Self.result(id: id, [
                "description": .string(prompt.description),
                "messages": [["role": "user", "content": ["type": "text", "text": .string(prompt.render(values))]]],
            ]))
        case "logging/setLevel":
            return .reply(Self.result(id: id, [:]))
        default:
            return .reply(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    /// The checks that catch a model's usual mistakes: a missing required
    /// argument, a wrong type, a value outside an enum. Not full JSON Schema.
    static func validate(_ arguments: JSONValue, against schema: JSONValue) -> String? {
        guard case .object(let given) = arguments else { return "arguments must be an object" }
        for required in schema["required"]?.array?.compactMap(\.string) ?? [] where given[required] == nil || given[required] == .null {
            return "missing required \"\(required)\""
        }
        let properties = schema["properties"]?.object ?? [:]
        for (key, value) in given where value != .null {
            guard let property = properties[key] else {
                return "unknown argument \"\(key)\"; expected one of \(properties.keys.sorted().joined(separator: ", "))"
            }
            if let type = property["type"]?.string, !matches(value, type: type) {
                return "\"\(key)\" must be \(type == "array" ? "an" : "a") \(type)"
            }
            if let allowed = property["enum"]?.array, !allowed.contains(value) {
                return "\"\(key)\" must be one of \(allowed.compactMap(\.string).joined(separator: ", "))"
            }
        }
        return nil
    }

    static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("number", .number), ("array", .array), ("object", .object): return true
        case ("integer", .number(let number)): return number.rounded() == number
        default: return false
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
