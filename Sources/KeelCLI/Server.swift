import Foundation
import AgentKit

/// Plain HTTP to the agent server.
enum HTTP {
    /// Tool calls can wait minutes (an approval, `request_human`), and
    /// pairing waits up to five; nothing here should time out before them.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 660
        configuration.timeoutIntervalForResource = 660
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]   // loopback only, never through a proxy
        return URLSession(configuration: configuration)
    }()

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    static func send(_ method: String, _ url: URL, body: Data? = nil, headers: [(String, String)] = [],
                     timeout: TimeInterval = 660) async throws -> Response {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var fields: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] { fields[String(describing: key)] = String(describing: value) }
        return Response(status: http?.statusCode ?? 0, headers: fields, body: data)
    }

    /// Nobody listening: the app is not running, or its server is off.
    static func isRefused(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
    }
}

/// Finding the server, starting the app, and pairing.
struct KeelServer: Sendable {
    let config: Config

    static let turnOnHint = "Turn on Keel → Settings → Agents & permissions → Allow agent connections"

    /// `GET /`: the health document, or nil when nothing answers.
    func health() async -> JSONValue? {
        guard let response = try? await HTTP.send("GET", config.base, timeout: 3), response.status == 200,
              let value = try? JSONValue.decode(response.body), value["mcp"] != nil else { return nil }
        return value
    }

    /// `GET /schema`.
    func schema() async -> JSONValue? {
        guard let response = try? await HTTP.send("GET", config.base.appendingPathComponent("schema"), timeout: 3),
              response.status == 200 else { return nil }
        return try? JSONValue.decode(response.body)
    }

    static var appIsRunning: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Keel"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    static func open(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Makes sure something answers: starts Keel when it is not running and
    /// waits up to `wait` seconds for its server. Throws with what the person
    /// should do when it still does not answer.
    func ensureRunning(launch: Bool = true, wait: TimeInterval = 15) async throws {
        if await health() != nil { return }
        var launched = false
        if launch, !Self.appIsRunning {
            Console.warn("Keel is not running; starting it…")
            launched = Self.open(["-g", "-b", Config.bundleID]) || Self.open(["-g", "-a", "Keel"])
            if !launched {
                throw CLIError.serverUnavailable("Keel is not running and could not be started. Install Keel, open it, and \(Self.turnOnHint.prefix(1).lowercased() + Self.turnOnHint.dropFirst()).")
            }
        }
        if launched || Self.appIsRunning {
            let deadline = Date().addingTimeInterval(launched ? wait : min(wait, 3))
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
                if await health() != nil { return }
            }
        }
        if Self.appIsRunning || launched {
            throw CLIError.serverUnavailable("Keel is running, but its agent server is not answering on port \(config.port). \(Self.turnOnHint) (and check the port matches, or pass --port).")
        }
        throw CLIError.serverUnavailable("Keel is not running. Open Keel; then \(Self.turnOnHint.prefix(1).lowercased() + Self.turnOnHint.dropFirst()).")
    }

    /// `POST /pair`: asks the person to approve this client, waits for them,
    /// and stores the token. Progress goes through `Console`.
    func pair(name: String) async throws -> String {
        try await ensureRunning()
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let body: JSONValue = ["name": .string(name), "version": .string(Config.version), "pid": .number(Double(pid))]
        Console.say("Waiting for you to approve “\(name)” in Keel… (pid \(pid))")
        Console.say("Keel shows a pairing request naming “\(name)” and process \(pid). Check both match, then click Approve. (Up to 5 minutes.)")
        let response: HTTP.Response
        do {
            response = try await HTTP.send("POST", config.base.appendingPathComponent("pair"), body: body.encoded(),
                                           headers: [("Content-Type", "application/json")], timeout: 330)
        } catch {
            throw CLIError.serverUnavailable("Pairing failed: \(error.localizedDescription)")
        }
        guard response.status == 200, let reply = try? JSONValue.decode(response.body), let token = reply["token"]?.string else {
            let reason = MCPHTTPClientCore.explanation(response.body) ?? "HTTP \(response.status)"
            throw CLIError.pairingRefused("Not paired: \(reason)")
        }
        let place = (try? TokenStore.save(token, for: config)) ?? nil
        let id = reply["clientId"]?.string ?? "?"
        switch place {
        case .keychain: Console.say("✔ Paired as \(id). Token saved in the login Keychain (“\(TokenStore.service)”, \(config.account)).")
        case .file: Console.say("✔ Paired as \(id). Token saved in \(TokenStore.fallbackFile.path) (the Keychain was unavailable).")
        default: Console.say("✔ Paired as \(id), but the token could not be saved; it is used for this run only.")
        }
        return token
    }
}

