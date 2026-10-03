import Foundation

/// One HTTP/1.1 request, as much of it as a local MCP endpoint needs.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// The path without the query string.
    public var path: String
    public var query: String?
    /// Header names lowercased; repeated headers joined with ", ".
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: String? = nil, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Incremental request parsing: feed it what has arrived so far.
public enum HTTPRequestParser {
    public enum Result: Sendable, Equatable {
        case incomplete
        /// The request, and how many bytes of the buffer it took.
        case complete(HTTPRequest, consumed: Int)
        /// The status to answer with before closing.
        case invalid(status: Int, reason: String)
    }

    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 32 * 1024 * 1024

    public static func parse(_ buffer: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431, reason: "Headers too large") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, reason: "Headers are not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400, reason: "Malformed request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400, reason: "Malformed header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid(status: 411, reason: "Chunked bodies are not supported; send Content-Length")
        }
        let length: Int
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else { return .invalid(status: 400, reason: "Bad Content-Length") }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .invalid(status: 413, reason: "Body too large") }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let target = String(requestLine[1])
        let path: String
        let query: String?
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark]); query = String(target[target.index(after: mark)...])
        } else {
            path = target; query = nil
        }
        let request = HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers,
                                  body: Data(buffer[bodyStart..<(bodyStart + length)]))
        return .complete(request, consumed: bodyStart + length - buffer.startIndex)
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body && lhs.headers.map { $0.0 + ":" + $0.1 } == rhs.headers.map { $0.0 + ":" + $0.1 }
    }

    public static func json(_ value: JSONValue, status: Int = 200, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: value.encoded())
    }

    public static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
    }

    public func serialized(keepAlive: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// Who may talk to the local agent endpoint. It drives a browser signed in
/// to the person's accounts, so: loopback only, a bearer token unless the
/// person turned that off, and never a web page (DNS rebinding, or a page on
/// another port posting to it).
public struct AgentAccessPolicy: Sendable {
    public var token: String?
    public var port: Int

    public init(token: String?, port: Int) {
        self.token = token; self.port = port
    }

    public enum Denial: Sendable, Equatable {
        case badHost(String)
        case foreignOrigin(String)
        case missingToken
        case wrongToken

        public var status: Int {
            switch self {
            case .badHost, .foreignOrigin: return 403
            case .missingToken, .wrongToken: return 401
            }
        }

        public var message: String {
            switch self {
            case .badHost(let host): return "Host \(host) is not this machine's loopback address"
            case .foreignOrigin(let origin): return "Requests from web pages are refused (Origin: \(origin))"
            case .missingToken: return "Missing Authorization: Bearer <token>. Pair this client with `keel pair`, or Keel → Agent → Pair a New Agent…."
            case .wrongToken: return "Wrong token. Copy the current one from Keel → Settings → Developer."
            }
        }
    }

    public func check(_ request: HTTPRequest) -> Denial? {
        let host = request.header("host") ?? ""
        let allowedHosts = ["127.0.0.1", "localhost", "[::1]"].flatMap { [$0, "\($0):\(port)"] }
        guard allowedHosts.contains(host.lowercased()) else { return .badHost(host) }
        // Command-line clients send no Origin; a web page always does. With a
        // token, a tool served from this machine (an MCP inspector on
        // localhost) may call in, since a page cannot know the token. Without
        // one, nothing a browser loads gets through.
        let hasToken = !(token ?? "").isEmpty
        if let origin = request.header("origin"), !origin.isEmpty {
            guard hasToken, Self.isLoopback(origin: origin) else { return .foreignOrigin(origin) }
        }
        guard let token, hasToken else { return nil }
        guard let authorization = request.header("authorization") else { return .missingToken }
        let prefix = "bearer "
        guard authorization.lowercased().hasPrefix(prefix) else { return .missingToken }
        let presented = String(authorization.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return Self.constantTimeEquals(presented, token) ? nil : .wrongToken
    }

    /// Host and Origin only: the request comes from this machine and not from
    /// a web page on another origin. Who is calling is the token's business.
    public func checkTransport(_ request: HTTPRequest) -> Denial? {
        let host = request.header("host") ?? ""
        let allowedHosts = ["127.0.0.1", "localhost", "[::1]"].flatMap { [$0, "\($0):\(port)"] }
        guard allowedHosts.contains(host.lowercased()) else { return .badHost(host) }
        if let origin = request.header("origin"), !origin.isEmpty, !Self.isLoopback(origin: origin) { return .foreignOrigin(origin) }
        return nil
    }

    static func isLoopback(origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }

    /// 32 random bytes, URL-safe base64.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
