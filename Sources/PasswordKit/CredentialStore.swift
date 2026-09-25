import Foundation

public enum CredentialStoreError: Error, Sendable, Equatable {
    case notFound
    /// The vault exists but this key does not open it. Nothing is overwritten.
    case cannotDecrypt
    case keyUnavailable(String)
    case io(String)
}

/// Where sign-ins are kept. Async because the real one may have to wait for
/// the Keychain, which can show a prompt; callers must never block on it.
public protocol CredentialStore: Sendable {
    func all() async throws -> [Credential]
    func password(for id: UUID) async throws -> String
    /// Saves a sign-in; an existing one for the same origin and username has
    /// its password replaced instead of a duplicate being made.
    @discardableResult
    func save(origin: String, username: String, password: String) async throws -> Credential
    /// Edits a sign-in in place. Nil leaves that part as it is.
    @discardableResult
    func update(_ id: UUID, username: String?, password: String?) async throws -> Credential
    func delete(_ id: UUID) async throws
    func deleteAll() async throws
    func markUsed(_ id: UUID) async throws
}

public extension CredentialStore {
    /// Sign-ins that may be offered to a page at `origin`, most recently used
    /// first, so the one filled without asking is the one used last.
    func credentials(forPage origin: String) async throws -> [Credential] {
        try await all()
            .filter { CredentialOrigin.matches(saved: $0.origin, page: origin) }
            .sorted { ($0.lastUsedAt ?? $0.modifiedAt) > ($1.lastUsedAt ?? $1.modifiedAt) }
    }
}
