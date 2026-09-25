import Foundation

/// One row of a Network panel: the best available picture of a request,
/// merged from every source that observed it.
///
/// The isolated-world agent sees every resource with timing and sizes but no
/// method, status or body; the page-world hooks see fetch/XHR with status,
/// headers and bodies but nothing else. Merged, a fetch shows up once with
/// all of it -- and `sources` still says who contributed what.
public struct NetworkRequest: Sendable, Codable, Identifiable {
    public let id: UUID
    public var url: URL
    public var method: String?
    public var statusCode: Int?
    public var initiator: String?
    public var mimeType: String?
    /// `document`, `stylesheet`, `script`, `image`, `font`, `media`, `fetch`, `xhr`, `other`
    public var resourceType: String
    public var requestHeaders: [String: String]
    public var responseHeaders: [String: String]
    public var requestBody: String?
    public var responseBody: String?
    /// Body obtained by fetching the URL again from the app, not observed in
    /// the page. May differ from what the page received.
    public var responseBodyIsRefetched: Bool
    public var failure: String?
    public var startedAt: Date
    public var duration: TimeInterval?
    public var transferSize: Int64?
    public var bodySize: Int64?
    public var protocolName: String?
    public var timing: NetworkTiming?
    public var sources: [EventSource]
    public var eventIDs: [UUID]
    /// Present when the inspector protocol saw this request: its body can be
    /// read on demand, exactly as the page received it.
    public var protocolRequestID: String?
    private var resourceTypeHint: String?

    public var isFailure: Bool {
        if failure != nil { return true }
        if let status = statusCode, status >= 400 { return true }
        return false
    }

    init(event: NetworkEvent) {
        id = event.id
        url = event.url
        method = event.method
        statusCode = event.statusCode
        initiator = event.initiator
        mimeType = NetworkRequest.mimeType(from: event.responseHeaders)
        requestHeaders = event.requestHeaders
        responseHeaders = event.responseHeaders
        requestBody = event.requestBody
        responseBody = event.responseBody
        responseBodyIsRefetched = false
        failure = event.failure
        startedAt = event.startedAt
        duration = event.duration
        transferSize = event.source == .agent ? event.bytesReceived : nil
        bodySize = event.source == .agent ? event.decodedBodySize : event.bytesReceived
        protocolName = event.protocolName
        timing = event.timing
        sources = [event.source]
        eventIDs = [event.id]
        protocolRequestID = event.protocolRequestID
        resourceTypeHint = event.resourceTypeHint
        if event.source == .inspector { transferSize = event.bytesReceived; bodySize = event.decodedBodySize }
        resourceType = event.resourceTypeHint
            ?? NetworkRequest.resourceType(url: event.url, mimeType: NetworkRequest.mimeType(from: event.responseHeaders), initiator: event.initiator)
    }

    mutating func merge(_ event: NetworkEvent) {
        if event.source == .inspector {
            // The engine's own account of the request beats anything inferred.
            method = event.method ?? method
            statusCode = event.statusCode ?? statusCode
            if !event.requestHeaders.isEmpty { requestHeaders = event.requestHeaders }
            if !event.responseHeaders.isEmpty { responseHeaders = event.responseHeaders; mimeType = NetworkRequest.mimeType(from: event.responseHeaders) ?? mimeType }
            protocolRequestID = event.protocolRequestID ?? protocolRequestID
            resourceTypeHint = event.resourceTypeHint ?? resourceTypeHint
            if transferSize == nil { transferSize = event.bytesReceived }
            if bodySize == nil { bodySize = event.decodedBodySize }
            protocolName = protocolName ?? event.protocolName
        }
        if method == nil { method = event.method }
        if statusCode == nil { statusCode = event.statusCode }
        if initiator == nil || initiator == "other" { initiator = event.initiator ?? initiator }
        if requestHeaders.isEmpty { requestHeaders = event.requestHeaders }
        if responseHeaders.isEmpty { responseHeaders = event.responseHeaders }
        if requestBody == nil { requestBody = event.requestBody }
        if responseBody == nil { responseBody = event.responseBody }
        if failure == nil { failure = event.failure }
        if event.source == .agent {
            transferSize = event.bytesReceived ?? transferSize
            bodySize = event.decodedBodySize ?? bodySize
            timing = event.timing ?? timing
            protocolName = event.protocolName ?? protocolName
            duration = event.duration ?? duration
            startedAt = event.startedAt
        } else if event.source != .inspector {
            if bodySize == nil { bodySize = event.bytesReceived }
            if duration == nil { duration = event.duration }
        } else if duration == nil {
            duration = event.duration
        }
        if mimeType == nil { mimeType = NetworkRequest.mimeType(from: event.responseHeaders) }
        if !sources.contains(event.source) { sources.append(event.source) }
        eventIDs.append(event.id)
        resourceType = resourceTypeHint ?? NetworkRequest.resourceType(url: url, mimeType: mimeType, initiator: initiator)
    }

