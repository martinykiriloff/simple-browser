import Foundation
import BrowserKit

/// Everything the dev tools observe, from any source, arrives as one of these.
public enum InspectorEvent: Sendable {
    case console(ConsoleEntry)
    case network(NetworkEvent)
    case dom(DOMMutationBatch)
    case performance(PerformanceEntry)
    case navigation(NavigationEvent)

    public var kind: Kind {
        switch self {
        case .console:     return .console
        case .network:     return .network
        case .dom:         return .dom
        case .performance: return .performance
        case .navigation:  return .navigation
        }
    }

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case console, network, dom, performance, navigation
    }
}

/// Where an observation came from. Kept on every event because the sources
/// disagree, and the UI must be able to say so rather than quietly presenting
/// a partial picture as complete.
public enum EventSource: String, Sendable, Codable {
    /// Injected agent running in an isolated `WKContentWorld`. Tamper-proof.
    /// Sees the DOM, uncaught exceptions and the full resource-timing
    /// inventory; blind to headers, bodies and request methods.
    case agent
    /// Hooks injected into the page world. Sees console output and the
    /// status, headers and bodies of fetch / XHR traffic -- but page script
    /// can in principle detect or replace them.
    case pageWorld
    /// Loopback proxy via `WKWebsiteDataStore.proxyConfigurations`. Sees every
    /// request including ones the page never exposes; no bodies without MITM.
    case proxy
    /// `WKNavigationDelegate` / `WKDownloadDelegate`.
    case navigationDelegate
    /// The app's own loader in instrumented mode (`loadSimulatedRequest`).
    case loader
    /// Typed by the developer into the recorder's console.
    case user
    /// WebKit's inspector protocol, available while DevTools is attached.
    /// Authoritative for status, headers and bodies of every resource.
    case inspector

    /// Whether page script could have forged or suppressed this observation.
    public var isTamperable: Bool { self == .pageWorld }
}

public struct ConsoleEntry: Sendable, Codable, Identifiable {
    public let id: UUID
    public var level: Level
    /// `log`, `dir`, `table`, `group`, `groupCollapsed`, `groupEnd`, `clear`,
    /// `assert`, `trace`, `result` (a value returned to the console prompt),
    /// `command` (what was typed into the prompt).
    public var type: String
    public var message: String
    /// The original arguments as remote objects, so a UI can expand them
    /// lazily the way Chrome's console does. Empty for native-side entries.
    public var args: [RemoteObject]
    public var stack: [StackFrame]
    public var timestamp: Date
    /// Set for uncaught exceptions and unhandled rejections.
    public var isUncaught: Bool
    /// Tabular rendering for `console.table`, already flattened to text.
    public var table: ConsoleTable?

    public enum Level: String, Sendable, Codable {
        case debug, info, warn, error, trace
    }

    public init(id: UUID = UUID(), level: Level, type: String = "log", message: String,
                args: [RemoteObject] = [], stack: [StackFrame] = [], timestamp: Date = .now,
                isUncaught: Bool = false, table: ConsoleTable? = nil) {
        self.id = id; self.level = level; self.type = type; self.message = message
        self.args = args; self.stack = stack; self.timestamp = timestamp; self.isUncaught = isUncaught
        self.table = table
    }
}

public struct ConsoleTable: Sendable, Codable {
    public var columns: [String]
    public var rows: [[String]]
    /// Rows beyond the agent's cap that were not sent.
    public var truncatedRows: Int

    public init(columns: [String], rows: [[String]], truncatedRows: Int = 0) {
        self.columns = columns; self.rows = rows; self.truncatedRows = truncatedRows
    }
}

/// A value living in the page, described well enough to render and expand
/// lazily. Mirrors the shape Chrome's protocol uses so the UI can treat
/// console arguments and evaluation results uniformly.
public struct RemoteObject: Sendable, Codable {
    /// `object`, `function`, `string`, `number`, `boolean`, `undefined`, `symbol`, `bigint`
    public var type: String
    /// `array`, `null`, `node`, `error`, `date`, `regexp`, `map`, `set`, `promise`, `typedarray`…
    public var subtype: String?
    public var className: String?
    public var description: String
    /// Present for objects and functions; resolves through `Runtime.getProperties`.
    public var objectId: String?
    public var preview: Preview?

