import AppKit

/// Sites' icons, for the sidebar, pinned tabs and ⌘K. Fetched once per site
/// with no cookies and kept in memory; until one arrives, or where a site
/// has none, a tile with the site's first letter stands in.
///
/// The address of the icon is the page's word, so it is taken as no more
/// than that. The fetch is made here, outside WebKit, where neither the
/// compiled blocking rules nor WebKit's rules about mixed content reach:
/// so an https page cannot send it to http, it never goes to this Mac or
/// to the network this Mac is on, and only so much of a reply is read.
/// What is fetched while browsing privately is kept apart from what
/// ordinary windows show, and goes with the last private window.
@MainActor
final class Favicons {
    static let shared = Favicons()
    static let didLoad = Notification.Name("Favicons.didLoad")

    /// How much of a reply is read before it is given up on.
    static let sizeLimit = 1_000_000
    /// How many sites are remembered before the lists are let go of: a long
    /// session touches thousands, and an icon is cheap to fetch again.
    static let hostLimit = 2_000

    /// Private browsing keeps its own icons: an icon shown in an ordinary
    /// window is a record of a visit, and that visit was nobody's business.
    private enum Scope: Hashable { case ordinary, `private` }

    private var images: [Scope: [String: NSImage]] = [:]
    private var asked: [Scope: Set<String>] = [:]
    private let session = URLSession(configuration: .ephemeral)

    /// The site's icon, or its letter.
    func icon(for url: URL?, title: String) -> NSImage {
        if let url, StartPageSchemeHandler.isStartPage(url) {
            return NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) ?? Self.monogram("S", for: url)
        }
        forgetPrivateBrowsing()
        if let host = url?.host(), let image = images[scope(of: host)]?[host] { return image }
        let name = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? title
        return Self.monogram(name.first.map(String.init)?.uppercased() ?? "•", for: url)
    }

    /// Fetches the icon a page names, or the site's /favicon.ico.
    func load(_ iconURL: URL?, for page: URL) {
        forgetPrivateBrowsing()
        guard let host = page.host(), let pageScheme = page.scheme?.lowercased(),
              pageScheme == "http" || pageScheme == "https" else { return }
        let scope = scope(of: host)
        if asked[scope, default: []].count > Self.hostLimit { asked[scope] = [] }
        guard !(asked[scope]?.contains(host) ?? false) else { return }
        asked[scope, default: []].insert(host)
        guard let source = iconURL ?? URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL,
              let scheme = source.scheme?.lowercased(), scheme == "http" || scheme == "https",
              // No downgrade: a page served over https must not be able to
              // put a cleartext request on the network through the browser.
              !(pageScheme == "https" && scheme != "https"),
              let iconHost = source.host(percentEncoded: false), !Self.isLocalOrPrivate(iconHost) else { return }
        var request = URLRequest(url: source, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        let session = session
        let limit = Self.sizeLimit
        Task { [weak self] in
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
                    bytes.task.cancel()
                    self?.giveUp(on: host, in: scope)
                    return
                }
                // Cut off as it arrives, not after: the address came from
                // the page, and a page could name one that never stops.
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    guard data.count <= limit else {
                        bytes.task.cancel()
                        self?.giveUp(on: host, in: scope)
                        return
                    }
                }
                guard let image = NSImage(data: data), image.isValid, image.size.width > 0 else {
                    self?.giveUp(on: host, in: scope)
                    return
                }
                image.size = NSSize(width: 16, height: 16)
                self?.keep(image, for: host, in: scope)
            } catch {
                self?.giveUp(on: host, in: scope)
            }
        }
    }

    private func keep(_ image: NSImage, for host: String, in scope: Scope) {
        if images[scope, default: [:]].count > Self.hostLimit { images[scope] = [:] }
        images[scope, default: [:]][host] = image
        NotificationCenter.default.post(name: Self.didLoad, object: nil)
    }

    /// Nothing came of it: the site is forgotten rather than remembered as
    /// asked, so a later visit can try again.
    private func giveUp(on host: String, in scope: Scope) {
        asked[scope]?.remove(host)
    }

    // MARK: - Private browsing, and the profiles

    /// Which icons a host's belong among. A host only private windows have
    /// open is private browsing's; where an ordinary window has it open
    /// too, that window would fetch the same icon itself, so there is
    /// nothing to keep apart.
    private func scope(of host: String) -> Scope {
        let showing = (NSApp.delegate as? AppDelegate)?.browserControllers.filter { $0.currentURL?.host() == host } ?? []
        guard !showing.isEmpty else { return .ordinary }
        return showing.contains { !$0.isPrivate } ? .ordinary : .private
    }

    /// What was fetched privately does not outlive the last private window.
    private func forgetPrivateBrowsing() {
        guard images[.private] != nil || asked[.private] != nil else { return }
        guard (NSApp.delegate as? AppDelegate)?.browserControllers.contains(where: \.isPrivate) != true else { return }
        images[.private] = nil
        asked[.private] = nil
    }

    // MARK: - Where an icon may come from

    /// This Mac, and the network it is on. A page naming such an address
    /// would be reaching a printer, a router or something listening on
    /// localhost through the browser, where nothing else can see it.
    static func isLocalOrPrivate(_ host: String) -> Bool {
        let name = host.lowercased()
        if name.isEmpty || name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local")
            || name.hasSuffix(".internal") || name.hasSuffix(".home.arpa") { return true }
        let literal = name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name
        if literal.contains(":") {
            if literal == "::" || literal == "::1" { return true }
            // Link-local (fe80::/10) and unique local (fc00::/7).
            if ["fe8", "fe9", "fea", "feb"].contains(where: literal.hasPrefix) || literal.hasPrefix("fc") || literal.hasPrefix("fd") { return true }
            // "::ffff:127.0.0.1": the address written inside decides.
            if let mapped = literal.split(separator: ":").last, mapped.contains(".") { return isLocalOrPrivate(String(mapped)) }
            return false
        }
        let parts = literal.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, !parts.contains(nil) else { return false }   // a name, not an address
        let bytes = parts.compactMap { $0 }
        switch (bytes[0], bytes[1]) {
        case (0, _), (127, _), (10, _): return true           // unspecified, this Mac, private
        case (169, 254): return true                          // link-local
        case (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true                     // between a carrier's customers
        default: return false
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
