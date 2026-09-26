import Foundation

/// What a site accepts as a password: the field's `minlength` and `maxlength`,
/// plus the `passwordrules` attribute Safari and 1Password read
/// (`required: upper; required: digit; allowed: [-_]; max-consecutive: 2;
/// minlength: 8; maxlength: 16;`).
///
/// A generated password the site rejects is worse than none: the sign-up
/// fails, or, when `maxlength` silently truncates, the site keeps a password
/// different from the one that was saved.
public struct PasswordRules: Equatable, Sendable {
    /// Each entry must be represented by at least one character.
    public var required: [Set<Character>] = []
    /// Nil means "anything the generator likes".
    public var allowed: Set<Character>?
    public var minLength: Int?
    public var maxLength: Int?
    /// No run of the same character longer than this.
    public var maxConsecutive: Int?

    public init() {}

    public static let upper = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    public static let lower = Set("abcdefghijklmnopqrstuvwxyz")
    public static let digit = Set("0123456789")
    /// The "special" class as Apple's spec defines it, less the space, which
    /// no one wants to find at the end of a password they cannot see.
    public static let special = Set("-~!@#$%^&*_+=`|(){}[:;\"'<>,.?]/")

    /// Nothing that restricts the default generator.
    public var isUnrestricted: Bool {
        required.isEmpty && allowed == nil && maxConsecutive == nil
            && (maxLength ?? .max) >= PasswordGenerator.defaultLength && (minLength ?? 0) <= PasswordGenerator.defaultLength
    }

    /// - Parameters:
    ///   - attribute: the `passwordrules` value, or empty.
    ///   - minLength, maxLength: the field's own limits; HTML reports -1 or 0 for "none".
    /// Unknown clauses are skipped rather than failing the whole attribute:
    /// the parts that are understood still make a better password.
    public static func parse(_ attribute: String, minLength: Int? = nil, maxLength: Int? = nil) -> PasswordRules {
        var rules = PasswordRules()
        for clause in attribute.split(separator: ";") {
            let parts = clause.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch name {
            case "required":
                if let set = characterClass(value), !set.isEmpty { rules.required.append(set) }
            case "allowed":
                if let set = characterClass(value) { rules.allowed = (rules.allowed ?? []).union(set) }
            case "minlength":
                if let n = Int(value), n > 0 { rules.minLength = max(rules.minLength ?? 0, n) }
            case "maxlength":
                if let n = Int(value), n > 0 { rules.maxLength = min(rules.maxLength ?? .max, n) }
            case "max-consecutive":
                if let n = Int(value), n > 0 { rules.maxConsecutive = n }
            default:
                continue
            }
        }
        if let n = minLength, n > 0 { rules.minLength = max(rules.minLength ?? 0, n) }
        if let n = maxLength, n > 0 { rules.maxLength = min(rules.maxLength ?? .max, n) }
        return rules
    }

    /// `upper, digit, [-_.]`: named classes and bracketed characters, joined.
    public static func characterClass(_ text: String) -> Set<Character>? {
        var set = Set<Character>()
        var rest = Substring(text)
        while !rest.isEmpty {
            rest = rest.drop { $0 == "," || $0 == " " }
            if rest.first == "[" {
                // `]` and `-` may appear first inside the brackets, per the spec.
                var body = rest.dropFirst()
                var chars: [Character] = []
                if body.first == "]" { chars.append("]"); body = body.dropFirst() }
                guard let close = body.firstIndex(of: "]") else { return nil }
                chars.append(contentsOf: body[..<close])
                set.formUnion(chars)
                rest = body[body.index(after: close)...]
                continue
            }
            let word = rest.prefix { $0 != "," && $0 != " " }
            rest = rest.dropFirst(word.count)
            switch word.lowercased() {
            case "upper": set.formUnion(upper)
            case "lower": set.formUnion(lower)
            case "digit": set.formUnion(digit)
            case "special": set.formUnion(special)
            case "ascii-printable", "unicode": set.formUnion(upper.union(lower).union(digit).union(special))
            case "": continue
            default: return nil
            }
        }
        return set
    }
}
