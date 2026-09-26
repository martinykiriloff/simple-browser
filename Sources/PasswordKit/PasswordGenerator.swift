import Foundation

/// Strong passwords for sign-up forms.
///
/// Three groups of six, `kpmwTx-r7hqzn-4bVcye`: readable, typeable on a phone
/// if it ever has to be, and accepted by the common "needs upper, lower, digit
/// and a symbol" rules. 18 characters from a 55-symbol alphabet is about 104
/// bits. Look-alikes (`l I 1 O 0 o`) are left out.
///
/// A site that says what it accepts (`PasswordRules`) gets a password drawn
/// to its rules instead, as long as the site allows.
public enum PasswordGenerator {
    static let lower = Array("abcdefghijkmnpqrstuvwxyz")
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    static let lookAlikes = Set("lI1O0o")

    /// The grouped format's length, dashes included.
    public static let defaultLength = 20

    public static func generate(rules: PasswordRules = PasswordRules()) -> String {
        var rng = SystemRandomNumberGenerator()   // cryptographically secure on Apple platforms
        return generate(rules: rules, using: &rng)
    }

    public static func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        generate(rules: PasswordRules(), using: &rng)
    }

    public static func generate<R: RandomNumberGenerator>(rules: PasswordRules, using rng: inout R) -> String {
        if rules.isUnrestricted { return grouped(using: &rng) }
        return fitted(to: rules, using: &rng)
    }

    private static func grouped<R: RandomNumberGenerator>(using rng: inout R) -> String {
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

    /// As long as the site allows, up to 20, from what it allows. Every
    /// required class is guaranteed by redrawing, never by patching.
    private static func fitted<R: RandomNumberGenerator>(to rules: PasswordRules, using rng: inout R) -> String {
        let requiredUnion = rules.required.reduce(into: Set<Character>()) { $0.formUnion($1) }
        let base = Set<Character>(lower + upper + digits)
        var allowed: Set<Character>
        if let explicit = rules.allowed {
            allowed = explicit.union(requiredUnion)
        } else {
            allowed = base.union(requiredUnion)
        }
        // Drop look-alikes only where that leaves every required class something to draw.
        let readable = allowed.subtracting(lookAlikes)
        if rules.required.allSatisfy({ !$0.intersection(readable).isEmpty }) && !readable.isEmpty { allowed = readable }
        let alphabet = Array(allowed).sorted()
        let required = rules.required.map { $0.intersection(allowed) }

        let upperBound = rules.maxLength ?? max(defaultLength, rules.minLength ?? 0)
        let length = max(min(defaultLength, upperBound), min(rules.minLength ?? 0, upperBound), required.count)
        for _ in 0..<10_000 {
            let characters = (0..<length).map { _ in alphabet.randomElement(using: &rng)! }
            guard required.allSatisfy({ set in characters.contains(where: set.contains) }) else { continue }
            if let limit = rules.maxConsecutive, longestRun(characters) > limit { continue }
            return String(characters)
        }
        // Rules no password can satisfy (a required class of nothing, say):
        // the site's own validation will explain, which is better than hanging.
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng) ?? "x" })
    }

    public static func longestRun(_ characters: [Character]) -> Int {
        var best = 0, run = 0
        var previous: Character?
        for c in characters {
            run = c == previous ? run + 1 : 1
            best = max(best, run)
            previous = c
        }
        return best
    }
}
