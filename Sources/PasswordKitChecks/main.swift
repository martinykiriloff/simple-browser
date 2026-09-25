import Foundation
import PasswordKit

// Unit checks for PasswordKit, as a plain executable: `swift run PasswordKitChecks`.
// `--keychain` adds a round trip through the real login Keychain under a
// throwaway account, which is removed again.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)") }
}

func expectThrow(_ name: String, _ expected: CredentialStoreError? = nil, _ body: () async throws -> Void) async {
    do {
        try await body()
        failures += 1; print("✘ \(name): did not throw")
    } catch let error as CredentialStoreError {
        if let expected, error != expected { failures += 1; print("✘ \(name): threw \(error)") } else { passed += 1 }
    } catch {
        failures += 1; print("✘ \(name): threw \(error)")
    }
}

// MARK: Origins

check("default https port is dropped", CredentialOrigin.origin(of: URL(string: "https://Example.COM:443/login?x=1")!) == "https://example.com")
check("default http port is dropped", CredentialOrigin.origin(of: URL(string: "http://example.com:80/")!) == "http://example.com")
check("other ports are kept", CredentialOrigin.origin(of: URL(string: "https://example.com:8443/a")!) == "https://example.com:8443")
check("WebKit's port 0 means default", CredentialOrigin.origin(scheme: "https", host: "example.com", port: 0) == "https://example.com")
check("IPv6 hosts are bracketed", CredentialOrigin.origin(scheme: "http", host: "::1", port: 8080) == "http://[::1]:8080")
check("file: has no origin", CredentialOrigin.origin(of: URL(string: "file:///etc/passwd")!) == nil)
check("about: has no origin", CredentialOrigin.origin(of: URL(string: "about:blank")!) == nil)
check("data: has no origin", CredentialOrigin.origin(of: URL(string: "data:text/html,hi")!) == nil)
check("a bare host normalises to https", CredentialOrigin.normalize("example.com") == "https://example.com")
check("a full URL normalises to its origin", CredentialOrigin.normalize(" http://example.com:8080/path ") == "http://example.com:8080")
check("a phrase is not an origin", CredentialOrigin.normalize("my bank") == nil)
check("site strips the scheme", CredentialOrigin.site(of: "https://example.com:8443") == "example.com:8443")

check("same origin matches", CredentialOrigin.matches(saved: "https://example.com", page: "https://example.com"))
check("http password is offered to the https site", CredentialOrigin.matches(saved: "http://example.com", page: "https://example.com"))
check("https password is never offered to http", !CredentialOrigin.matches(saved: "https://example.com", page: "http://example.com"))
check("a subdomain does not match", !CredentialOrigin.matches(saved: "https://example.com", page: "https://login.example.com"))
check("a suffix trick does not match", !CredentialOrigin.matches(saved: "https://example.com", page: "https://example.com.evil.test"))
check("a prefix trick does not match", !CredentialOrigin.matches(saved: "https://example.com", page: "https://evilexample.com"))
check("another port does not match", !CredentialOrigin.matches(saved: "https://example.com", page: "https://example.com:8443"))
check("the http upgrade keeps the port", !CredentialOrigin.matches(saved: "http://example.com:8080", page: "https://example.com"))
check("plain http is insecure", CredentialOrigin.isInsecure("http://example.com"))
check("loopback http is not flagged", !CredentialOrigin.isInsecure("http://127.0.0.1:8766") && !CredentialOrigin.isInsecure("http://localhost"))
check("https is not insecure", !CredentialOrigin.isInsecure("https://example.com"))

// MARK: Save decision

let ada = Credential(origin: "https://example.com", username: "ada")
let bob = Credential(origin: "https://example.com", username: "bob")
check("nothing saved: offer to save", SaveDecision.decide(username: "ada", password: "p", existing: []) == .offerSave)
check("same again: nothing", SaveDecision.decide(username: "ada", password: "p", existing: [(ada, "p")]) == .nothing)
check("new password: offer update", SaveDecision.decide(username: "ada", password: "q", existing: [(ada, "p")]) == .offerUpdate(ada))
check("second account: offer to save", SaveDecision.decide(username: "bob", password: "p", existing: [(ada, "p")]) == .offerSave)
check("empty password: nothing", SaveDecision.decide(username: "ada", password: "", existing: []) == .nothing)
check("change form, one account: update it", SaveDecision.decide(username: "", password: "new", existing: [(ada, "old")]) == .offerUpdate(ada))
check("change form, two accounts: cannot tell, offer save", SaveDecision.decide(username: "", password: "new", existing: [(ada, "a"), (bob, "b")]) == .offerSave)
check("no username but a known password: nothing", SaveDecision.decide(username: "", password: "b", existing: [(ada, "a"), (bob, "b")]) == .nothing)
check("change form, two accounts, current password names one: update that one",
      SaveDecision.decide(username: "", password: "new", currentPassword: "b", existing: [(ada, "a"), (bob, "b")]) == .offerUpdate(bob))
check("change form, current password shared by two accounts: cannot tell",
      SaveDecision.decide(username: "", password: "new", currentPassword: "same", existing: [(ada, "same"), (bob, "same")]) == .offerSave)
