import Foundation

/// What an extension asks for, said the way a person would say it. Chrome
/// and Safari word these prompts; these follow them.
public enum ExtensionPermissionWording {
    /// One line per thing the extension could do, the most far-reaching first.
    public static func describe(permissions: Set<String>, matchPatterns: Set<String>) -> [String] {
        var lines: [String] = []
        let sites = describeSites(matchPatterns)
        if let sites { lines.append(sites) }
        let wording: [(String, String)] = [
            ("nativeMessaging", "Talk to apps on this Mac"),
            ("webRequest", "See the pages your browser loads"),
            ("declarativeNetRequest", "Block content on any page"),
            ("declarativeNetRequestWithHostAccess", "Block content on pages it can read"),
            ("history", "Read and change your browsing history"),
            ("bookmarks", "Read and change your bookmarks"),
            ("tabs", "See the addresses and titles of your open tabs"),
            ("webNavigation", "See the addresses of the pages you visit"),
            ("cookies", "Read and change cookies of the sites it can read"),
            ("clipboardRead", "Read what you copy"),
            ("clipboardWrite", "Change what you copy and paste"),
            ("downloads", "Manage your downloads"),
            ("notifications", "Show notifications"),
            ("contextMenus", "Add to the right-click menu"),
            ("menus", "Add to the right-click menu"),
            ("scripting", "Run its own scripts on pages it can read"),
            ("storage", "Store its own data"),
            ("unlimitedStorage", "Store as much of its own data as it needs"),
            ("alarms", "Run in the background at set times"),
        ]
        for (permission, text) in wording where permissions.contains(permission) && !lines.contains(text) {
            lines.append(text)
        }
        if permissions.contains("activeTab"), sites == nil {
            lines.append("Read and change the page you are on when you click it")
        }
        return lines
    }

    /// "Read and change your data on all websites", or on the few it names.
    public static func describeSites(_ patterns: Set<String>) -> String? {
        let hosts = patterns.compactMap(host(of:))
        guard !hosts.isEmpty else { return nil }
        if hosts.contains("*") { return "Read and change your data on all websites" }
        let names = Array(Set(hosts)).sorted()
        if names.count > 3 { return "Read and change your data on \(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more sites" }
        return "Read and change your data on " + (names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!)
    }

    /// "*://*.example.com/*" is example.com; "<all_urls>" and "*://*/*" are every site.
    public static func host(of pattern: String) -> String? {
        if pattern == "<all_urls>" { return "*" }
        guard let scheme = pattern.range(of: "://") else { return nil }
        let rest = pattern[scheme.upperBound...]
        let host = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if host == "*" || host.isEmpty { return "*" }
        return host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
    }
}

/// What an extension may read, as chosen for it.
public enum ExtensionSiteAccess: Codable, Equatable, Sendable {
    /// Every site it asked for.
    case allRequested
    /// Only the page in front, when its button is clicked.
    case onClick
    /// These sites only, of those it asked for.
    case sites([String])

    public var title: String {
        switch self {
        case .allRequested: return "On all sites it asks for"
        case .onClick: return "When you click it"
        case .sites: return "On specific sites"
        }
    }

    /// The patterns to grant, of those requested.
    public func granted(from requested: Set<String>) -> Set<String> {
        switch self {
        case .allRequested: return requested
        case .onClick: return []
        case .sites(let hosts):
            return Set(hosts.flatMap { host in ["*://\(host)/*", "*://*.\(host)/*"] })
        }
    }
}

/// A Chrome Web Store package (.crx): a header with its signatures, then a zip.
public enum CRXPackage {
    /// The zip inside, or nil if this is not a .crx. A plain zip is returned as it is.
    public static func zip(from data: Data) -> Data? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return data }   // "PK": a zip already
        guard bytes.count >= 12, bytes.starts(with: Array("Cr24".utf8)) else { return nil }
        func uint32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        let version = uint32(4)
        let start: Int
        switch version {
        case 3:
            start = 12 + uint32(8)
        case 2:
            guard bytes.count >= 16 else { return nil }
            start = 16 + uint32(8) + uint32(12)
        default:
            return nil
        }
        guard start < data.count else { return nil }
        let zip = data.dropFirst(start)
        return zip.starts(with: [0x50, 0x4B]) ? Data(zip) : nil
    }
}
