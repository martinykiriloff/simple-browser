import Foundation

/// Strong passwords for sign-up forms.
///
/// Three groups of six, `kpmwTx-r7hqzn-4bVcye`: readable, typeable on a phone
/// if it ever has to be, and accepted by the common "needs upper, lower, digit
/// and a symbol" rules. 18 characters from a 55-symbol alphabet is about 104
/// bits. Look-alikes (`l I 1 O 0 o`) are left out.
public enum PasswordGenerator {
    static let lower = Array("abcdefghijkmnpqrstuvwxyz")
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")

    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()   // cryptographically secure on Apple platforms
        return generate(using: &rng)
    }

    public static func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let alphabet = lower + upper + digits
        while true {
            let characters = (0..<18).map { _ in alphabet.randomElement(using: &rng)! }
            // Reject and redraw rather than patching characters in, which
            // would make some positions more predictable than others.
            guard characters.contains(where: lower.contains),
                  characters.contains(where: upper.contains),
                  characters.contains(where: digits.contains) else { continue }
            return stride(from: 0, to: 18, by: 6).map { String(characters[$0..<$0 + 6]) }.joined(separator: "-")
        }
    }
}