check("change form, unknown current password, two accounts: offer save",
      SaveDecision.decide(username: "", password: "new", currentPassword: "zzz", existing: [(ada, "a"), (bob, "b")]) == .offerSave)
check("usernames are case-sensitive", SaveDecision.decide(username: "Ada", password: "p", existing: [(ada, "p")]) == .offerSave)

// MARK: Generator

var seen = Set<String>()
var shapeOK = true
for _ in 0..<2000 {
    let password = PasswordGenerator.generate()
    seen.insert(password)
    let groups = password.split(separator: "-")
    let letters = password.replacingOccurrences(of: "-", with: "")
    shapeOK = shapeOK && groups.count == 3 && groups.allSatisfy { $0.count == 6 }
        && letters.contains(where: \.isLowercase) && letters.contains(where: \.isUppercase) && letters.contains(where: \.isNumber)
        && !letters.contains(where: { "lI1O0o".contains($0) })
}
check("generated passwords have the shape and every character class", shapeOK)
check("2000 generated passwords are all different", seen.count == 2000)

// MARK: CSV

let tricky = [
    PasswordCSV.Row(origin: "https://example.com", username: "ada@example.com", password: "p,with\"quote\"\nand newline"),
    PasswordCSV.Row(origin: "http://127.0.0.1:8766", username: "", password: " leading space"),
    // WebKit reports international hosts in their ASCII form, so that is what is stored.
    PasswordCSV.Row(origin: "https://xn--e1afmkfd.xn--p1ai", username: "üser", password: "pässwörd-🔑"),
]
check("an international host normalises to its ASCII form", CredentialOrigin.normalize("https://пример.рф/login") == "https://xn--e1afmkfd.xn--p1ai")
check("export → import round trip keeps every character", try PasswordCSV.parse(PasswordCSV.export(tricky)).rows == tricky)
let chrome = "name,url,username,password,note\r\nexample.com,https://example.com/login,ada,secret,\r\n,android://hash@com.app/,x,y,\r\nnopass,https://a.test/,u,,\r\n"
let chromeResult = try PasswordCSV.parse(chrome)
check("Chrome CSV: the web row is imported by origin", chromeResult.rows == [PasswordCSV.Row(origin: "https://example.com", username: "ada", password: "secret")])
check("Chrome CSV: app and password-less rows are skipped and counted", chromeResult.skipped == 2)
let safari = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\nExample,https://example.com/,ada,secret,,\n"
check("Safari CSV with a BOM", try PasswordCSV.parse(safari).rows.count == 1)
let firefox = "\"url\",\"username\",\"password\",\"httpRealm\"\n\"https://example.com\",\"ada\",\"se\"\"cret\",\"\"\n"
check("Firefox CSV, all fields quoted", try PasswordCSV.parse(firefox).rows.first?.password == "se\"cret")
check("a file without url/password columns is refused", (try? PasswordCSV.parse("a,b,c\n1,2,3\n")) == nil)
check("an empty file is refused", (try? PasswordCSV.parse("")) == nil)

// MARK: Vault

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordkit-checks-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let vaultURL = directory.appendingPathComponent("vault/Passwords.sbvault")
let keyURL = directory.appendingPathComponent("key")
let secret = "correct horse battery staple ✓"

