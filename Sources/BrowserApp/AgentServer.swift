import Foundation
import Network
import AgentKit

/// The agent server: MCP over Streamable HTTP on the loopback interface, so
/// Claude Code, Cursor, Codex and any other MCP client can drive the browser
/// and read what its DevTools see.
///
/// Off until the person turns it on (Settings → Developer, or `--mcp-port`).
/// Bound to 127.0.0.1 only. Every client pairs and gets a token of its own
/// (`POST /pair`, approved by the person), and every call is checked by the
/// trust layer before it reaches a page; see `AgentTrust`.
@MainActor
final class AgentServer {

    enum State: Equatable {
        case off
        case starting
        case listening(port: Int)
        case failed(String)
    }

    static let defaultPort = 9333
    static let endpointPath = "/mcp"

    // MARK: Settings

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "agent.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "agent.enabled") }
    }

    static var port: Int {
        get { let saved = UserDefaults.standard.integer(forKey: "agent.port"); return (1024...65535).contains(saved) ? saved : defaultPort }
        set { UserDefaults.standard.set(newValue, forKey: "agent.port") }
    }

    static var requiresToken: Bool {
        get { UserDefaults.standard.object(forKey: "agent.requireToken") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agent.requireToken") }
    }

    /// Made on first use and kept until regenerated.
    static var token: String {
        if let saved = UserDefaults.standard.string(forKey: "agent.token"), saved.count >= 32 { return saved }
        let made = AgentAccessPolicy.makeToken()
        UserDefaults.standard.set(made, forKey: "agent.token")
        return made
    }

    static func regenerateToken() {
        UserDefaults.standard.set(AgentAccessPolicy.makeToken(), forKey: "agent.token")
    }

    // MARK: State

    let toolbox: AgentToolbox
    let trust: AgentTrust
    private(set) var state: State = .off { didSet { onChange?() } }
    /// Clients that introduced themselves, newest last.
    private(set) var clients: [String] = []
    /// Recent tool calls, newest last.
    private(set) var activity: [String] = []
    var onChange: (() -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [String: (info: MCPClientInfo, client: String)] = [:]
    private var policy = AgentAccessPolicy(token: nil, port: AgentServer.defaultPort)
    /// A client the command line set up (`--mcp-token`), kept in memory only.
    private var commandLineClient: PairedClient?
    /// `--agent-budget-actions`: its action budget.
    var commandLineBudget: Int?
    /// Overrides from the command line, for scripted runs.
    var portOverride: Int?
    var tokenOverride: String??

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// The tools this client may see: its scope, plus the WebMCP tools of
    /// its session's pages when the person has WebMCP on.
    func dispatcher(for client: PairedClient, live: AgentTrust.Live?) -> MCPDispatcher {
        var tools = BrowserTools.tools(for: client.scope)
        if trust.webMCPEnabled, let live {
            let pageTools = trust.webMCP.all(in: live.openTabs.map { $0.tab.rawValue.uuidString })
            tools += pageTools.filter { client.scope == .all || $0.readOnly }.map(\.mcpTool)
        } else {
            tools.removeAll { $0.name == "page_tools" || $0.name == "call_page_tool" }
        }
        return MCPDispatcher(serverName: "keel", serverVersion: Self.version, instructions: BrowserTools.instructions,
                             tools: tools, prompts: BrowserTools.prompts)
    }

    init(toolbox: AgentToolbox, trust: AgentTrust) {
        self.toolbox = toolbox
        self.trust = trust
        toolbox.trust = trust
        toolbox.onActivity = { [weak self] line in self?.log(line) }
    }

    var activePort: Int { portOverride ?? Self.port }
    var activeToken: String? {
        if let tokenOverride { return tokenOverride }
        return Self.requiresToken ? Self.token : nil
    }

    var endpointURL: String { "http://127.0.0.1:\(activePort)\(Self.endpointPath)" }

    /// Starts, restarts with new settings, or stops, to match the settings.
    func sync() {
        if Self.isEnabled || portOverride != nil { start() } else { stop() }
    }

    func start() {
        stop()
        if let tokenOverride {
            commandLineClient = PairedClient(id: "cli0", name: "Command line", tokenHash: tokenOverride.map(ClientRegistry.hash) ?? "",
                                             tokenHint: String((tokenOverride ?? "none").suffix(4)), pairedAt: Date(),
                                             defaultMode: trust.settings.defaultMode, approvalPolicy: trust.settings.policy,
                                             budgets: commandLineBudget.map { var b = trust.settings.budgets; b.maxActions = $0; return b } ?? trust.settings.budgets)
        }
        let port = activePort
        policy = AgentAccessPolicy(token: activeToken, port: port)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { state = .failed("Invalid port \(port)"); return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            state = .starting
            listener.stateUpdateHandler = { [weak self] newState in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    switch newState {
                    case .ready: self.state = .listening(port: port)
                    case .failed(let error):
                        self.state = .failed(Self.describe(error, port: port))
                        self.stop(keepState: true)
                    case .cancelled: if case .listening = self.state { self.state = .off }
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch {
            state = .failed(Self.describe(error, port: port))
        }
    }

    func stop(keepState: Bool = false) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if !keepState { state = .off }
    }

    private static func describe(_ error: NWError, port: Int) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is in use by another program. Choose another port."
        }
        return error.localizedDescription
    }

    private static func describe(_ error: any Error, port: Int) -> String {
        if let error = error as? NWError { return describe(error, port: port) }
        return error.localizedDescription
    }

    private func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        activity.append("\(stamp)  \(line)")
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
        onChange?()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.connections[key] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch HTTPRequestParser.parse(buffer) {
                case .incomplete:
                    if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                case .invalid(let status, let reason):
                    self.send(.text(reason, status: status), on: connection)
                case .complete(let request, _):
                    Task { @MainActor in
                        let response = await self.respond(to: request)
                        self.send(response, on: connection)
                    }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Requests

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" { return HTTPResponse(status: 204) }
        if request.method == "GET", request.path == "/" || request.path == "/health" {
            // Enough for a client to find the endpoint; nothing about the browser.
            return .json(["name": "Keel agent server", "mcp": .string(Self.endpointPath), "pair": "/pair", "transport": "streamable-http",
                          "toolSchemaVersion": .string(MCPDispatcher.toolSchemaVersion)])
        }
        if request.path == "/schema", request.method == "GET" {
            return .json(BrowserTools.schemaDocument)
        }
        if request.path == "/pair" {
            return await handlePairing(request)
        }
        guard request.path == Self.endpointPath else { return .text("Not found. The MCP endpoint is \(Self.endpointPath).", status: 404) }
        // Host and Origin first: no web page, no DNS rebinding.
        if let denial = AgentAccessPolicy(token: nil, port: activePort).checkTransport(request) {
            log("refused: \(denial.message)")
            return .json(["error": .string(denial.message)], status: denial.status)
        }
        guard let client = authenticate(request) else {
            let message = request.header("authorization") == nil
                ? "Missing Authorization: Bearer <token>. Pair this client: run `keel pair`, or Keel → Agent → Pair a New Agent…"
                : "This token is not paired with Keel, or was revoked. Pair again: `keel pair`, or Keel → Agent → Pair a New Agent…"
            log("refused: \(message)")
            return .json(["error": .string(message)], status: 401, headers: [("WWW-Authenticate", "Bearer")])
        }
        switch request.method {
        case "POST":
            return await handleMessage(request, client: client)
        case "DELETE":
            if let id = request.header("mcp-session-id") { sessions[id] = nil }
            return HTTPResponse(status: 200)
        case "GET":
            // No server-initiated stream: everything comes back as a reply.
            return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")])
        default:
            return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")])
        }
    }

    /// The paired client behind a request's bearer token.
    private func authenticate(_ request: HTTPRequest) -> PairedClient? {
        let header = request.header("authorization") ?? ""
        let presented = header.lowercased().hasPrefix("bearer ") ? String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
        if let commandLineClient, case .some(.some(let token)) = tokenOverride, AgentAccessPolicy.constantTimeEquals(presented, token) {
            return commandLineClient
        }
        if case .some(.none) = tokenOverride {
            // `--mcp-no-auth`, for scripted runs only.
            return commandLineClient
        }
        guard !presented.isEmpty, let client = trust.authenticate(presented) else { return nil }
        trust.touch(client.id)
        return client
    }

    /// `POST /pair {"name", "version", "pid"}`: a client asks to pair. The
    /// person sees the request with a code the client shows too, and the
    /// reply carries the new token once they approve. No web page may ask.
    private func handlePairing(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "POST" else { return HTTPResponse(status: 405, headers: [("Allow", "POST")]) }
        let host = (request.header("host") ?? "").lowercased()
        let hosts = ["127.0.0.1", "localhost", "[::1]"].flatMap { [$0, "\($0):\(activePort)"] }
        guard hosts.contains(host) else { return .json(["error": "Host is not this machine's loopback address"], status: 403) }
        guard (request.header("origin") ?? "").isEmpty else { return .json(["error": "Web pages cannot pair with Keel"], status: 403) }
        guard trust.pairings.count < 3 else { return .json(["error": "Too many pairing requests are waiting"], status: 429) }
        let body = (try? JSONValue.decode(request.body)) ?? [:]
        let name = String((body["name"]?.string ?? "MCP client").prefix(60))
        log("\(Self.friendlyName(name)) asked to pair")
        // A client may bring its own six-digit code, so it can show the code the person sees.
        let code = body["code"]?.string.flatMap { $0.count == 6 && $0.allSatisfy(\.isNumber) ? $0 : nil }
        guard let paired = await trust.requestPairing(clientName: name, version: body["version"]?.string,
                                                      processID: body["pid"]?.int, code: code, remote: "127.0.0.1") else {
            log("pairing refused")
            return .json(["error": "The person did not approve the pairing, or it expired."], status: 403)
        }
        log("\(paired.client.name) paired (\(paired.client.id))")
        return .json(["token": .string(paired.token), "clientId": .string(paired.client.id), "endpoint": .string(endpointURL),
                      "toolSchemaVersion": .string(MCPDispatcher.toolSchemaVersion)])
    }

    /// The code a pairing request shows, for `keel pair` to print while it waits.
    func pendingCode(for name: String) -> String? {
        trust.pairings.last { $0.request.clientName == name }?.request.displayCode
    }

    private func handleMessage(_ request: HTTPRequest, client: PairedClient) async -> HTTPResponse {
        let session = request.header("mcp-session-id")
        // A session from before a restart: the client starts over.
        if let session, sessions[session] == nil, !Self.isInitialize(request.body) {
            return .json(["jsonrpc": "2.0", "id": nil, "error": ["code": -32001, "message": "Session not found; initialize again"]], status: 404)
        }
        let toolbox = self.toolbox
        let newSession = SessionBox()
        let live = trust.session(for: client, transport: session)
        let outcome = await dispatcher(for: client, live: live).handle(request.body, onInitialize: { [weak self] info in
            await MainActor.run {
                guard let self else { return }
                let id = UUID().uuidString
                self.sessions[id] = (info, client.id)
                newSession.id = id
                live.transportIDs.insert(id)
                if live.session.clientName != Self.friendlyName(info.name), client.name.hasPrefix("Shared token") || client.name == "Command line" {
                    live.session.clientName = Self.friendlyName(info.name)
                }
                self.clients.append("\(Self.friendlyName(info.name))\(info.version.map { " \($0)" } ?? "")")
                if self.clients.count > 20 { self.clients.removeFirst() }
                self.log("\(Self.friendlyName(info.name)) connected as \(client.name) (MCP \(info.protocolVersion)) · session \(live.session.id)")
            }
        }, call: { name, arguments in
            await toolbox.call(name, arguments, live: live, client: client)
        })
        var headers: [(String, String)] = []
        if let id = newSession.id ?? session { headers.append(("Mcp-Session-Id", id)) }
        switch outcome {
        case .reply(let message): return .json(message, headers: headers)
        case .accepted: return HTTPResponse(status: 202, headers: headers)
        }
    }

    private static func isInitialize(_ body: Data) -> Bool {
        (try? JSONValue.decode(body))?["method"]?.string == "initialize"
    }

    /// "claude-code" → "Claude Code".
    static func friendlyName(_ name: String) -> String {
        let known = ["claude-code": "Claude Code", "claude-ai": "Claude", "cursor-vscode": "Cursor", "codex-mcp-client": "Codex",
                     "mcp-inspector": "MCP Inspector", "Visual Studio Code": "VS Code"]
        if let match = known[name] { return match }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - Setting up clients

    /// The command that adds this browser to Claude Code, with a paired client's token.
    func claudeCodeCommand(token: String?) -> String {
        var command = "claude mcp add --transport http keel \(endpointURL)"
        if let token { command += " --header \"Authorization: Bearer \(token)\"" }
        return command
    }

    /// The same through the stdio launcher, which pairs by itself.
    static let claudeCodeStdioCommand = "claude mcp add keel -- keel mcp"

    var claudeCodeCommand: String { claudeCodeCommand(token: activeToken) }

    /// The `mcpServers` entry most other clients (Cursor, Windsurf, VS Code) take.
    var clientConfigJSON: String { clientConfigJSON(token: activeToken) }

    func clientConfigJSON(token: String?) -> String {
        var server: [String: JSONValue] = ["type": "http", "url": .string(endpointURL)]
        if let token { server["headers"] = ["Authorization": .string("Bearer \(token)")] }
        let config: JSONValue = ["mcpServers": ["keel": .object(server)]]
        return String(decoding: config.encoded(pretty: true), as: UTF8.self)
    }
}

@MainActor
private final class SessionBox {
    var id: String?
}
