import Foundation
import Network
import AgentKit

/// The agent server: MCP over Streamable HTTP on the loopback interface, so
/// Claude Code, Cursor, Codex and any other MCP client can drive the browser
/// and read what its DevTools see.
///
/// Off until the person turns it on (Settings → Developer, or `--mcp-port`).
/// Bound to 127.0.0.1 only, and every request needs the bearer token unless
/// the person chose otherwise; see `AgentAccessPolicy`.
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
    private(set) var state: State = .off { didSet { onChange?() } }
    /// Clients that introduced themselves, newest last.
    private(set) var clients: [String] = []
    /// Recent tool calls, newest last.
    private(set) var activity: [String] = []
    var onChange: (() -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [String: MCPClientInfo] = [:]
    private var policy = AgentAccessPolicy(token: nil, port: AgentServer.defaultPort)
    /// Overrides from the command line, for scripted runs.
    var portOverride: Int?
    var tokenOverride: String??

    private lazy var dispatcher = MCPDispatcher(
        serverName: "simplebrowser",
        serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        instructions: BrowserTools.instructions,
        tools: BrowserTools.all
    )

    init(toolbox: AgentToolbox) {
        self.toolbox = toolbox
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
            return .json(["name": "SimpleBrowser agent server", "mcp": .string(Self.endpointPath), "transport": "streamable-http"])
        }
        guard request.path == Self.endpointPath else { return .text("Not found. The MCP endpoint is \(Self.endpointPath).", status: 404) }
        if let denial = policy.check(request) {
            log("refused: \(denial.message)")
            return .json(["error": .string(denial.message)], status: denial.status,
                         headers: denial.status == 401 ? [("WWW-Authenticate", "Bearer")] : [])
        }
        switch request.method {
        case "POST":
            return await handleMessage(request)
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

    private func handleMessage(_ request: HTTPRequest) async -> HTTPResponse {
        let session = request.header("mcp-session-id")
        // A session from before a restart: the client starts over.
        if let session, sessions[session] == nil, !Self.isInitialize(request.body) {
            return .json(["jsonrpc": "2.0", "id": nil, "error": ["code": -32001, "message": "Session not found; initialize again"]], status: 404)
        }
        let toolbox = self.toolbox
        let newSession = SessionBox()
        let outcome = await dispatcher.handle(request.body, onInitialize: { [weak self] client in
            await MainActor.run {
                guard let self else { return }
                let id = UUID().uuidString
                self.sessions[id] = client
                newSession.id = id
                toolbox.clientName = Self.friendlyName(client.name)
                self.clients.append("\(Self.friendlyName(client.name))\(client.version.map { " \($0)" } ?? "")")
                if self.clients.count > 20 { self.clients.removeFirst() }
                self.log("\(Self.friendlyName(client.name)) connected (MCP \(client.protocolVersion))")
            }
        }, call: { name, arguments in
            await toolbox.call(name, arguments)
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

    /// The command that adds this browser to Claude Code.
    var claudeCodeCommand: String {
        var command = "claude mcp add --transport http simplebrowser \(endpointURL)"
        if let token = activeToken { command += " --header \"Authorization: Bearer \(token)\"" }
        return command
    }

    /// The `mcpServers` entry most other clients (Cursor, Windsurf, VS Code) take.
    var clientConfigJSON: String {
        var server: [String: JSONValue] = ["type": "http", "url": .string(endpointURL)]
        if let token = activeToken { server["headers"] = ["Authorization": .string("Bearer \(token)")] }
        let config: JSONValue = ["mcpServers": ["simplebrowser": .object(server)]]
        return String(decoding: config.encoded(pretty: true), as: UTF8.self)
    }
}

@MainActor
private final class SessionBox {
    var id: String?
}
