import AppKit
import WebKit

/// The page web view, with an "Inspect Element" context-menu item that opens
/// our DevTools on the element under the pointer.
final class BrowserWebView: WKWebView {

    /// Receives the click location in CSS pixels.
    var onInspectElement: ((CGPoint) -> Void)?
    private var contextPoint: CGPoint = .zero

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        contextPoint = convert(event.locationInWindow, from: nil)

        // WebKit adds its own item that opens the WebKit inspector; ours
        // replaces it.
        for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" {
            menu.removeItem(item)
        }
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
        let item = NSMenuItem(title: "Inspect Element", action: #selector(inspectElement(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func inspectElement(_ sender: Any?) {
        var point = contextPoint
        if !isFlipped { point.y = bounds.height - point.y }
        let zoom = pageZoom > 0 ? pageZoom : 1
        onInspectElement?(CGPoint(x: point.x / zoom, y: point.y / zoom))
    }
}
