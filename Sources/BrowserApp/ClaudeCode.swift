import Foundation

/// The Claude panel's other way to Claude: the Claude Code CLI installed on
/// this Mac, signed in with the person's own Claude account, so no API key is
/// needed. It runs in print mode with every tool off and no MCP servers, so it
/// can only answer: it never reads files or acts on its own.
enum ClaudeCode {
    /// Where the installers put `claude`. An app opened from Finder does not
    /// get the shell's PATH, so these are looked at directly.
    static let candidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude", "\(home)/.volta/bin/claude"]
    }()

    nonisolated(unsafe) private static var cachedPath: String??

    /// The `claude` executable, or nil when Claude Code is not installed.
    static func path() -> String? {
        if let cachedPath { return cachedPath }
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            // Last resort: ask a login shell, which has the person's PATH.
            let output = run("/bin/zsh", ["-lc", "command -v claude"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let output, output.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: output) { found = output }
        }
        cachedPath = .some(found)
        return found
    }

    /// "2.1.288", from `claude --version`.
    static func version() -> String? {
        guard let path = path(), let output = run(path, ["--version"]) else { return nil }
        return output.split(separator: " ").first.map(String.init)
    }

    /// Forgets the found path, so an install made since is picked up.
    static func rescan() { cachedPath = nil }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// The conversation as one prompt: print mode takes a single message, so
    /// earlier turns go in as a transcript before the latest question.
    static func prompt(from messages: [[String: Any]]) -> String {
        let turns = messages.compactMap { message -> (String, String)? in
            guard let role = message["role"] as? String, let content = message["content"] as? String else { return nil }
            return (role, content)
        }
        guard let last = turns.last else { return "" }
        let earlier = turns.dropLast()
        guard !earlier.isEmpty else { return last.1 }
        let transcript = earlier.map { "<\($0.0)>\n\($0.1)\n</\($0.0)>" }.joined(separator: "\n\n")
        return "<earlier_conversation>\n\(transcript)\n</earlier_conversation>\n\n\(last.1)"
    }
}

/// One answer from Claude Code, streamed as the Claude panel's events:
/// `start`, `delta`, `stop`, `error`, `done`, the same as `ClaudeStream`.
final class ClaudeCodeStream: @unchecked Sendable {
    private let onEvent: @Sendable (_ kind: String, _ payload: [String: Any]) -> Void
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var cancelled = false
    private var answer = ""
    private var stderrTail = Data()

    init(onEvent: @escaping @Sendable (String, [String: Any]) -> Void) {
        self.onEvent = onEvent
    }

    func start(path: String, system: String, messages: [[String: Any]], effort: String) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                             "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                             "--system-prompt", system, "--effort", effort]
        // A folder of its own, so nothing it might look at is the person's.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("keel-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        process.currentDirectoryURL = work
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 4000 { self.stderrTail = self.stderrTail.suffix(4000) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.consume(output.fileHandleForReading.readDataToEndOfFile())
            self.lock.lock()
            let wasCancelled = self.cancelled
            let tail = String(decoding: self.stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            self.lock.unlock()
            if wasCancelled { self.finish("done", ["cancelled": true]); return }
            if process.terminationStatus != 0 {
                let line = tail.split(separator: "\n").last.map(String.init) ?? "Claude Code exited with status \(process.terminationStatus)"
                self.finish("error", ["message": line])
                return
            }
            self.finish("done", [:])
        }
        try process.run()
        input.fileHandleForWriting.write(Data(ClaudeCode.prompt(from: messages).utf8))
        try? input.fileHandleForWriting.close()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// One JSON object per line.
    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system" where event["subtype"] as? String == "init":
            onEvent("start", ["model": event["model"] as? String ?? "Claude Code"])
        case "stream_event":
            guard let inner = event["event"] as? [String: Any], inner["type"] as? String == "content_block_delta",
                  let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            lock.lock(); answer += text; lock.unlock()
            onEvent("delta", ["text": text])
        case "result":
            if event["is_error"] as? Bool == true {
                finish("error", ["message": event["result"] as? String ?? "Claude Code returned an error"])
            } else {
                // Without partial messages the whole answer only arrives here.
                lock.lock(); let streamed = !answer.isEmpty; lock.unlock()
                if !streamed, let text = event["result"] as? String, !text.isEmpty { onEvent("delta", ["text": text]) }
                onEvent("stop", ["reason": event["stop_reason"] as? String ?? "end_turn", "usage": event["usage"] ?? [:]])
            }
        default:
            break
        }
    }

    private func finish(_ kind: String, _ payload: [String: Any]) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        onEvent(kind, payload)
    }
}