do {
    let store = VaultCredentialStore(fileURL: vaultURL, keyProvider: FileVaultKeyProvider(url: keyURL))
    check("a new vault is empty", try await store.all().isEmpty)
    check("reading an empty vault creates no file", !FileManager.default.fileExists(atPath: vaultURL.path))
    let saved = try await store.save(origin: "https://example.com", username: "ada", password: secret)
    check("save returns the credential", saved.username == "ada" && saved.origin == "https://example.com")
    check("the password comes back", try await store.password(for: saved.id) == secret)
    let again = try await store.save(origin: "https://example.com", username: "ada", password: "changed")
    check("saving the same account again replaces, not duplicates", try await store.all().count == 1 && again.id == saved.id)
    check("…and the password is the new one", try await store.password(for: saved.id) == "changed")
    let second = try await store.save(origin: "https://example.com", username: "bob", password: "b")
    _ = try await store.save(origin: "http://example.com", username: "old", password: "o")
    _ = try await store.save(origin: "https://other.test", username: "ada", password: "x")
    try await store.markUsed(second.id)
    let offered = try await store.credentials(forPage: "https://example.com")
    check("a page is offered its own and its http ancestor's accounts only", Set(offered.map(\.username)) == ["ada", "bob", "old"])
    check("the most recently used account comes first", offered.first?.username == "bob")
    check("an http page is not offered https passwords", try await store.credentials(forPage: "http://example.com").map(\.username) == ["old"])

    let raw = try Data(contentsOf: vaultURL)
    for needle in ["changed", "example.com", "ada", "bob", "username", "records"] {
        check("the file on disk does not contain “\(needle)”", raw.range(of: Data(needle.utf8)) == nil)
    }
    let permissions = (try FileManager.default.attributesOfItem(atPath: vaultURL.path)[.posixPermissions] as? NSNumber)?.intValue
    check("the vault is readable by the owner only (0600)", permissions == 0o600)
    let directoryPermissions = (try FileManager.default.attributesOfItem(atPath: vaultURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
    check("its directory is private (0700)", directoryPermissions == 0o700)
    check("no temporary files are left behind", try FileManager.default.contentsOfDirectory(atPath: vaultURL.deletingLastPathComponent().path) == ["Passwords.sbvault"])

    // A second instance, as another launch or another process would be.
    let reopened = VaultCredentialStore(fileURL: vaultURL, keyProvider: FileVaultKeyProvider(url: keyURL))
    check("a second instance reads the same vault", try await reopened.all().count == 4)
    _ = try await reopened.save(origin: "https://third.test", username: "c", password: "c")
    check("the first instance sees the other's write", try await store.all().count == 5)
    _ = try await store.save(origin: "https://fourth.test", username: "d", password: "d")
    check("…and does not lose it when it writes next", try await reopened.all().count == 6)

    let renamed = try await store.update(second.id, username: "ada", password: nil)
    check("renaming onto an existing account merges into one entry", try await store.credentials(forPage: "https://example.com").filter { $0.username == "ada" }.count == 1 && renamed.id == second.id)
    check("…which keeps the renamed entry's password", try await store.password(for: second.id) == "b")
    try await store.delete(second.id)
    await expectThrow("a deleted password is gone", .notFound) { _ = try await store.password(for: second.id) }
    await expectThrow("updating a missing entry throws", .notFound) { _ = try await store.update(UUID(), username: "x", password: nil) }

    // Fail closed.
    let before = try Data(contentsOf: vaultURL)
    let wrongKeyURL = directory.appendingPathComponent("wrong-key")
    _ = try FileVaultKeyProvider(url: wrongKeyURL).createKey()
    let intruder = VaultCredentialStore(fileURL: vaultURL, keyProvider: FileVaultKeyProvider(url: wrongKeyURL))
    await expectThrow("the wrong key cannot read", .cannotDecrypt) { _ = try await intruder.all() }
    await expectThrow("the wrong key cannot write", .cannotDecrypt) { _ = try await intruder.save(origin: "https://evil.test", username: "e", password: "e") }
    await expectThrow("the wrong key cannot wipe", .cannotDecrypt) { try await intruder.deleteAll() }
    let keyless = VaultCredentialStore(fileURL: vaultURL, keyProvider: FileVaultKeyProvider(url: directory.appendingPathComponent("no-such-key")))
    await expectThrow("a vault whose key is missing is not replaced by a new one") { _ = try await keyless.save(origin: "https://x.test", username: "x", password: "x") }
    check("…no key was created for it", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("no-such-key").path))
    check("the vault is byte-for-byte untouched after all of that", try Data(contentsOf: vaultURL) == before)

    var tampered = before
    tampered[tampered.count - 20] ^= 0x01
    let tamperedURL = directory.appendingPathComponent("tampered.sbvault")
    try tampered.write(to: tamperedURL)
    let tamperedStore = VaultCredentialStore(fileURL: tamperedURL, keyProvider: FileVaultKeyProvider(url: keyURL))
    await expectThrow("a single flipped bit is detected", .cannotDecrypt) { _ = try await tamperedStore.all() }
    try Data("not a vault".utf8).write(to: tamperedURL)
    await expectThrow("a foreign file is refused", .cannotDecrypt) { _ = try await tamperedStore.all() }

    try await store.deleteAll()
    check("delete all empties the vault", try await store.all().isEmpty)
} catch {
    failures += 1
    print("✘ vault checks stopped early: \(error)")
}

// MARK: Keychain (opt-in)

if CommandLine.arguments.contains("--keychain") {
    let account = "passwordkit-checks-\(UUID().uuidString)"
    let provider = KeychainVaultKeyProvider(service: "SimpleBrowser Safe Storage (checks)", account: account)
    defer { provider.deleteKey() }
    do {
        check("Keychain: no key to begin with", try provider.existingKey() == nil)
        let key = try provider.createKey()
        check("Keychain: the key is 256 bits", key.count == 32)
        check("Keychain: the key reads back", try provider.existingKey() == key)
        let keychainVault = directory.appendingPathComponent("keychain.sbvault")
        let store = VaultCredentialStore(fileURL: keychainVault, keyProvider: provider)
        let saved = try await store.save(origin: "https://example.com", username: "ada", password: secret)
        let reopened = VaultCredentialStore(fileURL: keychainVault, keyProvider: KeychainVaultKeyProvider(service: "SimpleBrowser Safe Storage (checks)", account: account))
        check("Keychain: a vault keyed from the Keychain reopens", try await reopened.password(for: saved.id) == secret)
        provider.deleteKey()
        check("Keychain: the throwaway key is removed", try provider.existingKey() == nil)
    } catch {
        failures += 1
        print("✘ Keychain checks stopped early: \(error)")
    }
}

print(failures == 0 ? "✔ all \(passed) PasswordKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
