import Foundation
import PasswordKit

// Unit checks for PasswordKit, as a plain executable: `swift run PasswordKitChecks`.
// `--keychain` adds a round trip through the real login Keychain under a
// throwaway account, which is removed again.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
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

// MARK: Password rules

do {
    let rules = PasswordRules.parse("required: upper; required: digit; required: [-_]; allowed: lower; max-consecutive: 2; minlength: 10; maxlength: 14;")
    check("rules: three required classes", rules.required.count == 3)
    check("rules: allowed collects lower", rules.allowed == PasswordRules.lower)
    check("rules: lengths and max-consecutive", rules.minLength == 10 && rules.maxLength == 14 && rules.maxConsecutive == 2)
    check("rules: an unknown clause is skipped, the rest kept", PasswordRules.parse("frobnicate: 3; maxlength: 12").maxLength == 12)
    check("rules: `]` first inside brackets", PasswordRules.characterClass("[]-]") == Set("]-"))
    check("rules: an unknown class name spoils only its clause", PasswordRules.parse("required: wobbly; required: digit").required == [PasswordRules.digit])
    check("rules: the field's maxlength narrows, never widens", PasswordRules.parse("maxlength: 30", maxLength: 16).maxLength == 16
          && PasswordRules.parse("maxlength: 12", maxLength: 16).maxLength == 12)
    check("rules: HTML's -1 for no limit is ignored", PasswordRules.parse("", minLength: -1, maxLength: -1) == PasswordRules())
    check("rules: none is unrestricted", PasswordRules().isUnrestricted && !PasswordRules.parse("", maxLength: 16).isUnrestricted)

    var allRespected = true
    for _ in 0..<300 {
        let password = PasswordGenerator.generate(rules: rules)
        let chars = Array(password)
        let ok = (10...14).contains(chars.count)
            && chars.contains(where: PasswordRules.upper.contains) && chars.contains(where: PasswordRules.digit.contains)
            && chars.contains(where: Set("-_").contains)
            && chars.allSatisfy { PasswordRules.lower.union(PasswordRules.upper).union(PasswordRules.digit).union("-_").contains($0) }
            && PasswordGenerator.longestRun(chars) <= 2
        if !ok { allRespected = false; print("  offending: \(password)"); break }
    }
    check("generator: 300 passwords all obey the site's rules", allRespected)
    check("generator: a 16-character field gets 16, not a truncated 20", PasswordGenerator.generate(rules: .parse("", maxLength: 16)).count == 16)
    check("generator: a 32-character minimum is met", PasswordGenerator.generate(rules: .parse("minlength: 32")).count == 32)
    check("generator: digits only, when that is all a site allows", PasswordGenerator.generate(rules: .parse("allowed: digit; maxlength: 6")).allSatisfy(\.isNumber))
    check("generator: no rules keeps the grouped format", PasswordGenerator.generate(rules: PasswordRules()).split(separator: "-").count == 3)
}

// MARK: Checkup

check("weak: too short", PasswordStrength.weaknesses(of: "aB3$x").contains(.tooShort))
check("weak: a common password", PasswordStrength.weaknesses(of: "password").contains(.common))
check("weak: a common password with a number and ! on the end", PasswordStrength.weaknesses(of: "Password123!").contains(.common))
check("weak: digits only", PasswordStrength.weaknesses(of: "38472910").contains(.singleKind))
check("weak: a run", PasswordStrength.weaknesses(of: "abcdefgh").contains(.pattern))
check("weak: a keyboard row", PasswordStrength.weaknesses(of: "asdfghjk").contains(.pattern))
check("weak: contains the username", PasswordStrength.weaknesses(of: "ada-Lovelace-99", username: "ada@example.com").contains(.containsUsername))
check("weak: contains the site's name", PasswordStrength.weaknesses(of: "MyExample2024!", origin: "https://mail.example.co.uk").contains(.containsSiteName))
check("strong: a generated password is not weak", !PasswordStrength.isWeak(PasswordGenerator.generate(), username: "ada", origin: "https://example.com"))
check("strong: a long passphrase of one kind is not weak", !PasswordStrength.isWeak("correct horse battery staple"))