    public struct Preview: Sendable, Codable {
        public var properties: [Property]
        public var overflow: Bool
        public init(properties: [Property], overflow: Bool) {
            self.properties = properties; self.overflow = overflow
        }
        public struct Property: Sendable, Codable {
            public var name: String
            public var type: String
            public var subtype: String?
            public var value: String
            public init(name: String, type: String, subtype: String? = nil, value: String) {
                self.name = name; self.type = type; self.subtype = subtype; self.value = value
            }
        }
    }

    public init(type: String, subtype: String? = nil, className: String? = nil, description: String,
                objectId: String? = nil, preview: Preview? = nil) {
        self.type = type; self.subtype = subtype; self.className = className
        self.description = description; self.objectId = objectId; self.preview = preview
    }
}

public struct StackFrame: Sendable, Codable, Hashable {
    public var functionName: String?
    public var url: URL?
    public var line: Int
    public var column: Int
    /// Populated after source-map resolution; the location the developer wrote.
    public var originalLocation: SourceLocation?

    public init(functionName: String? = nil, url: URL? = nil,
                line: Int, column: Int, originalLocation: SourceLocation? = nil) {
        self.functionName = functionName; self.url = url
        self.line = line; self.column = column
        self.originalLocation = originalLocation
    }
}

public struct SourceLocation: Sendable, Codable, Hashable {
    public var file: String
    public var line: Int
    public var column: Int
    public init(file: String, line: Int, column: Int) {
        self.file = file; self.line = line; self.column = column
    }
}

public struct NetworkEvent: Sendable, Codable, Identifiable {
    public let id: UUID
    public var source: EventSource
    /// Unknown for resource-timing observations, which do not carry a method.
    public var method: String?
    public var url: URL
    /// `fetch`, `xmlhttprequest`, `img`, `script`, `css`, `link`, `navigation`…
    public var initiator: String?
    public var statusCode: Int?
    public var requestHeaders: [String: String]
    public var responseHeaders: [String: String]
    public var requestBody: String?
    /// Inline body while a recording lives in memory. Persisted recordings
    /// move bodies to `responseBodyRef`.
    public var responseBody: String?
    /// Nil when the source could not observe a body (proxy without MITM,
    /// resource timing, binary payloads).
    public var responseBodyRef: AssetRef?
    public var bodyUnavailable: Bool
    public var failure: String?
    public var startedAt: Date
    public var duration: TimeInterval?
    public var bytesReceived: Int64?
    /// Decoded body size when known separately from bytes on the wire.
    public var decodedBodySize: Int64?
    public var protocolName: String?
    /// Resource-timing phases, from the isolated-world agent only.
    public var timing: NetworkTiming?
    /// Set once agent and proxy observations of the same request are merged.
    public var correlationID: UUID?
    /// The inspector protocol's id for this request; the key for fetching
    /// its body on demand.
    public var protocolRequestID: String?
    /// `document`, `stylesheet`, `script`… when the source knows it outright.
    public var resourceTypeHint: String?

    public init(
        id: UUID = UUID(), source: EventSource, method: String? = nil, url: URL,
        initiator: String? = nil, statusCode: Int? = nil,
        requestHeaders: [String: String] = [:], responseHeaders: [String: String] = [:],
        requestBody: String? = nil, responseBody: String? = nil,
        responseBodyRef: AssetRef? = nil, bodyUnavailable: Bool = false,
        failure: String? = nil, startedAt: Date = .now, duration: TimeInterval? = nil,
        bytesReceived: Int64? = nil, decodedBodySize: Int64? = nil, protocolName: String? = nil,
        timing: NetworkTiming? = nil, correlationID: UUID? = nil,
        protocolRequestID: String? = nil, resourceTypeHint: String? = nil
    ) {
        self.protocolRequestID = protocolRequestID
        self.resourceTypeHint = resourceTypeHint
        self.id = id; self.source = source; self.method = method; self.url = url
        self.initiator = initiator; self.statusCode = statusCode
        self.requestHeaders = requestHeaders; self.responseHeaders = responseHeaders
        self.requestBody = requestBody; self.responseBody = responseBody
        self.responseBodyRef = responseBodyRef; self.bodyUnavailable = bodyUnavailable
        self.failure = failure; self.startedAt = startedAt; self.duration = duration
        self.bytesReceived = bytesReceived; self.decodedBodySize = decodedBodySize
        self.protocolName = protocolName; self.timing = timing
        self.correlationID = correlationID
    }

    public var isFailure: Bool {
        if failure != nil { return true }
        if let status = statusCode, status >= 400 { return true }
        return false
    }
}

