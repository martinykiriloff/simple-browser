import AppKit
import WebKit

/// Developer aid (`--quiet`): a test run that keeps out of the way of the
/// person at the Mac. The app never makes itself active, shows no Dock
/// icon, and keeps its windows beneath everyone else's.
///
/// Without it a self-test takes the keyboard for as long as it runs, and
/// what the person types meanwhile lands in the test's windows: measured,
/// as stray letters in a field under test, and as a ⌘T and a ⌘W among the
/// menu items a test saw fire.
@MainActor
enum QuietMode {
    static let isOn = CommandLine.arguments.contains("--quiet")

    static func activate() {
        guard !isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// For every web view the app makes. Beneath other windows a page is
    /// occluded, WebKit tells it it is hidden, and (measured) a hidden page's
    /// requests for the camera or for the location wait, unanswered, until
    /// it is shown. So a quiet run's pages are told they are visible.
    static func apply(to webView: WKWebView) {
        guard isOn else { return }
        let setter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: setter), let method = webView.method(for: setter) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Set.self)(webView, setter, false)
    }

    /// For every window the app makes.
    static func apply(to window: NSWindow?) {
        guard isOn, let window else { return }
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior.insert(.stationary)
    }
}
