import AppKit
import LocalAuthentication
import BrowserKit
import PasswordKit

/// Confirms the person at the keyboard is the Mac's owner before a saved
/// password is shown, copied, edited or exported -- Touch ID, Apple Watch or
/// the login password, whatever the Mac offers.
@MainActor
protocol PasswordAuthenticator: AnyObject {
    func authenticate(reason: String) async -> Bool
}

@MainActor
final class DeviceOwnerAuthenticator: PasswordAuthenticator {
    /// One confirmation covers a minute of looking things up, as in Chrome.
    private var validUntil = Date.distantPast

    func authenticate(reason: String) async -> Bool {
        if Date() < validUntil { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // A Mac with no login password has nothing to check against.
            return error?.code == LAError.passcodeNotSet.rawValue
        }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok { validUntil = Date().addingTimeInterval(60) }
        return ok
    }
}

/// The app's saved passwords: one vault per profile, the settings that govern
/// it, and the gate in front of anything that reveals a password.
@MainActor
final class PasswordService {
    static let didChange = Notification.Name("SimpleBrowser.passwordsDidChange")

    let store: any CredentialStore
    var authenticator: any PasswordAuthenticator
    /// Replaced by the self-test, so it never calls the real service.
    var breachChecker = PwnedPasswords()

    init(store: any CredentialStore, authenticator: any PasswordAuthenticator = DeviceOwnerAuthenticator()) {
        self.store = store
        self.authenticator = authenticator
    }

    /// The real thing: an encrypted file in Application Support, its key in
    /// the login Keychain.
    static func forProfile(_ profile: Profile) -> PasswordService {
        PasswordService(store: VaultCredentialStore(
            fileURL: directory(of: profile).appendingPathComponent("Passwords.sbvault"),
            keyProvider: KeychainVaultKeyProvider(account: profile.id.description)
        ))
    }

    /// For a deleted profile: the vault file and the Keychain key that opens it.
    static func deleteVault(of profile: Profile) {
        try? FileManager.default.removeItem(at: directory(of: profile))
        KeychainVaultKeyProvider(account: profile.id.description).deleteKey()
    }

    private static func directory(of profile: Profile) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SimpleBrowser/Profiles/\(profile.id)")
    }

    /// For the self-test: a vault and its key in a scratch directory, so a test
    /// run can never read, write or prompt for the user's own passwords.
    static func scratch(in directory: URL) -> PasswordService {
        PasswordService(store: VaultCredentialStore(
            fileURL: directory.appendingPathComponent("Passwords.sbvault"),
            keyProvider: FileVaultKeyProvider(url: directory.appendingPathComponent("key"))
        ))
    }

    func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Never save

    func isNeverSaved(_ origin: String) -> Bool {
        BrowserSettings.neverSavePasswordOrigins.contains(origin)
    }

    func neverSave(_ origin: String) {
        BrowserSettings.neverSavePasswordOrigins.append(origin)
        changed()
    }

    func allowSaving(_ origin: String) {
        BrowserSettings.neverSavePasswordOrigins.removeAll { $0 == origin }
        changed()
    }

    // MARK: - Checkup

    /// Weak, reused and, if `checkLeaks`, leaked passwords. Reads every
    /// password, so it asks first; nil when the person says no.
    ///
    /// A failed leak check still returns the rest, marked as unchecked for
    /// leaks, rather than failing the whole checkup or claiming none leaked.
    func checkup(checkLeaks: Bool) async throws -> PasswordAuditReport? {
        guard await authenticator.authenticate(reason: "check your saved passwords") else { return nil }
        var entries: [(credential: Credential, password: String)] = []
        for credential in try await store.all() {
            entries.append((credential, try await store.password(for: credential.id)))
        }
        guard checkLeaks, !entries.isEmpty else { return PasswordAudit.run(entries) }
        do {
            let breaches = try await breachChecker.counts(for: entries.map(\.password))
            return PasswordAudit.run(entries, breaches: breaches)
        } catch {
            return PasswordAudit.run(entries, breachCheckError: "The leak check could not reach Have I Been Pwned (\(error.localizedDescription)).")
        }
    }

    // MARK: - Import and export

    struct ImportSummary: Equatable {
        var added = 0, updated = 0, unchanged = 0, skipped = 0
    }

    func importCSV(from url: URL) async throws -> ImportSummary {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try PasswordCSV.parse(text)
        return try await importRows(parsed.rows, skipped: parsed.skipped)
    }

    /// Sign-ins from another browser, or a file: new ones added, changed
    /// ones updated, the same ones left.
    func importRows(_ rows: [PasswordCSV.Row], skipped: Int = 0) async throws -> ImportSummary {
        var summary = ImportSummary(skipped: skipped)
        var existing: [String: UUID] = [:]
        for credential in try await store.all() { existing[credential.origin + "\n" + credential.username] = credential.id }
        for row in rows {
            if let id = existing[row.origin + "\n" + row.username] {
                if try await store.password(for: id) == row.password { summary.unchanged += 1 } else { summary.updated += 1 }
            } else {
                summary.added += 1
            }
            let saved = try await store.save(origin: row.origin, username: row.username, password: row.password)
            existing[row.origin + "\n" + row.username] = saved.id
        }
        changed()
        return summary
    }

    /// Writes every password in the clear, so it asks first. The file is
    /// created readable by the owner only; it is still the user's to delete.
    func exportCSV(to url: URL, format: PasswordCSV.Format = .chrome) async throws -> Int? {
        guard await authenticator.authenticate(reason: "export your saved passwords") else { return nil }
        var rows: [PasswordCSV.Row] = []
        for credential in try await store.all().sorted(by: { ($0.site, $0.username) < ($1.site, $1.username) }) {
            rows.append(PasswordCSV.Row(origin: credential.origin, username: credential.username,
                                        password: try await store.password(for: credential.id)))
        }
        let data = Data(PasswordCSV.export(rows, format: format).utf8)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CredentialStoreError.io("could not write \(url.path)")
        }
        return rows.count
    }
}