/// Milliseconds from the request's own start, as resource timing reports them.
/// Zero means the phase did not happen or was hidden (cross-origin without
/// `Timing-Allow-Origin`).
public struct NetworkTiming: Sendable, Codable {
    public var fetchStart: Double
    public var domainLookupStart: Double
    public var domainLookupEnd: Double
    public var connectStart: Double
    public var secureConnectionStart: Double
    public var connectEnd: Double
    public var requestStart: Double
    public var responseStart: Double
    public var responseEnd: Double

    public init(fetchStart: Double = 0, domainLookupStart: Double = 0, domainLookupEnd: Double = 0,
                connectStart: Double = 0, secureConnectionStart: Double = 0, connectEnd: Double = 0,
                requestStart: Double = 0, responseStart: Double = 0, responseEnd: Double = 0) {
        self.fetchStart = fetchStart; self.domainLookupStart = domainLookupStart
        self.domainLookupEnd = domainLookupEnd; self.connectStart = connectStart
        self.secureConnectionStart = secureConnectionStart; self.connectEnd = connectEnd
        self.requestStart = requestStart; self.responseStart = responseStart
        self.responseEnd = responseEnd
    }
}

public struct DOMMutation: Sendable, Codable {
    public var nodeID: Int
    public var kind: Kind
    /// `div#main.hero` style description of the mutation target.
    public var target: String
    public var attribute: String?
    public var addedNodes: Int
    public var removedNodes: Int

    public enum Kind: String, Sendable, Codable {
        case childList, attributes, characterData
    }

    public init(nodeID: Int, kind: Kind, target: String = "", attribute: String? = nil,
                addedNodes: Int = 0, removedNodes: Int = 0) {
        self.nodeID = nodeID; self.kind = kind; self.target = target
        self.attribute = attribute; self.addedNodes = addedNodes; self.removedNodes = removedNodes
    }
}

/// One animation frame's worth of mutations. The agent caps the batch and
/// reports how many records it dropped, so the count is always honest.
public struct DOMMutationBatch: Sendable, Codable {
    public var mutations: [DOMMutation]
    public var dropped: Int
    public var timestamp: Date

    public init(mutations: [DOMMutation], dropped: Int = 0, timestamp: Date = .now) {
        self.mutations = mutations; self.dropped = dropped; self.timestamp = timestamp
    }

    public var total: Int { mutations.count + dropped }
}

public struct PerformanceEntry: Sendable, Codable {
    public var name: String
    public var entryType: String
    public var startTime: Double
    public var duration: Double
    /// Layout-shift score, LCP element size, and similar per-type extras.
    public var value: Double?
    public var detail: String?

    public init(name: String, entryType: String, startTime: Double, duration: Double,
                value: Double? = nil, detail: String? = nil) {
        self.name = name; self.entryType = entryType
        self.startTime = startTime; self.duration = duration
        self.value = value; self.detail = detail
    }
}

public struct NavigationEvent: Sendable, Codable {
    public var url: URL
    public var phase: Phase
    public var timestamp: Date
    public var detail: String?

    public enum Phase: String, Sendable, Codable {
        case started, redirected, committed, finished, failed
        /// The isolated-world agent reported in for a new document.
        case agentReady
    }

    public init(url: URL, phase: Phase, timestamp: Date = .now, detail: String? = nil) {
        self.url = url; self.phase = phase; self.timestamp = timestamp; self.detail = detail
    }
}

// MARK: - Codable

/// Encoded as `{ "kind": "network", "network": { … } }` rather than the
/// synthesized `{ "network": { "_0": { … } } }`, so exported recordings are
/// readable and stable across Swift versions.
extension InspectorEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, console, network, dom, performance, navigation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .console:     self = .console(try container.decode(ConsoleEntry.self, forKey: .console))
        case .network:     self = .network(try container.decode(NetworkEvent.self, forKey: .network))
        case .dom:         self = .dom(try container.decode(DOMMutationBatch.self, forKey: .dom))
        case .performance: self = .performance(try container.decode(PerformanceEntry.self, forKey: .performance))
        case .navigation:  self = .navigation(try container.decode(NavigationEvent.self, forKey: .navigation))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .console(let e):     try container.encode(e, forKey: .console)
        case .network(let e):     try container.encode(e, forKey: .network)
        case .dom(let e):         try container.encode(e, forKey: .dom)
        case .performance(let e): try container.encode(e, forKey: .performance)
        case .navigation(let e):  try container.encode(e, forKey: .navigation)
        }
    }
}
