import AppKit
import WebKit
import BrowserKit

/// What the private windows of one profile share, and all that remains of
/// them: a website data store that exists only in memory. When the last
/// private tab closes the session is let go, and with it every cookie,
/// cache entry and stored item those tabs made.
///
/// Settings a normal window would remember by site (zoom, blocking switched
/// off) are kept here instead, so they last for the private session and
/// leave no record of which sites were visited.
@MainActor
final class PrivateSession {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    var zoomLevels: [String: Double] = [:]
    var blockingOffSites: [String] = []
    var permissions = SitePermissions()
    var certificateExceptions = CertificateExceptions()
    /// Open private tabs.
    var tabs = 0
}

/// "Private", in the toolbar of a private window, where a profile's colour
/// would be: it cannot be taken for a profile.
@MainActor
enum PrivateBadge {
    static func view() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let label = NSTextField(labelWithString: "Private")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .white
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 11)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.62, alpha: 1).cgColor
        stack.layer?.cornerRadius = 11
        stack.toolTip = "Private window: nothing you visit here is kept in history, the session, or on disk."
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.staticText)
        stack.setAccessibilityLabel("Private window")
        return stack
    }
}
