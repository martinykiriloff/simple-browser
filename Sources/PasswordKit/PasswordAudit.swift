import Foundation
import CryptoKit

/// Why a password is easy to guess. Deliberately a short list of things a
/// person can act on, not a score: "weak" with no reason teaches nothing.
public enum PasswordWeakness: Hashable, Sendable {
    case tooShort
    case common
    case singleKind
    case pattern
    case containsUsername
    case containsSiteName

    public var explanation: String {
        switch self {
        case .tooShort:         return "shorter than 8 characters"
        case .common:           return "one of the most common passwords"
        case .singleKind:       return "only one kind of character"
        case .pattern:          return "a repeated or keyboard pattern"
        case .containsUsername: return "contains the username"
        case .containsSiteName: return "contains the site’s name"
        }
    }
}

public enum PasswordStrength {
    /// Nothing here is a reason on its own to call a long random password
    /// weak: every rule checks for something an attacker's first guesses
    /// would include.
    public static func weaknesses(of password: String, username: String = "", origin: String = "") -> [PasswordWeakness] {
        var found: [PasswordWeakness] = []
        let lowered = password.lowercased()
        if password.count < 8 { found.append(.tooShort) }

        // "Password1!" is "password" to anyone guessing.
        let core = String(lowered.drop { !$0.isLetter && !$0.isNumber }.reversed().drop { !$0.isLetter }.reversed())
        if commonPasswords.contains(lowered) || (core.count >= 4 && commonPasswords.contains(core)) { found.append(.common) }

        let kinds = [password.contains(where: \.isLowercase), password.contains(where: \.isUppercase),
                     password.contains(where: \.isNumber), password.contains { !$0.isLetter && !$0.isNumber }]
        if kinds.filter({ $0 }).count == 1 && password.count < 16 { found.append(.singleKind) }

        if isPattern(lowered) { found.append(.pattern) }

        let user = username.lowercased().split(separator: "@").first.map(String.init) ?? ""
        if user.count >= 3 && lowered.contains(user) { found.append(.containsUsername) }

        let host = CredentialOrigin.site(of: origin).split(separator: ":").first.map(String.init) ?? ""
        let labels = host.split(separator: ".").map(String.init)
        // The registrable-ish name: "mail.example.co.uk" → "example".
        if let name = labels.dropLast().max(by: { $0.count < $1.count }), name.count >= 4, name != "www", lowered.contains(name) {
            found.append(.containsSiteName)
        }
        return found
    }

    public static func isWeak(_ password: String, username: String = "", origin: String = "") -> Bool {
        !weaknesses(of: password, username: username, origin: origin).isEmpty
    }

    /// One character repeated, a run up or down the alphabet or digits, or a
    /// keyboard row, for the whole password.
    static func isPattern(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 4 else { return false }
        if Set(scalars).count <= 2 { return true }
        let steps = zip(scalars, scalars.dropFirst()).map { Int($1.value) - Int($0.value) }
        if Set(steps).count == 1, let step = steps.first, abs(step) <= 1 { return true }
        return ["qwertyuiop", "asdfghjkl", "zxcvbnm", "1qaz2wsx", "qazwsx"].contains { row in
            row.contains(text) || String(row.reversed()).contains(text)
        }
    }

    /// The most common passwords in public breach corpora, lower-cased.
    static let commonPasswords: Set<String> = [
        "123456", "password", "12345678", "qwerty", "123456789", "12345", "1234", "111111", "1234567",
        "dragon", "123123", "baseball", "abc123", "football", "monkey", "letmein", "696969", "shadow",
        "master", "666666", "qwertyuiop", "123321", "mustang", "1234567890", "michael", "654321",
        "superman", "1qaz2wsx", "7777777", "121212", "000000", "qazwsx", "123qwe", "killer", "trustno1",
        "jordan", "jennifer", "zxcvbnm", "asdfgh", "hunter", "buster", "soccer", "harley", "batman",
        "andrew", "tigger", "sunshine", "iloveyou", "2000", "charlie", "robert", "thomas", "hockey",
        "ranger", "daniel", "starwars", "klaster", "112233", "george", "computer", "michelle", "jessica",
        "pepper", "1111", "zxcvbn", "555555", "11111111", "131313", "freedom", "777777", "pass", "maggie",
        "159753", "aaaaaa", "ginger", "princess", "joshua", "cheese", "amanda", "summer", "love", "ashley",
        "nicole", "chelsea", "biteme", "matthew", "access", "yankees", "987654321", "dallas", "austin",
        "thunder", "taylor", "matrix", "admin", "welcome", "login", "passw0rd", "p@ssw0rd", "p@ssword",
        "qwerty123", "password1", "password123", "abc12345", "changeme", "secret", "hello", "whatever",
        "letmein1", "welcome1", "admin123", "root", "toor", "guest", "default", "test", "test123",
    ]
}

