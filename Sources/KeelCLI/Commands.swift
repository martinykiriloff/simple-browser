import Foundation
import AgentKit

enum Commands {
    // MARK: pair / unpair

    static func pair(_ config: Config, name: String) async throws -> Int32 {
        if config.tokenOverride != nil { Console.warn("Note: KEEL_TOKEN is set; it is used instead of the token this stores.") }
        _ = try await KeelServer(config: config).pair(name: name)
        print("Use it from an MCP client:  claude mcp add keel -- keel mcp")
        return 0
    }

    static func unpair(_ config: Config) -> Int32 {
        if TokenStore.delete(for: config) {
            print("✔ Deleted the stored token for \(config.account).")
            print("Keel still lists the client until you revoke it: Keel → Settings → Agents & permissions.")
        } else {
            print("No token stored for \(config.account).")
        }
        return 0
    }

    // MARK: status

    static func status(_ config: Config) async -> Int32 {
        let server = KeelServer(config: config)
        print("keel \(Config.version) · tool schema \(MCPDispatcher.toolSchemaVersion) (built in)")
        print("Endpoint      http://\(config.account)/mcp")
        let running = KeelServer.appIsRunning
        guard let health = await server.health() else {
            print("Server        ✘ not reachable")
            print("Keel app      \(running ? "running" : "not running")")
            print(running ? KeelServer.turnOnHint : "Open Keel, then: \(KeelServer.turnOnHint)")
            printToken(config)
            return 69
        }
        print("Server        ✔ \(health["name"]?.string ?? "reachable") (\(health["transport"]?.string ?? "?"))")
        let remoteSchema = health["toolSchemaVersion"]?.string ?? "?"
        let compatible = remoteSchema.split(separator: ".").first == MCPDispatcher.toolSchemaVersion.split(separator: ".").first
        print("Tool schema   \(remoteSchema)\(compatible ? "" : "  ⚠ different major version from this keel (\(MCPDispatcher.toolSchemaVersion))")")
        guard printToken(config) else {
            print("Pair with:    keel pair")
            return 0
        }
        let connection = MCPConnection(config: config, mayPair: false, mayLaunch: false)
        do {
            let reply = try await connection.initialize()
            if let version = reply["result"]?["serverInfo"]?["version"]?.string { print("Keel version  \(version)") }
            let tools = try await connection.request("tools/list")
            let count = tools["result"]?["tools"]?.array?.count ?? 0
            print("Token         ✔ accepted · \(count) tools available")
            await connection.close()
            return 0
        } catch {
            print("Token         ✘ \(error)")
            await connection.close()
            return 77
        }
    }

    @discardableResult
    private static func printToken(_ config: Config) -> Bool {
        guard let (token, source) = TokenStore.load(config) else {
            print("Token         none stored")
            return false
        }
        let where_: String
        switch source {
        case .environment: where_ = "from KEEL_TOKEN"
        case .keychain: where_ = "in the Keychain"
        case .file: where_ = "in \(TokenStore.fallbackFile.path)"
        }
        print("Token         …\(token.suffix(4)) \(where_)")
        return true
    }

    // MARK: schema

    static func schema(_ config: Config, out: String?) async throws -> Int32 {
        var document = await KeelServer(config: config).schema()
        if document == nil {
            Console.warn("Keel is not answering on port \(config.port); using the schema built into this keel (\(MCPDispatcher.toolSchemaVersion)).")
            document = BrowserTools.schemaDocument
        }
        let data = document!.encoded(pretty: true) + Data("\n".utf8)
        if let out {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            do { try data.write(to: url) } catch { throw CLIError.failed("Could not write \(url.path): \(error.localizedDescription)") }
            Console.warn("Wrote \(url.path)")
        } else {
            FileHandle.standardOutput.write(data)
        }
        return 0
    }

    // MARK: replay

    static func replay(_ config: Config, file: String, dryRun: Bool, keepGoing: Bool) async throws -> Int32 {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { throw CLIError.usage("Cannot read \(url.path)") }
        let plan: ReplayPlan
        do { plan = try ReplayPlan.parse(data) } catch { throw CLIError.failed(error.description) }
        let calls = plan.calls
        var header = "Replay of \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")"
        if let client = plan.client { header += " by \(client)" }
        if let recorded = plan.recorded { header += ", recorded \(recorded)" }
        print(header)
        if calls.isEmpty { print("Nothing to replay."); return 0 }
        if dryRun {
            for (index, call) in calls.enumerated() {
                let label = call.summary.isEmpty ? call.tool : call.summary
                print(String(format: "%3d. ", index + 1) + "\(call.tool)  \(call.arguments.jsonString)  — \(label)")
            }
            return 0
        }
        let connection = MCPConnection(config: config, mayPair: true)
        try await connection.initialize(clientName: "keel-replay")
        var failures = 0
        for (index, call) in calls.enumerated() {
            let reply: JSONValue
            do { reply = try await connection.callTool(call.tool, call.arguments) } catch {
                print("✘ \(index + 1). \(call.tool): \(error)")
                failures += 1
                if keepGoing { continue } else { break }
            }
            let (ok, line) = MCPToolOutcome.summarize(reply)
            print("\(ok ? "✔" : "✘") \(index + 1). \(call.tool): \(line)")
            if !ok {
                failures += 1
                if !keepGoing {
                    print("Stopped at step \(index + 1). Pass --keep-going to run the rest anyway.")
                    break
                }
            }
        }
        await connection.close()
        if failures == 0 { print("✔ Replayed \(calls.count) call\(calls.count == 1 ? "" : "s").") }
        return failures == 0 ? 0 : 1
    }

    // MARK: events

    static func events(_ config: Config, after: Int, follow: Bool) async throws -> Int32 {
        let connection = MCPConnection(config: config, mayPair: true)
        try await connection.initialize(clientName: "keel-events")
        var cursor = after
        repeat {
            let reply = try await connection.callTool("session_events", ["afterId": .number(Double(cursor)), "limit": 200])
            let (ok, line) = MCPToolOutcome.summarize(reply)
            guard ok else {
                await connection.close()
                throw CLIError.failed("session_events: \(line)")
            }
            let text = MCPToolOutcome.text(reply)
            if text != "No new events.", !text.isEmpty {
                print(text)
                fflush(stdout)
            } else if !follow {
                print(text.isEmpty ? "No new events." : text)
            }
            if let last = MCPToolOutcome.lastEventID(reply) { cursor = max(cursor, last) }
            if follow { try await Task.sleep(nanoseconds: 1_000_000_000) }
        } while follow
        await connection.close()
        return 0
    }
}
