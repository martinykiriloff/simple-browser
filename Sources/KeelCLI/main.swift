import Foundation
import AgentKit

// `keel`: Keel's command-line companion. Pairs with the browser's agent
// server, bridges stdio MCP clients to it, and replays recorded sessions.

let usage = """
keel \(Config.version) — the command line for Keel's agent server

Usage:
  keel pair [--name <name>] [--port <port>]   Ask Keel for a token (you approve it in Keel)
  keel mcp [--port <port>]                    stdio MCP server for Claude Code, Cursor, Codex…
  keel status [--port <port>]                 Is Keel reachable, and is the token accepted?
  keel schema [--out <file>] [--port <port>]  Print the published tool schema (works offline)
  keel replay <file.json> [--dry-run] [--keep-going] [--port <port>]
                                              Run a session exported from Keel's Agent panel again
  keel events [--after <id>] [--follow] [--port <port>]
                                              Print this client's session events
  keel unpair [--port <port>]                 Delete the stored token
  keel --version | help

Set up Claude Code:   claude mcp add keel -- keel mcp
Environment: KEEL_PORT (default 9333, or the port set in Keel), KEEL_TOKEN (use this token instead of the stored one).
"""

func run(_ argv: [String]) async throws -> Int32 {
    guard let command = argv.first else { print(usage); return 0 }
    let rest = Array(argv.dropFirst())
    switch command {
    case "help", "--help", "-h":
        print(usage)
        return 0
    case "--version", "-v", "version":
        print("keel \(Config.version) (tool schema \(MCPDispatcher.toolSchemaVersion))")
        return 0
    case "pair":
        let args = try Arguments(rest, valued: ["name", "port"], switches: [])
        return try await Commands.pair(try Config.resolve(portFlag: args.options["port"]), name: args.options["name"] ?? "keel")
    case "mcp":
        let args = try Arguments(rest, valued: ["port"], switches: [])
        return await StdioBridge.run(config: try Config.resolve(portFlag: args.options["port"]))
    case "status":
        let args = try Arguments(rest, valued: ["port"], switches: [])
        return await Commands.status(try Config.resolve(portFlag: args.options["port"]))
    case "schema":
        let args = try Arguments(rest, valued: ["port", "out"], switches: [])
        return try await Commands.schema(try Config.resolve(portFlag: args.options["port"]), out: args.options["out"])
    case "replay":
        let args = try Arguments(rest, valued: ["port"], switches: ["dry-run", "keep-going"])
        guard let file = args.positional.first else { throw CLIError.usage("keel replay needs a file: keel replay <file.json>") }
        return try await Commands.replay(try Config.resolve(portFlag: args.options["port"]), file: file,
                                         dryRun: args.switches.contains("dry-run"), keepGoing: args.switches.contains("keep-going"))
    case "events":
        let args = try Arguments(rest, valued: ["port", "after"], switches: ["follow"])
        let after = try args.options["after"].map { text -> Int in
            guard let value = Int(text), value >= 0 else { throw CLIError.usage("--after takes an event id") }
            return value
        } ?? 0
        return try await Commands.events(try Config.resolve(portFlag: args.options["port"]), after: after, follow: args.switches.contains("follow"))
    case "unpair":
        let args = try Arguments(rest, valued: ["port"], switches: [])
        return Commands.unpair(try Config.resolve(portFlag: args.options["port"]))
    default:
        throw CLIError.usage("Unknown command “\(command)”. Run `keel help`.")
    }
}

signal(SIGPIPE, SIG_IGN)
let status: Int32
do {
    status = try await run(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIError {
    Console.warn("keel: \(error)")
    status = error.exitCode
} catch {
    Console.warn("keel: \(error.localizedDescription)")
    status = 1
}
exit(status)
