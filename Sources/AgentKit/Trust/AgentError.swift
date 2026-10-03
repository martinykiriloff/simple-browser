import Foundation

/// A machine-readable failure (AR-5): what went wrong, and whether trying
/// again later can work. Sent as `structuredContent.error` beside the text.
public struct AgentError: Error, Sendable, Equatable {
    public enum Code: String, Sendable, CaseIterable {
        case invalidArguments = "invalid_arguments"
        case unknownTool = "unknown_tool"
        case noTab = "no_tab"
        case elementNotFound = "element_not_found"
        case elementCovered = "element_covered"
        case navigationFailed = "navigation_failed"
        case timeout = "timeout"
        case dialogOpen = "dialog_open"
        case approvalDenied = "approval_denied"
        case approvalTimeout = "approval_timeout"
        case originBlocked = "origin_blocked"
        case budgetExhausted = "budget_exhausted"
        case rateLimited = "rate_limited"
        case sessionPaused = "session_paused"
        case sessionStopped = "session_stopped"
        case sessionExpired = "session_expired"
        case needsHuman = "needs_human"
        case unsupported = "unsupported"
        case scriptError = "script_error"
        case internalError = "internal"

        /// Whether the same call can succeed later without changing it.
        public var retryable: Bool {
            switch self {
            case .elementNotFound, .elementCovered, .navigationFailed, .timeout, .dialogOpen,
                 .rateLimited, .sessionPaused, .needsHuman, .approvalTimeout:
                return true
            case .invalidArguments, .unknownTool, .noTab, .approvalDenied, .originBlocked, .budgetExhausted,
                 .sessionStopped, .sessionExpired, .unsupported, .scriptError, .internalError:
                return false
            }
        }
    }

    public var code: Code
    public var message: String
    public var retryAfterMs: Int?

    public init(_ code: Code, _ message: String, retryAfterMs: Int? = nil) {
        self.code = code; self.message = message; self.retryAfterMs = retryAfterMs
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message), "retryable": .bool(code.retryable)]
        if let retryAfterMs { object["retryAfterMs"] = .number(Double(retryAfterMs)) }
        return .object(object)
    }

    public var result: MCPToolResult {
        MCPToolResult([.text("Error [\(code.rawValue)\(code.retryable ? ", retryable" : "")]: \(message)")], isError: true,
                      structured: ["ok": false, "error": json])
    }

    /// Best guess at a code for a plain message from older code paths.
    public static func classify(_ message: String) -> Code {
        let text = message.lowercased()
        if text.contains("no element") || text.contains("not found") && text.contains("ref") || text.contains("stale") { return .elementNotFound }
        if text.contains("covered by") || text.contains("is covered") { return .elementCovered }
        if text.contains("timed out") || text.contains("timeout") { return .timeout }
        if text.contains("no tab with id") || text.contains("no browser window") { return .noTab }
        if text.contains("dialog") && text.contains("open") { return .dialogOpen }
        if text.contains("not supported") || text.contains("unsupported") || text.contains("not available in this") { return .unsupported }
        if text.contains("must be") || text.contains("needs ") || text.contains("missing") { return .invalidArguments }
        if text.contains("javascript") || text.contains("exception") { return .scriptError }
        return .internalError
    }
}
