import AppKit
import WebKit

/// The page web view. Its context menu is WebKit's, rewritten by
/// `PageContextMenu` into the one Safari and Chrome show.
final class BrowserWebView: WKWebView {

    /// Set by the window controller.
    weak var contextMenu: PageContextMenu?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            contextMenu?.lastPoint = point
            contextMenu?.rewrite(menu)
        }
    }

    // MARK: - Human input, for DevTools' actor tags

    /// When the person last clicked, typed or scrolled in the page (ms since
    /// 1970), newest last. Events an agent synthesizes are not counted: they
    /// reach the view directly, not through the app's event dispatch.
    private(set) var humanInputTimes: [Double] = []
    /// Told of each human input (at most every 250 ms); set by DevTools.
    var onHumanInput: ((Double) -> Void)?

    override func mouseDown(with event: NSEvent) { noteHumanInput(event); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { noteHumanInput(event); super.rightMouseDown(with: event) }
    override func keyDown(with event: NSEvent) { noteHumanInput(event); super.keyDown(with: event) }
    override func scrollWheel(with event: NSEvent) { noteHumanInput(event); super.scrollWheel(with: event) }

    private func noteHumanInput(_ event: NSEvent) {
        guard let current = NSApp.currentEvent, current === event || (current.type == event.type && current.timestamp == event.timestamp) else { return }
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        if let last = humanInputTimes.last, now - last < 250 { return }
        humanInputTimes.append(now)
        if humanInputTimes.count > 500 { humanInputTimes.removeFirst(humanInputTimes.count - 500) }
        onHumanInput?(now)
    }

    /// A point in this view's coordinates, in the page's CSS pixels.
    func cssPoint(_ viewPoint: CGPoint) -> CGPoint {
        var viewPoint = viewPoint
        if !isFlipped { viewPoint.y = bounds.height - viewPoint.y }
        let zoom = pageZoom > 0 ? pageZoom : 1
        return CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom)
    }
}
