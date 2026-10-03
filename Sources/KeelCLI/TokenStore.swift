import Foundation
import Security

/// The paired token, kept in the login Keychain (generic password, service
/// "Keel CLI token", account "127.0.0.1:<port>"). A file readable only by
/// this user is the fallback when the Keychain cannot be used (a locked or
/// missing keychain, an SSH session).
enum TokenStore {
    static let service = "Keel CLI token"

    enum Source: String { case environment = "KEEL_TOKEN", keychain = "Keychain", file = "file" }

    static var fallbackFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Keel/cli-token")
    }

    static func load(_ config: Config) -> (token: String, source: Source)? {
        if let token = config.tokenOverride { return (token, .environment) }
        if let token = keychainRead(account: config.account) { return (token, .keychain) }
        if let token = fileTokens()[config.account] { return (token, .file) }
        return nil
    }

    /// Saves a token; returns where it went.
    @discardableResult
    static func save(_ token: String, for config: Config) throws -> Source {
        if keychainWrite(token, account: config.account) {
            removeFromFile(account: config.account)
            return .keychain
        }
        var tokens = fileTokens()
        tokens[config.account] = token
        try writeFile(tokens)
        return .file
    }

    /// Deletes the token for this endpoint wherever it is. True if one was there.
    @discardableResult
    static func delete(for config: Config) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: config.account]
        let fromKeychain = SecItemDelete(query as CFDictionary) == errSecSuccess
        let fromFile = removeFromFile(account: config.account)
        return fromKeychain || fromFile
    }

    // MARK: Keychain

    static func keychainRead(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    static func keychainWrite(_ token: String, account: String) -> Bool {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let data = Data(token.utf8)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Keel CLI token (\(account))"
        add[kSecAttrDescription as String] = "Token the keel command uses for Keel's agent server"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: File fallback

    static func fileTokens() -> [String: String] {
        guard let data = try? Data(contentsOf: fallbackFile), let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return value
    }

    static func writeFile(_ tokens: [String: String]) throws {
        let directory = fallbackFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if tokens.isEmpty {
            try? FileManager.default.removeItem(at: fallbackFile)
            return
        }
        let data = try JSONEncoder().encode(tokens)
        // Created 0600 before any secret is written into it.
        if !FileManager.default.fileExists(atPath: fallbackFile.path) {
            FileManager.default.createFile(atPath: fallbackFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackFile.path)
        try data.write(to: fallbackFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackFile.path)
    }

    @discardableResult
    static func removeFromFile(account: String) -> Bool {
        var tokens = fileTokens()
        guard tokens.removeValue(forKey: account) != nil else { return false }
        try? writeFile(tokens)
        return true
    }
}
