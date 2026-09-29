import AppKit

/// Sites' icons, for the sidebar, pinned tabs and ⌘K. Fetched once per site
/// with no cookies and kept in memory; until one arrives, or where a site
/// has none, a tile with the site's first letter stands in.
@MainActor
final class Favicons {
    static let shared = Favicons()
    static let didLoad = Notification.Name("Favicons.didLoad")

    private var images: [String: NSImage] = [:]
    private var asked: Set<String> = []
    private let session = URLSession(configuration: .ephemeral)

    /// The site's icon, or its letter.
    func icon(for url: URL?, title: String) -> NSImage {
        if let url, StartPageSchemeHandler.isStartPage(url) {
            return NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) ?? Self.monogram("S", for: url)
        }
        if let host = url?.host(), let image = images[host] { return image }
        let name = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? title
        return Self.monogram(name.first.map(String.init)?.uppercased() ?? "•", for: url)
    }

    /// Fetches the icon a page names, or the site's /favicon.ico.
    func load(_ iconURL: URL?, for page: URL) {
        guard let host = page.host(), page.scheme?.hasPrefix("http") == true, !asked.contains(host) else { return }
        asked.insert(host)
        guard let source = iconURL ?? URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL,
              source.scheme?.hasPrefix("http") == true else { return }
        var request = URLRequest(url: source, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        let session = session
        Task { [weak self] in
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
                  let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return }
            image.size = NSSize(width: 16, height: 16)
            self?.images[host] = image
            NotificationCenter.default.post(name: Self.didLoad, object: nil)
        }
    }

    /// A rounded tile with a letter, coloured by the site so each is told apart.
    static func monogram(_ letter: String, for url: URL?) -> NSImage {
        let palette: [NSColor] = [.systemBlue, .systemRed, .systemOrange, .systemGreen, .systemTeal, .systemPurple, .systemPink, .systemIndigo, .systemBrown]
        let seed = (url?.host() ?? letter).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let color = palette[seed % palette.count]
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }
}
