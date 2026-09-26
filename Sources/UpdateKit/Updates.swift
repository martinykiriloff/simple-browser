import Foundation
import CryptoKit

/// A release version, `1.4.2`, compared number by number: `0.10.0` is newer
/// than `0.9.3`, which a string comparison gets wrong.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// Accepts `v1.2.3` as a tag spells it. Pre-release suffixes (`-beta.1`)
    /// are not versions this updater offers: nil.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// A published release this app can update to.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL
    public let dmgURL: URL
    /// The Ed25519 signature file published beside the DMG.
    public let signatureURL: URL

    public init(version: AppVersion, notes: String, pageURL: URL, dmgURL: URL, signatureURL: URL) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.signatureURL = signatureURL
    }
}

/// Reads GitHub's "latest release" answer.
public enum GitHubReleases {
    public static func latestURL(repository: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public enum ParseError: Error, Equatable, Sendable {
        case notJSON
        case badVersion(String)
        /// The release has no DMG, or no signature for it: nothing safe to install.
        case missingAsset(String)
    }

    /// Drafts and pre-releases are never offered; GitHub leaves them out of
    /// "latest" already, and this refuses them again in case that changes.
    public static func parse(_ data: Data) throws -> AvailableUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        let tag = json["tag_name"] as? String ?? ""
        guard let version = AppVersion(tag) else { throw ParseError.badVersion(tag) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ matches: (String) -> Bool) -> URL? {
            assets.first { matches(($0["name"] as? String ?? "").lowercased()) }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        guard let dmg = asset({ $0.hasSuffix(".dmg") }) else { throw ParseError.missingAsset(".dmg") }
        let dmgName = dmg.lastPathComponent.lowercased()
        guard let signature = asset({ $0 == dmgName + ".sig" }) else { throw ParseError.missingAsset(dmgName + ".sig") }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? dmg
        return AvailableUpdate(version: version, notes: json["body"] as? String ?? "", pageURL: page, dmgURL: dmg, signatureURL: signature)
    }
}

/// Ed25519 signatures over the DMG, the way Sparkle signs its updates.
///
/// The private key lives only in the repository's secrets and signs in CI;
/// the public key is compiled into the app. A DMG that does not verify is
/// never opened, whoever put it on the release page.
public enum UpdateSignature {
    public enum VerifyError: Error, Equatable, Sendable {
        case badPublicKey
        case badSignature
        case mismatch
    }

    /// - Parameters:
    ///   - signature: the `.sig` file's contents: base64, whitespace allowed.
    ///   - publicKey: base64 of the 32-byte raw key.
    public static func verify(_ data: Data, signature: String, publicKey: String) throws {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw VerifyError.badPublicKey }
        guard let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              signatureData.count == 64 else { throw VerifyError.badSignature }
        guard key.isValidSignature(signatureData, for: data) else { throw VerifyError.mismatch }
    }

    /// For the signing script and the checks.
    public static func sign(_ data: Data, privateKey: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw VerifyError.badPublicKey
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        return try key.signature(for: data).base64EncodedString()
    }
}

/// When to look again, and what the person already said no to.
public struct UpdatePolicy: Sendable {
    /// Once a day at most, unless asked.
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }

    /// Offer it when it is newer than what runs, and not the version the
    /// person chose to skip. A check they asked for ignores the skip.
    public static func shouldOffer(_ update: AvailableUpdate, current: AppVersion, skipped: AppVersion?, userInitiated: Bool) -> Bool {
        guard update.version > current else { return false }
        if !userInitiated, let skipped, skipped == update.version { return false }
        return true
    }
}
