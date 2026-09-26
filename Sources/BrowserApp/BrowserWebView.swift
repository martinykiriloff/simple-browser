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

    /// A point in this view's coordinates, in the page's CSS pixels.
    func cssPoint(_ viewPoint: CGPoint) -> CGPoint {
        var viewPoint = viewPoint
        if !isFlipped { viewPoint.y = bounds.height - viewPoint.y }
        let zoom = pageZoom > 0 ? pageZoom : 1
        return CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom)
    }
}
