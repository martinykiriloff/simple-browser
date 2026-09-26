import Foundation
import CryptoKit
import UpdateKit

// Unit checks for UpdateKit: `swift run UpdateKitChecks`.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
}

func v(_ text: String) -> AppVersion { AppVersion(text)! }

// MARK: Versions

check("v prefix", AppVersion("v1.2.3")?.parts == [1, 2, 3])
check("numeric, not alphabetical", v("0.10.0") > v("0.9.3"))
check("missing parts are zero", v("1.2") == v("1.2.0") && !(v("1.2") < v("1.2.0")))
check("patch releases order", v("1.2.1") > v("1.2") && v("1.2.0") < v("1.2.1"))
check("major wins", v("2.0") > v("1.99.99"))
check("pre-releases are not offered", AppVersion("1.0.0-beta.1") == nil)
check("garbage is nil", AppVersion("latest") == nil && AppVersion("") == nil && AppVersion("1..2") == nil)
check("equal versions hash alike", Set([v("1.2"), v("1.2.0")]).count == 1)

// MARK: GitHub

func release(tag: String, assets: [String], draft: Bool = false, prerelease: Bool = false) -> Data {
    let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://github.com/o/r/releases/download/\#(tag)/\#($0)"}"# }
    return Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"html_url":"https://github.com/o/r/releases/tag/\#(tag)","body":"Faster.","assets":[\#(list.joined(separator: ","))]}"#.utf8)
}
do {
    let update = try GitHubReleases.parse(release(tag: "v0.3.0", assets: ["SimpleBrowser-0.3.0.dmg", "SimpleBrowser-0.3.0.dmg.sig"]))
    check("a release parses", update?.version == v("0.3.0") && update?.notes == "Faster.")
    check("the DMG and its signature are found", update?.dmgURL.lastPathComponent == "SimpleBrowser-0.3.0.dmg" && update?.signatureURL.lastPathComponent == "SimpleBrowser-0.3.0.dmg.sig")
    check("a draft is not offered", try GitHubReleases.parse(release(tag: "v9.0", assets: ["a.dmg", "a.dmg.sig"], draft: true)) == nil)
    check("a pre-release is not offered", try GitHubReleases.parse(release(tag: "v9.0", assets: ["a.dmg", "a.dmg.sig"], prerelease: true)) == nil)
} catch {
    check("releases parse", false, error)
}
do {
    _ = try GitHubReleases.parse(release(tag: "v1.0", assets: ["SimpleBrowser-1.0.dmg"]))
    check("a DMG without a signature is refused", false)
} catch { check("a DMG without a signature is refused", error as? GitHubReleases.ParseError == .missingAsset("simplebrowser-1.0.dmg.sig")) }
do {
    _ = try GitHubReleases.parse(release(tag: "nightly", assets: []))
    check("a tag that is not a version is refused", false)
} catch { check("a tag that is not a version is refused", error as? GitHubReleases.ParseError == .badVersion("nightly")) }

// MARK: Signatures

let key = Curve25519.Signing.PrivateKey()
let privateKey = key.rawRepresentation.base64EncodedString()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
let dmg = Data("pretend this is a disk image".utf8)
do {
    let signature = try UpdateSignature.sign(dmg, privateKey: privateKey)
    try UpdateSignature.verify(dmg, signature: signature + "\n", publicKey: publicKey)
    check("a signed DMG verifies", true)
    do {
        try UpdateSignature.verify(dmg + Data([0]), signature: signature, publicKey: publicKey)
        check("one changed byte fails", false)
    } catch { check("one changed byte fails", error as? UpdateSignature.VerifyError == .mismatch) }
    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    do {
        try UpdateSignature.verify(dmg, signature: signature, publicKey: other)
        check("another key's signature fails", false)
    } catch { check("another key's signature fails", error as? UpdateSignature.VerifyError == .mismatch) }
    do {
        try UpdateSignature.verify(dmg, signature: "bm90IGEgc2lnbmF0dXJl", publicKey: publicKey)
        check("a malformed signature fails", false)
    } catch { check("a malformed signature fails", error as? UpdateSignature.VerifyError == .badSignature) }
} catch {
    check("signing works", false, error)
}

// MARK: Policy

let now = Date()
check("never checked: due", UpdatePolicy.isDue(lastCheck: nil, now: now))
check("an hour ago: not due", !UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
check("a day ago: due", UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-UpdatePolicy.interval), now: now))
check("a clock set back: due", UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
let update = AvailableUpdate(version: v("0.2.0"), notes: "", pageURL: URL(string: "https://x")!, dmgURL: URL(string: "https://x/a.dmg")!, signatureURL: URL(string: "https://x/a.dmg.sig")!)
check("newer: offered", UpdatePolicy.shouldOffer(update, current: v("0.1.0"), skipped: nil, userInitiated: false))
check("same: not offered", !UpdatePolicy.shouldOffer(update, current: v("0.2.0"), skipped: nil, userInitiated: true))
check("older: not offered", !UpdatePolicy.shouldOffer(update, current: v("0.3.0"), skipped: nil, userInitiated: true))
check("skipped: not offered on its own", !UpdatePolicy.shouldOffer(update, current: v("0.1.0"), skipped: v("0.2.0"), userInitiated: false))
check("skipped: offered when asked for", UpdatePolicy.shouldOffer(update, current: v("0.1.0"), skipped: v("0.2.0"), userInitiated: true))
check("a newer one than the skipped is offered", UpdatePolicy.shouldOffer(update, current: v("0.1.0"), skipped: v("0.1.5"), userInitiated: false))

print(failures == 0 ? "✔ all \(passed) UpdateKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
