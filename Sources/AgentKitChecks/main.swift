import Foundation
import AgentKit

// Unit checks for AgentKit: `swift run AgentKitChecks`.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
}

func request(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

// MARK: JSON values

do {
    let value = try JSONValue.decode(Data(#"{"a":[1,2.5,true,null,"x"],"b":{"c":false}}"#.utf8))
    check("json: numbers, booleans, null and strings decode apart",
          value["a"] == [1, 2.5, true, nil, "x"] && value["b"]?["c"] == false)
    check("json: integers encode without a fraction", JSONValue.number(3).jsonString == "3" && JSONValue.number(2.5).jsonString == "2.5")
    check("json: keys are sorted, so output is stable", (["b": 1, "a": 2] as JSONValue).jsonString == #"{"a":2,"b":1}"#)
    check("json: Foundation booleans stay booleans", JSONValue(any: NSNumber(value: true)) == .bool(true) && JSONValue(any: NSNumber(value: 1)) == .number(1))
    check("json: Foundation objects bridge", JSONValue(any: ["k": [1, "two"]] as [String: Any]) == ["k": [1, "two"]])
} catch {
    check("json decodes", false, error)
}

// MARK: HTTP

let post = request("POST /mcp?x=1 HTTP/1.1\nHost: 127.0.0.1:9333\nContent-Type: application/json\nContent-Length: 2\n\n{}")
if case .complete(let parsed, let consumed) = HTTPRequestParser.parse(post) {
    check("http: method, path, query", parsed.method == "POST" && parsed.path == "/mcp" && parsed.query == "x=1")
    check("http: headers are case-insensitive", parsed.header("content-type") == "application/json" && parsed.header("Host") == "127.0.0.1:9333")
    check("http: the body is exactly Content-Length", parsed.body == Data("{}".utf8) && consumed == post.count)
} else {
    check("http: a whole request parses", false, HTTPRequestParser.parse(post))
}
check("http: half a body is incomplete", HTTPRequestParser.parse(post.dropLast()) == .incomplete)
check("http: headers without their end are incomplete", HTTPRequestParser.parse(request("POST /mcp HTTP/1.1\nHost: x")) == .incomplete)
check("http: two pipelined requests, the first is taken", {
    let two = post + request("GET / HTTP/1.1\nHost: localhost\n\n")
    if case .complete(_, let consumed) = HTTPRequestParser.parse(two) { return consumed == post.count }
    return false
}())
check("http: chunked bodies are refused", {
    if case .invalid(let status, _) = HTTPRequestParser.parse(request("POST /mcp HTTP/1.1\nTransfer-Encoding: chunked\n\n")) { return status == 411 }
    return false
}())
check("http: garbage is a 400", {
    if case .invalid(let status, _) = HTTPRequestParser.parse(request("hello\n\n")) { return status == 400 }
    return false
}())
check("http: a response has its length and closes", String(decoding: HTTPResponse.text("hi", status: 200).serialized(), as: UTF8.self)
      .hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n"))

// MARK: Access

func access(_ headers: [String: String], token: String? = "secret") -> AgentAccessPolicy.Denial? {
    AgentAccessPolicy(token: token, port: 9333).check(HTTPRequest(method: "POST", path: "/mcp", headers: headers))
}
check("access: the right token on loopback is let in", access(["host": "127.0.0.1:9333", "authorization": "Bearer secret"]) == nil)
check("access: localhost by name is loopback too", access(["host": "localhost:9333", "authorization": "Bearer secret"]) == nil)
check("access: no token is refused", access(["host": "127.0.0.1:9333"]) == .missingToken)
check("access: a wrong token is refused", access(["host": "127.0.0.1:9333", "authorization": "Bearer secreT"]) == .wrongToken)
check("access: a rebound host name is refused", access(["host": "evil.example:9333", "authorization": "Bearer secret"]) == .badHost("evil.example:9333"))
check("access: a web page is refused even with the token", access(["host": "127.0.0.1:9333", "origin": "https://evil.example", "authorization": "Bearer secret"]) == .foreignOrigin("https://evil.example"))
check("access: a local tool with the token is let in", access(["host": "127.0.0.1:9333", "origin": "http://localhost:6274", "authorization": "Bearer secret"]) == nil)
check("access: without a token, any page is refused", access(["host": "127.0.0.1:9333", "origin": "http://localhost:3000"], token: nil) == .foreignOrigin("http://localhost:3000"))
check("access: without a token, a command-line client is let in", access(["host": "127.0.0.1:9333"], token: nil) == nil)
let token = AgentAccessPolicy.makeToken()
check("access: tokens are long and URL-safe", token.count >= 42 && !token.contains("+") && !token.contains("/") && !token.contains("="), token)
check("access: tokens differ", token != AgentAccessPolicy.makeToken())

// MARK: MCP

let dispatcher = MCPDispatcher(serverName: "simplebrowser", serverVersion: "1.0", instructions: "Use snapshot.", tools: BrowserTools.all)
let echo: MCPDispatcher.ToolCall = { name, arguments in .text("\(name) \(arguments.jsonString)") }
func send(_ message: JSONValue) async -> JSONValue? {
    if case .reply(let reply) = await dispatcher.handle(message.encoded(), call: echo) { return reply }
    return nil
}

let initialized = await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2.0"]]])
check("mcp: initialize echoes a supported version", initialized?["result"]?["protocolVersion"] == "2025-03-26", initialized as Any)
check("mcp: initialize offers tools and instructions", initialized?["result"]?["capabilities"]?["tools"] != nil && initialized?["result"]?["instructions"] == "Use snapshot.")
let future = await send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
check("mcp: an unknown version gets our latest", future?["result"]?["protocolVersion"] == .string(MCPDispatcher.supportedVersions[0]))
check("mcp: notifications get no reply", await dispatcher.handle((["jsonrpc": "2.0", "method": "notifications/initialized"] as JSONValue).encoded(), call: echo) == .accepted)
check("mcp: ping", await send(["jsonrpc": "2.0", "id": "p", "method": "ping"])?["result"] == [:])
let listed = await send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
let names = listed?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
check("mcp: every tool is listed", names.count == BrowserTools.all.count && names.contains("snapshot") && names.contains("click"), names)
check("mcp: tools carry annotations", listed?["result"]?["tools"]?.array?.first { $0["name"] == "snapshot" }?["annotations"]?["readOnlyHint"] == true)
let called = await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "click", "arguments": ["ref": "e3"]]])
check("mcp: a call reaches the tool", called?["result"]?["content"]?.array?.first?["text"] == #"click {"ref":"e3"}"#, called as Any)
let missing = await send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "fill", "arguments": ["ref": "e3"]]])
check("mcp: a missing argument is a tool error the model can read", missing?["result"]?["isError"] == true
      && (missing?["result"]?["content"]?.array?.first?["text"]?.string ?? "").contains("value"), missing as Any)
