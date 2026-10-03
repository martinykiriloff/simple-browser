import Foundation

/// The scripts that make up the injected agent, and the names the
/// WebKit-facing layer must use to wire them up.
///
/// `InspectKit` has no WebKit dependency, so it hands out source text and
/// names; `BrowserApp` turns them into `WKUserScript` / message handlers.
public enum InspectorAgent {
    /// Name of the isolated `WKContentWorld` the observer runs in.
    public static let isolatedWorldName = "KeelInspector"
    /// Message handler registered in the isolated world only.
    public static let isolatedHandlerName = "inspector"
    /// Message handler registered in the page world only.
    public static let pageHandlerName = "inspectorPage"

    /// Placeholder replaced with the tab token at injection time.
    static let tokenPlaceholder = "__TAB_TOKEN__"

    /// In injection order: the DOM agent must define the node registry
    /// before the observer starts reporting mutations against it.
    public enum Script: String, Sendable, CaseIterable {
        /// Isolated world: DOM tree, CSS, overlay, storage and page commands.
        case domAgent = "dom-agent"
        /// Isolated world: uncaught errors, resource timing, DOM mutations.
        case observer = "agent"
        /// Page world: console, fetch, XMLHttpRequest, remote objects, evaluate.
        case pageHooks = "page-hooks"

        public var isIsolated: Bool { self != .pageHooks }

        public var source: EventSource {
            isIsolated ? .agent : .pageWorld
        }

        public var handlerName: String {
            isIsolated ? InspectorAgent.isolatedHandlerName : InspectorAgent.pageHandlerName
        }
    }

    /// Isolated-world scripts the DevTools inject on first use rather than
    /// at document start. They extend the DOM agent's dispatcher.
    public enum OnDemandScript: String, Sendable {
        /// Audits, accessibility, IndexedDB, Cache Storage, manifest, animations, overlays.
        case tools = "tools-agent"
    }

    public static func onDemandSource(_ script: OnDemandScript) throws -> String {
        guard let url = resourceBundle.url(forResource: script.rawValue, withExtension: "js") else {
            throw LoadError.resourceMissing("\(script.rawValue).js")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public enum LoadError: Error, Sendable {
        case resourceMissing(String)
    }

    /// Script source with the tab token substituted in. The token must be
    /// safe inside a JavaScript string literal; UUID strings are.
    public static func source(for script: Script, tabToken: String) throws -> String {
        try rawSource(for: script)
            .replacingOccurrences(of: tokenPlaceholder, with: tabToken)
    }

    private static func rawSource(for script: Script) throws -> String {
        guard let url = resourceBundle.url(forResource: script.rawValue, withExtension: "js") else {
            throw LoadError.resourceMissing("\(script.rawValue).js")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// SwiftPM's `Bundle.module` only looks beside the executable, which is
    /// wrong inside an `.app`, where the packaging script puts resource
    /// bundles in `Contents/Resources`. Check there first.
    static let resourceBundle: Bundle = {
        let name = "Keel_InspectKit.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }()
}