/// One MCP session over Streamable HTTP: the token, the session id, and
/// starting over when the server forgets either.
actor MCPConnection {
    let server: KeelServer
    /// May pair when there is no token or it was refused.
    let mayPair: Bool
    /// Starts Keel when nothing answers.
    let mayLaunch: Bool
    private var core: MCPHTTPClientCore
    private var pairName: String
    private var pairing: Task<String, any Error>?
    private var reinitializing: Task<Void, any Error>?
    private var launchTried = false

    init(config: Config, mayPair: Bool, mayLaunch: Bool = true, pairName: String = "keel") {
        self.server = KeelServer(config: config)
        self.mayPair = mayPair
        self.mayLaunch = mayLaunch
        self.pairName = pairName
        self.core = MCPHTTPClientCore(token: TokenStore.load(config)?.token)
    }

    var hasToken: Bool { core.token != nil }
    var sessionID: String? { core.sessionID }

    /// Sends one message (or batch); the reply, or nil when the server only accepted it.
    func send(_ message: JSONValue) async throws -> JSONValue? {
        if let initialize = MCPMessage.initialize(in: message), let name = initialize["params"]?["clientInfo"]?["name"]?.string {
            pairName = name == "keel" ? name : "keel mcp · \(name)"
        }
        core.willSend(message)
        var attempts = 0
        while true {
            attempts += 1
            let generation = core.generation
            let tokenUsed = core.token
            let response: HTTP.Response
            do {
                response = try await HTTP.send("POST", server.config.mcpURL, body: message.encoded(), headers: core.headers(for: message))
            } catch where HTTP.isRefused(error) && attempts <= 2 {
                try await ensureServer()
                continue
            } catch where HTTP.isRefused(error) {
                throw CLIError.serverUnavailable("Keel's agent server is not answering on port \(server.config.port). \(KeelServer.turnOnHint).")
            }
            switch core.handle(status: response.status, headers: response.headers, body: response.body, for: message) {
            case .reply(let body):
                guard let value = try? JSONValue.decode(body) else { throw CLIError.failed("The server sent something that is not JSON") }
                return value
            case .nothing:
                return nil
            case .sessionLost where attempts <= 3:
                if !MCPMessage.isInitialize(message) { try await reinitialize(seen: generation) }
            case .unauthorized(let reason) where mayPair && attempts <= 3:
                Console.warn("Keel refused the stored token: \(reason)")
                try await repair(after: tokenUsed)
                if !MCPMessage.isInitialize(message) { core.endSession(); try await reinitialize(seen: core.generation) }
            case .unauthorized(let reason):
                throw CLIError.unauthorized(reason + (mayPair || reason.contains("keel pair") ? "" : " Run `keel pair`."))
            case .sessionLost:
                throw CLIError.failed("The server keeps losing the session")
            case .failed(let status, let reason):
                throw CLIError.failed("Keel answered \(status): \(reason)")
            }
        }
    }

    /// `initialize` then `notifications/initialized`, for the CLI's own commands.
    @discardableResult
    func initialize(clientName: String = "keel") async throws -> JSONValue {
        let request = MCPMessage.request(id: "init", method: "initialize", params: [
            "protocolVersion": .string(MCPDispatcher.supportedVersions[0]),
            "capabilities": [:],
            "clientInfo": ["name": .string(clientName), "version": .string(Config.version)],
        ])
        guard let reply = try await send(request) else { throw CLIError.failed("No answer to initialize") }
        if let error = reply["error"] { throw CLIError.failed(error["message"]?.string ?? "initialize failed") }
        _ = try await send(MCPMessage.notification("notifications/initialized"))
        return reply
    }

    private var nextID = 1

    /// A request from the CLI itself; returns the reply.
    func request(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        nextID += 1
        guard let reply = try await send(MCPMessage.request(id: .number(Double(nextID)), method: method, params: params)) else {
            throw CLIError.failed("No answer to \(method)")
        }
        return reply
    }

    func callTool(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        try await request("tools/call", ["name": .string(name), "arguments": arguments])
    }

    /// `DELETE /mcp`: ends the session on the server.
    func close() async {
        guard let id = core.sessionID else { return }
        var headers = [("Mcp-Session-Id", id)]
        if let token = core.token { headers.append(("Authorization", "Bearer \(token)")) }
        _ = try? await HTTP.send("DELETE", server.config.mcpURL, headers: headers, timeout: 3)
        core.endSession()
    }

    // MARK: Starting over

    private func ensureServer() async throws {
        let launch = mayLaunch && !launchTried
        launchTried = true
        try await server.ensureRunning(launch: launch)
    }

    /// Pairs once for everyone waiting, unless someone already replaced the
    /// token that was refused.
    private func repair(after refused: String?) async throws {
        if let refused, core.token != refused { return }
        if refused == nil, core.token != nil { return }
        if let pairing {
            _ = try await pairing.value
            return
        }
        if refused != nil { TokenStore.delete(for: server.config) }
        let task = Task { [server, pairName] in try await server.pair(name: pairName) }
        pairing = task
        defer { pairing = nil }
        core.token = try await task.value
    }

    /// Starts a new session with the client's original initialize, once for
    /// everyone that saw the old one go.
    private func reinitialize(seen generation: Int) async throws {
        if core.generation != generation, core.sessionID != nil { return }
        if let reinitializing {
            try await reinitializing.value
            return
        }
        guard let request = core.reinitializeRequest() else {
            throw CLIError.failed("The session was lost before it was initialized")
        }
        Console.warn("Keel forgot this session (restarted?); starting a new one.")
        let task = Task { try await self.performReinitialize(request) }
        reinitializing = task
        defer { reinitializing = nil }
        try await task.value
    }

    private func performReinitialize(_ request: JSONValue) async throws {
        let response = try await HTTP.send("POST", server.config.mcpURL, body: request.encoded(), headers: core.headers(for: request))
        switch core.handle(status: response.status, headers: response.headers, body: response.body, for: request) {
        case .reply, .nothing: break
        case .unauthorized(let reason): throw CLIError.unauthorized(reason)
        case .sessionLost: throw CLIError.failed("The server refused a new session")
        case .failed(let status, let reason): throw CLIError.failed("Keel answered \(status): \(reason)")
        }
        let initialized = MCPMessage.notification("notifications/initialized")
        _ = try? await HTTP.send("POST", server.config.mcpURL, body: initialized.encoded(), headers: core.headers(for: initialized))
    }
}
