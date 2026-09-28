import Foundation

/// Zoom levels, and which site has which.
public enum PageZoom {
    /// The steps ⌘+ and ⌘− move through: Chrome's.
    public static let steps: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    public static func larger(than zoom: Double) -> Double {
        steps.first { $0 > zoom + 0.001 } ?? steps[steps.count - 1]
    }

    public static func smaller(than zoom: Double) -> Double {
        steps.last { $0 < zoom - 0.001 } ?? steps[0]
    }

    public static func isDefault(_ zoom: Double) -> Bool { abs(zoom - 1) < 0.001 }

    /// "125%"
    public static func label(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// What zoom is remembered by: the site, so every page of it and both
    /// http and https share one level, and `www.` is the same site.
    public static func key(for url: URL?) -> String? {
        guard let url, url.scheme == "http" || url.scheme == "https", var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The remembered levels with one changed. 100% is not remembered: it
    /// is what a site has when nothing is.
    public static func setting(_ zoom: Double, for key: String, in levels: [String: Double]) -> [String: Double] {
        var levels = levels
        if isDefault(zoom) { levels[key] = nil } else { levels[key] = zoom }
        return levels
    }
}
