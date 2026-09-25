import Foundation
import CryptoKit

/// Supplies the 256-bit key that opens a vault.
public protocol VaultKeyProvider: Sendable {
    /// The stored key, or nil if there is none yet.
    func existingKey() throws -> Data?
    /// Makes, stores and returns a new key. Only called for a brand-new vault.
    func createKey() throws -> Data
}

/// Sign-ins in one encrypted file per profile, the way Chrome keeps them on
/// macOS: the file lives in Application Support, and only its key is in the
/// Keychain. One Keychain item means at most one Keychain prompt, where an
/// item per password would mean one prompt per password after every update
/// of an ad-hoc signed app.
///
/// Unlike Chrome's, the whole file is encrypted (AES-256-GCM), not just the
/// password column: which sites you have accounts on, and under what names,
/// is nobody's business either.
///
/// It fails closed. A vault that cannot be opened -- wrong key, damaged file
/// -- is never overwritten: every call throws until the problem is fixed.
public actor VaultCredentialStore: CredentialStore {

    private struct Record: Codable {
        var credential: Credential
        var password: String
    }

    private struct Contents: Codable {
        var version = 1
        var records: [Record] = []
    }

    /// Identifies the format, and is authenticated along with the ciphertext.
    private static let magic = Data("SBPV1".utf8)

    private let fileURL: URL
    private let keyProvider: any VaultKeyProvider
    private var key: SymmetricKey?
    private var cache: Contents?
    private var cacheStamp: Stamp?

    private struct Stamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    public init(fileURL: URL, keyProvider: any VaultKeyProvider) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    // MARK: - CredentialStore

    public func all() throws -> [Credential] {
        try load().records.map(\.credential)
    }

    public func password(for id: UUID) throws -> String {
        guard let record = try load().records.first(where: { $0.credential.id == id }) else {
            throw CredentialStoreError.notFound
        }
        return record.password
    }

    @discardableResult
    public func save(origin: String, username: String, password: String) throws -> Credential {
        try mutate { contents in
            let now = Date()
            if let index = contents.records.firstIndex(where: { $0.credential.origin == origin && $0.credential.username == username }) {
                if contents.records[index].password != password {
                    contents.records[index].password = password
                    contents.records[index].credential.modifiedAt = now
                }
                return contents.records[index].credential
            }
            let credential = Credential(origin: origin, username: username, createdAt: now, modifiedAt: now)
            contents.records.append(Record(credential: credential, password: password))
            return credential
        }
    }

    @discardableResult
    public func update(_ id: UUID, username: String?, password: String?) throws -> Credential {
        try mutate { contents in
            guard let index = contents.records.firstIndex(where: { $0.credential.id == id }) else {
                throw CredentialStoreError.notFound
            }
            if let username, username != contents.records[index].credential.username {
                // Renaming onto another saved account would leave two entries
                // for one sign-in; the renamed one wins, as the newer intent.
                let origin = contents.records[index].credential.origin
                contents.records.removeAll { $0.credential.id != id && $0.credential.origin == origin && $0.credential.username == username }
                guard let moved = contents.records.firstIndex(where: { $0.credential.id == id }) else { throw CredentialStoreError.notFound }
                contents.records[moved].credential.username = username
                contents.records[moved].credential.modifiedAt = Date()
                if let password { contents.records[moved].password = password }
                return contents.records[moved].credential
            }
            if let password, password != contents.records[index].password {
                contents.records[index].password = password
                contents.records[index].credential.modifiedAt = Date()
            }
            return contents.records[index].credential
        }
    }

    public func delete(_ id: UUID) throws {
        try mutate { contents in contents.records.removeAll { $0.credential.id == id } }
    }

    public func deleteAll() throws {
        try mutate { contents in contents.records.removeAll() }
    }

    public func markUsed(_ id: UUID) throws {
        try mutate { contents in
            guard let index = contents.records.firstIndex(where: { $0.credential.id == id }) else { return }
            contents.records[index].credential.lastUsedAt = Date()
        }
    }

    // MARK: - File

    private func stamp() -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
        return Stamp(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue)
    }

    /// Re-reads the file when another window's process has changed it.
    private func load() throws -> Contents {
        let current = stamp()
        if let cache, current == cacheStamp { return cache }
        guard current != nil else {
            let empty = Contents()
            cache = empty
            cacheStamp = nil
            return empty
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw CredentialStoreError.io(error.localizedDescription) }
        guard data.starts(with: Self.magic) else { throw CredentialStoreError.cannotDecrypt }
        guard let key = try existingKey() else {
            throw CredentialStoreError.keyUnavailable("The passwords file exists but its key is not in the Keychain.")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
            let plain = try AES.GCM.open(box, using: key, authenticating: Self.magic)
            let contents = try JSONDecoder().decode(Contents.self, from: plain)
            cache = contents
            cacheStamp = current
            return contents
        } catch {
            throw CredentialStoreError.cannotDecrypt
        }
    }

    private func mutate<T>(_ change: (inout Contents) throws -> T) throws -> T {
        // Start from the file, not the cache, so another process's writes
        // are kept. `load` throws for a vault that cannot be opened, which is
        // what stops it being overwritten with an empty one.
        var contents = try load()
        let result = try change(&contents)
        try write(contents)
        return result
    }

    private func write(_ contents: Contents) throws {
        let key = try existingKey() ?? newKey()
        do {
            let plain = try JSONEncoder().encode(contents)
            guard let sealed = try AES.GCM.seal(plain, using: key, authenticating: Self.magic).combined else {
                throw CredentialStoreError.io("could not seal the vault")
            }
            let manager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Born private, then renamed into place: never world-readable,
            // and never half-written.
            let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
            guard manager.createFile(atPath: temporary.path, contents: Self.magic + sealed, attributes: [.posixPermissions: 0o600]) else {
                throw CredentialStoreError.io("could not write \(temporary.path)")
            }
            if rename(temporary.path, fileURL.path) != 0 {
                let reason = String(cString: strerror(errno))
                try? manager.removeItem(at: temporary)
                throw CredentialStoreError.io("could not replace the vault: \(reason)")
            }
        } catch let error as CredentialStoreError {
            throw error
        } catch {
            throw CredentialStoreError.io(error.localizedDescription)
        }
        cache = contents
        cacheStamp = stamp()
    }

    // MARK: - Key

    private func existingKey() throws -> SymmetricKey? {
        if let key { return key }
        guard let data = try keyProvider.existingKey() else { return nil }
        guard data.count == 32 else { throw CredentialStoreError.keyUnavailable("The stored key is not 256 bits.") }
        key = SymmetricKey(data: data)
        return key
    }

    private func newKey() throws -> SymmetricKey {
        // Only reachable when there is no vault file, or the file opened with
        // an existing key; `load` has already refused every other case.
        let data = try keyProvider.createKey()
        guard data.count == 32 else { throw CredentialStoreError.keyUnavailable("The new key is not 256 bits.") }
        let created = SymmetricKey(data: data)
        key = created
        return created
    }
}

/// A key held in memory or in a file. For tests and the self-test only: a key
/// next to the vault it opens protects nothing.
public final class FileVaultKeyProvider: VaultKeyProvider {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func existingKey() throws -> Data? {
        try? Data(contentsOf: url)
    }

    public func createKey() throws -> Data {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.write(to: url, options: .atomic)
        return key
    }
}
