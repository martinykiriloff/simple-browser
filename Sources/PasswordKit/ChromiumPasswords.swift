import Foundation
import CommonCrypto

/// Chromium's saved passwords on a Mac: "v10", then AES-128-CBC with a key
/// made from the secret the browser keeps in the Keychain ("Chrome Safe
/// Storage"): PBKDF2-SHA1 with the salt "saltysalt", 1003 rounds, and an
/// IV of sixteen spaces. The secret is asked of the Keychain, and so of
/// the person, by the app; this only turns it and a value into a password.
public enum ChromiumPasswords {
    static let prefix = Data("v10".utf8)
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    public static func key(from secret: String) -> Data? {
        let password = Array(secret.utf8)
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: CChar.self) { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress, password.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        return status == kCCSuccess ? Data(key) : nil
    }

    /// The password, or nil if it is not in this form or the secret is wrong.
    public static func decrypt(_ value: Data, key: Data) -> String? {
        guard value.count > prefix.count, value.prefix(prefix.count) == prefix else { return nil }
        guard let plain = crypt(CCOperation(kCCDecrypt), Data(value.dropFirst(prefix.count)), key: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// The same, the other way: for tests.
    public static func encrypt(_ password: String, key: Data) -> Data? {
        crypt(CCOperation(kCCEncrypt), Data(password.utf8), key: key).map { prefix + $0 }
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                input.withUnsafeBytes { i in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress, i.baseAddress, input.count, &output, output.count, &written)
                }
            }
        }
        return status == kCCSuccess ? Data(output.prefix(written)) : nil
    }
}