/// A saved sign-in the checkup has something to say about.
public struct PasswordIssue: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Found in a public breach this many times.
        case compromised(Int)
        /// The same password is saved for these other sites.
        case reused([String])
        case weak([PasswordWeakness])
    }
    public let credential: Credential
    public let kinds: [Kind]

    /// Worst first: a leaked password is being tried against every site now.
    public var severity: Int {
        kinds.map { kind in
            switch kind { case .compromised: return 3; case .reused: return 2; case .weak: return 1 }
        }.max() ?? 0
    }
}

public struct PasswordAuditReport: Sendable {
    public let issues: [PasswordIssue]
    public let checked: Int
    /// Nil when the leak check did not run (off, or offline): the report
    /// must not read as "none leaked" when nobody looked.
    public let breachCheckError: String?
    public let breachChecked: Bool

    public var compromised: Int { issues.filter { $0.kinds.contains { if case .compromised = $0 { return true } else { return false } } }.count }
    public var reused: Int { issues.filter { $0.kinds.contains { if case .reused = $0 { return true } else { return false } } }.count }
    public var weak: Int { issues.filter { $0.kinds.contains { if case .weak = $0 { return true } else { return false } } }.count }
}

public enum PasswordAudit {
    /// - Parameter breaches: times each password was seen in a breach, for
    ///   the passwords that were checked. Absent means unknown, not safe.
    public static func run(_ entries: [(credential: Credential, password: String)],
                           breaches: [String: Int]? = nil, breachCheckError: String? = nil) -> PasswordAuditReport {
        var sitesByPassword: [String: [String]] = [:]
        for entry in entries { sitesByPassword[entry.password, default: []].append(entry.credential.site) }

        var issues: [PasswordIssue] = []
        for entry in entries {
            var kinds: [PasswordIssue.Kind] = []
            if let count = breaches?[entry.password], count > 0 { kinds.append(.compromised(count)) }
            var others = sitesByPassword[entry.password] ?? []
            if let mine = others.firstIndex(of: entry.credential.site) { others.remove(at: mine) }
            // Two accounts on one site sharing a password is still reuse.
            if !others.isEmpty { kinds.append(.reused(Array(Set(others)).sorted())) }
            let weak = PasswordStrength.weaknesses(of: entry.password, username: entry.credential.username, origin: entry.credential.origin)
            if !weak.isEmpty { kinds.append(.weak(weak)) }
            if !kinds.isEmpty { issues.append(PasswordIssue(credential: entry.credential, kinds: kinds)) }
        }
        issues.sort { ($0.severity, $1.credential.site, $1.credential.username) > ($1.severity, $0.credential.site, $0.credential.username) }
        return PasswordAuditReport(issues: issues, checked: entries.count, breachCheckError: breachCheckError,
                                   breachChecked: breaches != nil)
    }
}

/// Have I Been Pwned's Pwned Passwords range API, used the k-anonymous way:
/// only the first five hex characters of a password's SHA-1 leave the Mac,
/// and the match against the returned suffixes happens here. Padding is
/// requested so the response size does not give the prefix's hit count away.
public struct PwnedPasswords: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = PwnedPasswords.defaultFetch) {
        self.fetch = fetch
    }

    /// No cookies, no cache, no credentials: nothing identifies the asker
    /// beyond the address the request comes from.
    public static let defaultFetch: Fetch = { request in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    public enum CheckError: Error, Equatable, Sendable {
        case http(Int)
    }

    /// Times each password appears in known breaches; 0 for not found.
    /// One request per distinct prefix, however many passwords share it.
    public func counts(for passwords: [String]) async throws -> [String: Int] {
        var byPrefix: [String: [(password: String, suffix: String)]] = [:]
        for password in Set(passwords) {
            let hash = Self.sha1Hex(password)
            byPrefix[String(hash.prefix(5)), default: []].append((password, String(hash.dropFirst(5))))
        }
        var result: [String: Int] = [:]
        for (prefix, members) in byPrefix {
            var request = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
            request.setValue("true", forHTTPHeaderField: "Add-Padding")
            request.setValue("Keel password checkup", forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await fetch(request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw CheckError.http(http.statusCode) }
            let table = Self.parse(range: String(decoding: data, as: UTF8.self))
            for member in members { result[member.password] = table[member.suffix] ?? 0 }
        }
        return result
    }

    public static func sha1Hex(_ password: String) -> String {
        Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// `SUFFIX:COUNT` per line. Padding lines carry a count of 0.
    public static func parse(range body: String) -> [String: Int] {
        var table: [String: Int] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            guard parts.count == 2, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            table[parts[0].trimmingCharacters(in: .whitespaces).uppercased()] = count
        }
        return table
    }
}
