import Foundation

/// The seam between the dev-tools UI and however debugging is actually achieved.
///
/// Two implementations are planned:
///
/// - `InstrumentedBackend` -- rewrites JS through the app's own loader, pauses
///   via a synchronous XHR held open by a `WKURLSchemeHandler`, and reads scope
///   through direct `eval` closures. Public API only, so it ships everywhere.
///   Costs roughly 3-10x runtime on instrumented origins.
/// - `InspectorBackend` -- drives `_WKInspector` SPI. No runtime cost and a real
///   JavaScriptCore debugger, but private API: Developer ID builds only.
///
/// `InspectKit` must never import WebKit SPI directly. The backend is injected
/// at startup, which is what keeps the two distributions one codebase.
public protocol DebugBackend: Sendable {
    func setBreakpoint(at location: SourceLocation) async throws -> BreakpointID
    func removeBreakpoint(_ id: BreakpointID) async throws
    func resume() async throws
    func step(_ mode: StepMode) async throws
    func evaluate(_ expression: String, in frame: FrameID) async throws -> RemoteValue
    func callStack() async throws -> [StackFrame]
    var state: AsyncStream<DebuggerState> { get }
}

public struct BreakpointID: Hashable, Sendable { 
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct FrameID: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

public enum StepMode: Sendable { case over, into, out }

public enum DebuggerState: Sendable {
    case detached
    case running
    case paused(reason: PauseReason, at: SourceLocation)
}

public enum PauseReason: Sendable {
    case breakpoint(BreakpointID)
    case step
    case exception(String)
    case debuggerStatement
}

/// A value read out of the paused page. Deliberately shallow -- deep object
/// graphs are fetched lazily by the UI rather than serialized eagerly.
public struct RemoteValue: Sendable, Codable {
    public var type: String
    public var preview: String
    public var objectID: String?
    public init(type: String, preview: String, objectID: String? = nil) {
        self.type = type; self.preview = preview; self.objectID = objectID
    }
}

public enum DebugBackendError: Error, Sendable {
    /// The backend cannot provide this capability in the current build.
    case unsupported(String)
    case notPaused
    case instrumentationFailed(String)
}