let wrongType = await send(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "click", "arguments": ["doubleClick": "yes"]]])
check("mcp: a wrong type is a tool error", wrongType?["result"]?["isError"] == true)
let badEnum = await send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "navigate", "arguments": ["action": "sideways"]]])
check("mcp: a value outside the enum is a tool error", badEnum?["result"]?["isError"] == true)
let unknownArgument = await send(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "list_tabs", "arguments": ["verbose": true]]])
check("mcp: an unknown argument is a tool error naming the real ones", (unknownArgument?["result"]?["content"]?.array?.first?["text"]?.string ?? "").contains("tabId"))
let unknownTool = await send(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "teleport"]])
check("mcp: an unknown tool is a protocol error", unknownTool?["error"]?["code"] == -32602)
check("mcp: an unknown method is -32601", await send(["jsonrpc": "2.0", "id": 10, "method": "sampling/whatever"])?["error"]?["code"] == -32601)
if case .reply(let reply) = await dispatcher.handle(Data("{nope".utf8), call: echo) {
    check("mcp: bad JSON is a parse error", reply["error"]?["code"] == -32700)
}
if case .reply(let reply) = await dispatcher.handle(([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "method": "notifications/x"]] as JSONValue).encoded(), call: echo) {
    check("mcp: a batch answers the requests in it", reply.array?.count == 1)
}

// MARK: Catalog

for tool in BrowserTools.all {
    let properties = tool.inputSchema["properties"]?.object ?? [:]
    let required = tool.inputSchema["required"]?.array?.compactMap(\.string) ?? []
    check("catalog: \(tool.name) requires only what it declares", required.allSatisfy { properties[$0] != nil }, required)
    check("catalog: \(tool.name) takes a tabId", properties["tabId"] != nil)
    check("catalog: \(tool.name) is described", tool.description.count > 20)
}
check("catalog: names are unique", Set(BrowserTools.all.map(\.name)).count == BrowserTools.all.count)

print(failures == 0 ? "✔ all \(passed) AgentKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
