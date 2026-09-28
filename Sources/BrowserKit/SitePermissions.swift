import Foundation

/// Something a site can ask to do, and a person can allow or refuse.
public enum SitePermission: String, CaseIterable, Sendable, Codable {
    case camera, microphone, location, notifications, popups, downloads

    public var name: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .popups: return "Pop-up Windows"
        case .downloads: return "Automatic Downloads"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: return "video.fill"
        case .microphone: return "mic.fill"
        case .location: return "location.fill"
        case .notifications: return "bell.fill"
        case .popups: return "macwindow.on.rectangle"
        case .downloads: return "arrow.down.circle.fill"
        }
    }

    /// "… would like to use your camera."
    public func question(site: String) -> String {
        switch self {
        case .camera: return "“\(site)” would like to use your camera."
        case .microphone: return "“\(site)” would like to use your microphone."
        case .location: return "“\(site)” would like to know where you are."
        case .notifications: return "“\(site)” would like to send you notifications."
        case .popups: return "“\(site)” tried to open a pop-up window."
        case .downloads: return "“\(site)” would like to download more than one file."
        }
    }

    /// What sites can ask for today. Notifications are not among them:
    /// measured, a page in an app can be granted the permission, and the
    /// notification it then shows goes nowhere, because WebKit hands page
    /// notifications to a provider only its C API can set. Granting what
    /// cannot be delivered would be a lie, so pages are given no
    /// Notification API at all and fall back as they do in any browser
    /// without one.
    public static let offered: [SitePermission] = [.camera, .microphone, .location, .popups, .downloads]

    /// What happens when nothing was chosen. Pop-ups a page opens by
    /// itself are blocked, with a way to let them through; everything else
    /// is asked about.
    public var asksByDefault: Bool { self != .popups }

    /// Camera and microphone are asked for together by most sites, and
    /// answered together.
    public static func question(for permissions: [SitePermission], site: String) -> String {
        if Set(permissions) == [.camera, .microphone] { return "“\(site)” would like to use your camera and microphone." }
        return permissions.first?.question(site: site) ?? ""
    }
}

public enum PermissionChoice: String, Sendable, Codable, CaseIterable {
    case allow, deny

    public var name: String { self == .allow ? "Allow" : "Don’t Allow" }
}

/// Choices by site. A site is an origin: `https://example.com` and
/// `http://example.com` are different sites here, because a permission
/// given to the first must not be usable by whoever can impersonate the
/// second on an open network.
public struct SitePermissions: Equatable, Sendable, Codable {
    public private(set) var choices: [String: [String: PermissionChoice]] = [:]

    public init() {}

    /// `scheme://host[:port]`, lowercased, default ports left out. Nil for
    /// anything that is not a web page.
    public static func site(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return site(scheme: scheme, host: host, port: url.port)
    }

    /// From what WebKit reports for a frame's security origin (port 0 is
    /// "the scheme's default").
    public static func site(scheme: String, host: String, port: Int?) -> String? {
        let scheme = scheme.lowercased(), host = host.lowercased()
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return nil }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port, port > 0, port != (scheme == "https" ? 443 : 80) else { return "\(scheme)://\(name)" }
        return "\(scheme)://\(name):\(port)"
    }

    /// For showing: the host, with "(not secure)" left to the caller.
    public static func displayName(of site: String) -> String {
        site.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    public func choice(for permission: SitePermission, site: String) -> PermissionChoice? {
        choices[site]?[permission.rawValue]
    }

    /// Nil forgets the choice: the site is asked again.
    public mutating func set(_ choice: PermissionChoice?, for permission: SitePermission, site: String) {
        var forSite = choices[site] ?? [:]
        forSite[permission.rawValue] = choice
        choices[site] = forSite.isEmpty ? nil : forSite
    }

    public mutating func forget(site: String) { choices[site] = nil }

    /// Every site with a choice, by name, each with its choices in the
    /// order permissions are listed.
    public var sites: [(site: String, choices: [(permission: SitePermission, choice: PermissionChoice)])] {
        choices.keys.sorted { Self.displayName(of: $0) < Self.displayName(of: $1) }.map { site in
            (site, SitePermission.allCases.compactMap { permission in
                choices[site]?[permission.rawValue].map { (permission, $0) }
            })
        }
    }

    public var isEmpty: Bool { choices.isEmpty }
}

/// What to do about a request, given what was chosen before and what was
/// allowed once for the page showing.
public enum PermissionDecision: Equatable, Sendable {
    case allow, deny, ask

    public static func decide(_ permissions: [SitePermission], site: String, stored: SitePermissions, allowedOnce: Set<SitePermission> = []) -> PermissionDecision {
        var ask = false
        for permission in permissions {
            switch stored.choice(for: permission, site: site) {
            case .deny: return .deny                       // one refusal refuses the request
            case .allow: continue
            case nil:
                if allowedOnce.contains(permission) { continue }
                if permission.asksByDefault { ask = true } else { return .deny }
            }
        }
        return ask ? .ask : .allow
    }
}