    static func mimeType(from headers: [String: String]) -> String? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "content-type" })?.value else { return nil }
        return raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    static func resourceType(url: URL, mimeType: String?, initiator: String?) -> String {
        switch initiator {
        case "navigation", "iframe", "frame": return "document"
        case "fetch":                         return "fetch"
        case "xmlhttprequest":                return "xhr"
        case "img", "image", "input":         return "image"
        case "script":                        return "script"
        case "css":
            // Stylesheets pull in images and fonts too; let the type decide.
            break
        case "link":
            break
        case "video", "audio", "track":       return "media"
        case "beacon", "ping":                return "ping"
        default:                              break
        }
        if let mime = mimeType {
            if mime == "text/html" || mime == "application/xhtml+xml" { return "document" }
            if mime == "text/css" { return "stylesheet" }
            if mime.contains("javascript") || mime == "text/ecmascript" || mime.contains("wasm") { return "script" }
            if mime.hasPrefix("image/") { return "image" }
            if mime.hasPrefix("font/") || mime.contains("font") { return "font" }
            if mime.hasPrefix("audio/") || mime.hasPrefix("video/") { return "media" }
            if mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text/") { return "fetch" }
        }
        switch url.pathExtension.lowercased() {
        case "js", "mjs", "cjs", "wasm":                       return "script"
        case "css":                                            return "stylesheet"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp": return "image"
        case "woff", "woff2", "ttf", "otf", "eot":            return "font"
        case "mp4", "webm", "mp3", "m4a", "ogg", "wav", "m3u8", "ts": return "media"
        case "html", "htm":                                    return "document"
        case "json":                                           return "fetch"
        default:                                               break
        }
        if initiator == "css" { return "other" }
        if initiator == "link" { return "other" }
        return "other"
    }
}

/// Merges `NetworkEvent`s from all sources into `NetworkRequest`s.
///
/// Two observations are the same request when the URL matches, they come
/// from different sources, no source is duplicated, their start times are
/// close, and their initiators do not contradict each other. Either source
/// may arrive first.
@MainActor
public final class NetworkRequestLog {
    public private(set) var requests: [NetworkRequest] = []
    private var indexByID: [UUID: Int] = [:]
    /// How far apart two observations of one request may start.
    public var mergeWindow: TimeInterval = 5

    public init() {}

    public enum Outcome: Sendable {
        case added(NetworkRequest)
        case updated(NetworkRequest)
    }

    @discardableResult
    public func ingest(_ event: NetworkEvent) -> Outcome {
        if let index = mergeCandidate(for: event) {
            requests[index].merge(event)
            indexByID[event.id] = index
            return .updated(requests[index])
        }
        let request = NetworkRequest(event: event)
        requests.append(request)
        indexByID[event.id] = requests.count - 1
        return .added(request)
    }

    public func request(id: UUID) -> NetworkRequest? {
        indexByID[id].map { requests[$0] }
    }

    public func setResponseBody(_ body: String?, refetched: Bool, for id: UUID) -> NetworkRequest? {
        guard let index = indexByID[id] else { return nil }
        requests[index].responseBody = body
        requests[index].responseBodyIsRefetched = refetched
        return requests[index]
    }

    public func clear() {
        requests.removeAll()
        indexByID.removeAll()
    }

    private func mergeCandidate(for event: NetworkEvent) -> Int? {
        let urlString = event.url.absoluteString
        // Search from the end: the partner observation is almost always recent.
        for index in stride(from: requests.count - 1, through: 0, by: -1) {
            let candidate = requests[index]
            if candidate.startedAt.timeIntervalSince(event.startedAt) > mergeWindow { continue }
            if event.startedAt.timeIntervalSince(candidate.startedAt) > mergeWindow { break }
            guard candidate.url.absoluteString == urlString,
                  !candidate.sources.contains(event.source) else { continue }
            if let a = candidate.initiator, let b = event.initiator,
               a != b, a != "other", b != "other" { continue }
            return index
        }
        return nil
    }
}