do {
    let a = Credential(origin: "https://a.com", username: "ada")
    let b = Credential(origin: "https://b.com", username: "ada")
    let c = Credential(origin: "https://c.com", username: "ada")
    let report = PasswordAudit.run([(a, "Shared-Pass-2024"), (b, "Shared-Pass-2024"), (c, "kpmwTx-r7hqzn-4bVcye")],
                                   breaches: ["Shared-Pass-2024": 0, "kpmwTx-r7hqzn-4bVcye": 12])
    check("audit: reuse is reported on both sites, naming the other", report.issues.first { $0.credential.id == a.id }?.kinds == [.reused(["b.com"])])
    check("audit: a leaked password comes first", report.issues.first?.credential.id == c.id && report.issues.first?.kinds == [.compromised(12)])
    check("audit: counts", report.compromised == 1 && report.reused == 2 && report.weak == 0 && report.checked == 3)
    check("audit: without a leak check, it says so", !PasswordAudit.run([(a, "x")]).breachChecked)
}

do {
    check("pwned: SHA-1 is upper-case hex", PwnedPasswords.sha1Hex("password") == "5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8")
    check("pwned: range lines parse, padding counts 0",
          PwnedPasswords.parse(range: "1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\n0018A45C4D1DEF81644B54AB7F969B88D65:0\n") ==
          ["1E4C9B93F3F0682250B6CF8331B7EE68FD8": 9545824, "0018A45C4D1DEF81644B54AB7F969B88D65": 0])

    final class Log: @unchecked Sendable { var urls: [URL] = []; var padding: [String?] = [] }
    let log = Log()
    let checker = PwnedPasswords { request in
        log.urls.append(request.url!)
        log.padding.append(request.value(forHTTPHeaderField: "Add-Padding"))
        let body = "1E4C9B93F3F0682250B6CF8331B7EE68FD8:42\r\nFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:0"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let counts = try await checker.counts(for: ["password", "password", "kpmwTx-r7hqzn-4bVcye"])
    check("pwned: a match is counted", counts["password"] == 42)
    check("pwned: a miss is 0", counts["kpmwTx-r7hqzn-4bVcye"] == 0)
    check("pwned: one request per distinct prefix", log.urls.count == 2)
    check("pwned: only five characters of the hash leave", log.urls.allSatisfy { $0.lastPathComponent.count == 5 })
    check("pwned: neither a password nor its full hash appears in a request", !log.urls.contains {
        $0.absoluteString.contains("kpmwTx") || $0.absoluteString.contains(PwnedPasswords.sha1Hex("password"))
    })
    check("pwned: padding is requested", log.padding.allSatisfy { $0 == "true" })

    let failing = PwnedPasswords { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
    }
    do {
        _ = try await failing.counts(for: ["x"])
        check("pwned: a server error is an error, not \"none leaked\"", false)
    } catch {
        check("pwned: a server error is an error, not \"none leaked\"", error as? PwnedPasswords.CheckError == .http(503))
    }
} catch {
    failures += 1
    print("✘ pwned checks stopped early: \(error)")
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

// MARK: Chromium's saved passwords

do {
    let key = ChromiumPasswords.key(from: "peanuts")
    check("chromium: the key is PBKDF2-SHA1 of the Keychain secret, saltysalt, 1003 rounds",
          key?.map { String(format: "%02x", $0) }.joined() == "d9a09d499b4e1b7461f28e67972c6dbd")
    // Made with openssl, apart from this code: "correct horse", AES-128-CBC, IV of spaces.
    let fromOpenSSL = Data("v10".utf8) + Data([0x2c, 0x4b, 0xb4, 0x0f, 0x87, 0x5f, 0x1b, 0x63, 0x39, 0x35, 0x8d, 0x9c, 0x8f, 0xc0, 0xf8, 0x7b])
    check("chromium: a password Chrome stored reads back", key.flatMap { ChromiumPasswords.decrypt(fromOpenSSL, key: $0) } == "correct horse")
    check("chromium: …and one written here reads back the same", key.flatMap { k in ChromiumPasswords.encrypt("pässwörd ✓", key: k).flatMap { ChromiumPasswords.decrypt($0, key: k) } } == "pässwörd ✓")
    check("chromium: the wrong secret reads nothing", ChromiumPasswords.key(from: "almonds").flatMap { ChromiumPasswords.decrypt(fromOpenSSL, key: $0) } == nil)
    check("chromium: a value without v10 is not taken", key.flatMap { ChromiumPasswords.decrypt(Data(fromOpenSSL.dropFirst(3)), key: $0) } == nil)
}

// MARK: AutoFill: addresses and cards

do {
    typealias F = AutofillFieldDescriptor
    // A shop that says what each field is (autocomplete), as Shopify's checkout does.
    let tagged = [F(autocomplete: "shipping given-name"), F(autocomplete: "shipping family-name"), F(autocomplete: "shipping address-line1"),
                  F(autocomplete: "shipping address-line2"), F(autocomplete: "shipping address-level2"), F(tag: "select", autocomplete: "shipping country"),
                  F(autocomplete: "shipping postal-code"), F(type: "email", autocomplete: "email"), F(autocomplete: "cc-number"),
                  F(autocomplete: "cc-exp"), F(autocomplete: "cc-csc"), F(autocomplete: "cc-name")]
    check("autofill: autocomplete tokens say what a field is", AutofillClassifier.kinds(of: tagged).map { $0?.rawValue ?? "-" } == [
        "givenName", "familyName", "addressLine1", "addressLine2", "city", "country", "postalCode", "email", "cardNumber", "cardExpiry", "cardSecurityCode", "cardName"])
    // One that does not: names, ids and labels, as many older shops.
    let untagged = [F(name: "fname", label: "First name"), F(name: "lname", label: "Last name"), F(name: "address1", label: "Street address"),
                    F(name: "address2", label: "Apartment, suite, etc."), F(name: "city"), F(tag: "select", name: "state", label: "State"),
                    F(name: "zip", label: "ZIP code"), F(type: "tel", name: "phone"), F(name: "ccnum", label: "Card number"),
                    F(tag: "select", name: "exp_month", label: "Expiration month"), F(tag: "select", name: "exp_year", label: "Expiration year"),
                    F(name: "cvv", label: "Security code"), F(type: "password", name: "password"), F(type: "hidden", name: "token"),
                    F(name: "search_query", placeholder: "Search")]
    check("autofill: names and labels, when nothing says", AutofillClassifier.kinds(of: untagged).map { $0?.rawValue ?? "-" } == [
        "givenName", "familyName", "addressLine1", "addressLine2", "city", "region", "postalCode", "phone", "cardNumber",
        "cardExpiryMonth", "cardExpiryYear", "cardSecurityCode", "-", "-", "-"], AutofillClassifier.kinds(of: untagged).map { $0?.rawValue ?? "-" })
    check("autofill: other languages", AutofillClassifier.kind(of: F(name: "plz")) == .postalCode && AutofillClassifier.kind(of: F(label: "Nachname")) == .familyName
          && AutofillClassifier.kind(of: F(label: "Numéro de carte")) == .cardNumber)
    check("autofill: a one-time code", AutofillClassifier.kind(of: F(autocomplete: "one-time-code")) == .oneTimeCode)

    let home = AutofillAddress(label: "Home", fullName: "Ada King Lovelace", street: "12 St James's Square\nFlat 3", city: "London", region: "",
                               postalCode: "SW1Y 4JH", country: "GB", email: "ada@example.com", phone: "+44 20 7946 0000")
    let visa = AutofillCard(nameOnCard: "A K Lovelace", number: "4242 4242 4242 4242", expiryMonth: 7, expiryYear: 29)
    check("cards: brand, last four, expiry", visa.brand == .visa && visa.masked == "Visa •••• 4242" && visa.expiry == "07/29" && visa.expiryYear == 2029)
    check("cards: brands", AutofillCard.brand(of: "5555555555554444") == .mastercard && AutofillCard.brand(of: "378282246310005") == .amex
          && AutofillCard.brand(of: "2223003122003222") == .mastercard && AutofillCard.brand(of: "6011111111111117") == .discover)
    check("cards: a mistyped number is not a card", AutofillCard.isPlausible("4242424242424242") && !AutofillCard.isPlausible("4242424242424241") && !AutofillCard.isPlausible("1234"))
    check("addresses: shown as a line", home.summary == "Home — 12 St James's Square, London")

    let values = AutofillFill.values(for: AutofillClassifier.kinds(of: tagged), address: home, card: visa)
    check("autofill: name, address and card, in one go", values == [0: "Ada King", 1: "Lovelace", 2: "12 St James's Square", 3: "Flat 3", 4: "London", 5: "GB",
                                                                      6: "SW1Y 4JH", 7: "ada@example.com", 8: "4242424242424242", 9: "07/29", 11: "A K Lovelace"], values)
    check("autofill: the security code is never filled", values[10] == nil)
    let split = AutofillFill.values(for: AutofillClassifier.kinds(of: untagged), address: home, card: visa)
    check("autofill: month and year apart", split[9] == "07" && split[10] == "2029" && split[2] == "12 St James's Square")
    check("autofill: an address alone fills no card field", AutofillFill.values(for: AutofillClassifier.kinds(of: tagged), address: home, card: nil)[8] == nil)

    let typed = AutofillFill.captured(kinds: AutofillClassifier.kinds(of: untagged),
                                      values: ["Grace", "Hopper", "1 Navy Way", "", "Arlington", "VA", "22201", "555-0100", "5555 5555 5555 4444", "12", "2031", "123", "secret", "x", ""])
    check("autofill: what was typed becomes an address and a card, to save", typed.address?.fullName == "Grace Hopper" && typed.address?.city == "Arlington"
          && typed.card?.number == "5555555555554444" && typed.card?.expiryYear == 2031 && typed.card?.nameOnCard == "Grace Hopper", typed)
    check("autofill: …never its security code", !(String(describing: typed).contains("123\"")))
    let nothing = AutofillFill.captured(kinds: AutofillClassifier.kinds(of: untagged), values: Array(repeating: "", count: untagged.count))
    check("autofill: an empty form is nothing to save", nothing.address == nil && nothing.card == nil)
    check("addresses: the same one typed again is the same", home.isSame(as: AutofillAddress(fullName: "ada king lovelace", street: "12 St James's Square", postalCode: "sw1y 4jh")))
    check("addresses: …and another is another", !home.isSame(as: AutofillAddress(fullName: "Ada King Lovelace", street: "1 Other Road", postalCode: "SW1Y 4JH")))

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("autofill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let keys = FileVaultKeyProvider(url: folder.appendingPathComponent("key"))
    let vault = AutofillVault(fileURL: folder.appendingPathComponent("Autofill.vault"), keyProvider: keys)
    try await vault.save(home)
    try await vault.save(visa)
    let reopened = AutofillVault(fileURL: folder.appendingPathComponent("Autofill.vault"), keyProvider: keys)
    let back = try await reopened.contents()
    check("autofill vault: addresses and cards come back", back.addresses == [home] && back.cards == [visa])
    let raw = try Data(contentsOf: folder.appendingPathComponent("Autofill.vault"))
    check("autofill vault: nothing readable on disk", raw.range(of: Data("4242".utf8)) == nil && raw.range(of: Data("Lovelace".utf8)) == nil)
    try await reopened.deleteCard(visa.id)
    check("autofill vault: a card can go", try await reopened.contents().cards.isEmpty)

    // A missing key, with the passwords' file still there, is never replaced.
    let passwords = folder.appendingPathComponent("Passwords.vault")
    try Data("x".utf8).write(to: passwords)
    let keyless = AutofillVault(fileURL: folder.appendingPathComponent("Other.vault"), keyProvider: FileVaultKeyProvider(url: folder.appendingPathComponent("nokey")),
                                passwordVault: passwords)
    var refused = false
    do { try await keyless.save(home) } catch { refused = true }
    check("autofill vault: a lost key is reported, not remade over the passwords", refused && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("nokey").path))
} catch {
    check("autofill checks", false, error)
}

print(failures == 0 ? "✔ all \(passed) PasswordKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
