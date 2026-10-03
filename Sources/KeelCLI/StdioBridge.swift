import Foundation
import AgentKit

/// `keel mcp`: the stdio transport for clients that launch their servers
/// (`claude mcp add keel -- keel mcp`). One JSON-RPC message per line in,
/// each forwarded to the HTTP endpoint, each reply one line out.
enum StdioBridge {
    static func run(config: Config) async -> Int32 {
        Console.humanToStderr = true
        let connection = MCPConnection(config: config, mayPair: true)
        let output = LineWriter()

        await withTaskGroup(of: Void.self) { group in
            for await line in standardInputLines() {
                guard let message = try? JSONValue.decode(line) else {
                    await output.write(["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "Parse error"]])
                    continue
                }
                if MCPMessage.isInitialize(message) {
                    // Everything after it rides the session it creates.
                    await forward(message, connection: connection, output: output)
                } else {
                    group.addTask { await forward(message, connection: connection, output: output) }
                }
            }
            // stdin closed: answer what is in flight (a script may pipe its
            // requests and close at once), then end the session.
            await group.waitForAll()
        }
        await connection.close()
        return 0
    }

    static func forward(_ message: JSONValue, connection: MCPConnection, output: LineWriter) async {
        do {
            if let reply = try await connection.send(message) { await output.write(reply) }
        } catch is CancellationError {
        } catch {
            let code: Int
            switch error as? CLIError {
            case .serverUnavailable: code = MCPHTTPClientCore.ErrorCode.serverUnavailable
            case .unauthorized, .pairingRefused: code = MCPHTTPClientCore.ErrorCode.unauthorized
            default: code = -32603
            }
            let text = (error as? CLIError)?.description ?? error.localizedDescription
            Console.warn("keel mcp: \(text)")
            if let replies = MCPMessage.errorReplies(for: message, code: code, message: text) { await output.write(replies) }
        }
    }

    /// Lines from stdin, read on a thread of their own so a slow reply never
    /// holds up reading.
    static func standardInputLines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let thread = Thread {
                var framer = LineFramer()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(STDIN_FILENO, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break }
                    for line in framer.append(Data(buffer[0..<count])) { continuation.yield(line) }
                }
                if let last = framer.finish() { continuation.yield(last) }
                continuation.finish()
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }
}

/// Writes whole lines to stdout, one at a time, each flushed as it goes.
actor LineWriter {
    func write(_ message: JSONValue) {
        try? FileHandle.standardOutput.write(contentsOf: LineFramer.frame(message))
    }
}
