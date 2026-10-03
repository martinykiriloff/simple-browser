import Foundation

/// Where the agent server is and who we are, from flags, the environment
/// and the app's own settings, in that order.
struct Config: Sendable {
    static let version = "0.1.0"
    static let defaultPort = 9333
    static let bundleID = "dev.simplebrowser.SimpleBrowser"

    var port: Int
    /// `KEEL_TOKEN`: a token to use instead of the stored one (scripts, CI,
    /// an app started with `--mcp-token`).
    var tokenOverride: String?

    var host: String { "127.0.0.1" }
    var account: String { "\(host):\(port)" }
    var base: URL { URL(string: "http://\(host):\(port)")! }
    var mcpURL: URL { base.appendingPathComponent("mcp") }

    static func resolve(portFlag: String?) throws -> Config {
        let environment = ProcessInfo.processInfo.environment
        var port = Self.appPort ?? defaultPort
        if let text = portFlag ?? environment["KEEL_PORT"] {
            guard let value = Int(text), (1...65535).contains(value) else { throw CLIError.usage("Not a port: \(text)") }
            port = value
        }
        let token = environment["KEEL_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        return Config(port: port, tokenOverride: token)
    }

    /// The port set in Keel → Settings, when it was changed from the default.
    static var appPort: Int? {
        let saved = UserDefaults(suiteName: bundleID)?.integer(forKey: "agent.port") ?? 0
        return (1024...65535).contains(saved) ? saved : nil
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case serverUnavailable(String)
    case unauthorized(String)
    case pairingRefused(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let text), .serverUnavailable(let text), .unauthorized(let text), .pairingRefused(let text), .failed(let text):
            return text
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 64
        case .serverUnavailable: return 69
        case .unauthorized, .pairingRefused: return 77
        case .failed: return 1
        }
    }
}

/// Messages for the person. In `keel mcp` stdout is the protocol, so
/// everything human goes to stderr there.
enum Console {
    nonisolated(unsafe) static var humanToStderr = false

    static func say(_ text: String) {
        if humanToStderr { warn(text) } else { print(text); fflush(stdout) }
    }

    static func warn(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// `--flag value` and `--switch` parsing, enough for a handful of subcommands.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []

    init(_ arguments: [String], valued: Set<String>, switches allowed: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                var name = String(argument.dropFirst(2))
                var inline: String?
                if let equals = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if valued.contains(name) {
                    if let inline { options[name] = inline } else {
                        index += 1
                        guard index < arguments.count else { throw CLIError.usage("--\(name) needs a value") }
                        options[name] = arguments[index]
                    }
                } else if allowed.contains(name) {
                    switches.insert(name)
                } else {
                    throw CLIError.usage("Unknown option --\(name)")
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }
}
