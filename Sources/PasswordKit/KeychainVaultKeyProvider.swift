import Foundation
import Security

/// Keeps a vault's key in the login Keychain, as "SimpleBrowser Safe Storage"
/// -- the same arrangement, and nearly the same name, as Chrome's.
///
/// This is the file-based Keychain on purpose: the data-protection Keychain
/// needs an entitlement that only a provisioned, properly signed app has, and
/// this app has to work ad-hoc signed.
public final class KeychainVaultKeyProvider: VaultKeyProvider {
    private let service: String
    private let account: String

    /// - Parameter account: distinguishes profiles; each has its own key.
    public init(service: String = "SimpleBrowser Safe Storage", account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func existingKey() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw CredentialStoreError.keyUnavailable(Self.describe(status))
        }
    }

    public func createKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CredentialStoreError.keyUnavailable("The system could not produce random bytes.")
        }
        let key = Data(bytes)
        let status = SecItemAdd(query.merging([
            kSecValueData as String: key,
            kSecAttrLabel as String: service,
            kSecAttrDescription as String: "encryption key",
            kSecAttrComment as String: "Opens the saved passwords of a SimpleBrowser profile. Deleting this makes them unreadable.",
        ]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keyUnavailable(Self.describe(status)) }
        return key
    }

    /// For tests that use a throwaway account, and for "remove everything".
    public func deleteKey() {
        SecItemDelete(query as CFDictionary)
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain: \(message) (\(status))"
    }
}
