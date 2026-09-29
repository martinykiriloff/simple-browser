import Foundation

/// Where the app is running from, and whether to offer to move it.
///
/// Opened straight from the downloaded disk image, or from Downloads,
/// macOS runs a copy in a random read-only place ("App Translocation"),
/// where the app cannot update itself. From /Applications it can.
public enum AppLocation: Equatable, Sendable {
    case applications
    case userApplications
    /// macOS's temporary copy of a quarantined app.
    case translocated
    /// A mounted disk image, such as the downloaded DMG.
    case diskImage
    /// A temporary folder: a build or a test's copy, not a download.
    case temporary
    case elsewhere

    public static func of(bundlePath: String, home: String) -> AppLocation {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Applications/") { return .applications }
        if path.hasPrefix((home as NSString).appendingPathComponent("Applications") + "/") { return .userApplications }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        // Anywhere in the person's home (Downloads, Desktop) is theirs.
        if path.hasPrefix((home as NSString).standardizingPath + "/") { return .elsewhere }
        if ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains(where: path.hasPrefix) { return .temporary }
        return .elsewhere
    }

    /// Worth asking about: anywhere but an Applications folder.
    public var shouldOfferMove: Bool { self != .applications && self != .userApplications && self != .temporary }

    /// The original can go to the Trash once moved: not a disk image's, nor
    /// macOS's temporary copy, which are not the person's to throw away.
    public var removesOriginal: Bool { self == .elsewhere }
}
