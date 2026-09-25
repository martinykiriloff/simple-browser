import WebKit
import BrowserKit
import InspectKit

/// The WebKit-facing half of the injected agent: installs the scripts into
/// their worlds, receives their messages, and feeds the recorder.
///
/// One bridge per web view. The message source is taken from the *handler*
/// each message arrived on, never from the payload -- page script can post
/// anything to the page-world handler but cannot reach the isolated one.
@MainActor
final class InspectorBridge: NSObject, WKScriptMessageHandler {

    let recorder: InspectorRecorder
    let tab: TabID
    private(set) var installError: (any Error)?
    /// Messages that are not recorder events: element-picker results,
    /// clipboard requests from the console's `copy()`.
    var onAuxiliaryMessage: ((_ kind: String, _ body: [String: Any], _ source: EventSource) -> Void)?

    private let isolatedWorld = WKContentWorld.world(name: InspectorAgent.isolatedWorldName)
    private weak var userContentController: WKUserContentController?

    init(recorder: InspectorRecorder, tab: TabID) {
        self.recorder = recorder
        self.tab = tab
    }

    /// Call before the web view is created so the scripts run for the very
    /// first document; the message handlers are removed in `uninstall()` to
    /// break the retain cycle WebKit otherwise keeps to `self`.
    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        let token = tab.rawValue.uuidString

        controller.add(self, contentWorld: isolatedWorld, name: InspectorAgent.isolatedHandlerName)
        controller.add(self, contentWorld: .page, name: InspectorAgent.pageHandlerName)

        for script in InspectorAgent.Script.allCases {
            do {
                let source = try InspectorAgent.source(for: script, tabToken: token)
                controller.addUserScript(WKUserScript(
                    source: source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                    in: script.isIsolated ? isolatedWorld : .page
                ))
            } catch {
                installError = error
            }
        }
    }

    func uninstall() {
        guard let controller = userContentController else { return }
        controller.removeScriptMessageHandler(forName: InspectorAgent.isolatedHandlerName, contentWorld: isolatedWorld)
        controller.removeScriptMessageHandler(forName: InspectorAgent.pageHandlerName, contentWorld: .page)
        controller.removeAllUserScripts()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let source: EventSource
        switch message.name {
        case InspectorAgent.isolatedHandlerName: source = .agent
        case InspectorAgent.pageHandlerName:     source = .pageWorld
        default: return
        }
        let events = InspectorMessageDecoder.decode(message.body, source: source)
        if !events.isEmpty {
            recorder.record(events, tab: tab)
            return
        }
        if let body = message.body as? [String: Any], let kind = body["kind"] as? String {
            onAuxiliaryMessage?(kind, body, source)
        }
    }
}
