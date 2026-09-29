import Foundation
import CryptoKit

// MARK: - What is kept

/// An address, for checkout and sign-up forms.
public struct AutofillAddress: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var label = ""
    public var fullName = ""
    public var organization = ""
    /// Lines of the street address, joined by newlines.
    public var street = ""
    public var city = ""
    public var region = ""
    public var postalCode = ""
    /// A two-letter code (ISO 3166-1), or a name as typed.
    public var country = ""
    public var email = ""
    public var phone = ""

    public init(label: String = "", fullName: String = "", organization: String = "", street: String = "", city: String = "",
                region: String = "", postalCode: String = "", country: String = "", email: String = "", phone: String = "") {
        self.label = label
        self.fullName = fullName
        self.organization = organization
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.email = email
        self.phone = phone
    }

    public var givenName: String { fullName.split(separator: " ").dropLast().joined(separator: " ").nonEmpty ?? fullName }
    public var familyName: String { fullName.split(separator: " ").count > 1 ? String(fullName.split(separator: " ").last!) : "" }
    public var streetLines: [String] { street.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } }

    /// How it is shown in a list: "Home — 1 Infinite Loop, Cupertino".
    public var summary: String {
        let place = [streetLines.first, city].compactMap { $0?.nonEmpty }.joined(separator: ", ")
        let name = label.nonEmpty ?? fullName.nonEmpty ?? "Address"
        return place.isEmpty ? name : "\(name) — \(place)"
    }

    /// The same address, however it was typed.
    public func isSame(as other: AutofillAddress) -> Bool {
        func key(_ a: AutofillAddress) -> String {
            [a.fullName, a.streetLines.first ?? "", a.postalCode].map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.joined(separator: "|")
        }
        return key(self) == key(other)
    }
}

/// A payment card. Its security code is never kept: forms ask for it each time.
public struct AutofillCard: Codable, Equatable, Identifiable, Sendable {
    public enum Brand: String, Codable, Sendable {
        case visa, mastercard, amex, discover, jcb, unionpay, other

        public var name: String {
            switch self {
            case .visa: return "Visa"
            case .mastercard: return "Mastercard"
            case .amex: return "American Express"
            case .discover: return "Discover"
            case .jcb: return "JCB"
            case .unionpay: return "UnionPay"
            case .other: return "Card"
            }
        }
    }

    public var id = UUID()
    public var nameOnCard = ""
    /// Digits only.
    public var number = ""
    public var expiryMonth = 0
    /// Four digits.
    public var expiryYear = 0

    public init(nameOnCard: String = "", number: String = "", expiryMonth: Int = 0, expiryYear: Int = 0) {
        self.nameOnCard = nameOnCard
        self.number = number.filter(\.isNumber)
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear < 100 && expiryYear > 0 ? 2000 + expiryYear : expiryYear
    }

    public var brand: Brand { Self.brand(of: number) }
    public var last4: String { String(number.suffix(4)) }
    /// "Visa •••• 4242".
    public var masked: String { "\(brand.name) •••• \(last4)" }
    public var expiry: String { expiryMonth > 0 ? String(format: "%02d/%02d", expiryMonth, expiryYear % 100) : "" }

    public static func brand(of number: String) -> Brand {
        let digits = number.filter(\.isNumber)
        func starts(_ prefixes: [ClosedRange<Int>], length: Int) -> Bool {
            guard let head = Int(digits.prefix(length)) else { return false }
            return prefixes.contains { $0.contains(head) }
        }
        if digits.hasPrefix("4") { return .visa }
        if starts([34...34, 37...37], length: 2) { return .amex }
        if starts([51...55], length: 2) || starts([2221...2720], length: 4) { return .mastercard }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") || starts([644...649], length: 3) { return .discover }
        if starts([3528...3589], length: 4) { return .jcb }
        if digits.hasPrefix("62") { return .unionpay }
        return .other
    }

    /// A card number that could be real: 12 to 19 digits, and the Luhn check.
    public static func isPlausible(_ number: String) -> Bool {
        let digits = number.filter(\.isNumber).compactMap(\.wholeNumberValue)
        guard (12...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, pair in
            let (index, digit) = pair
            guard index % 2 == 1 else { return total + digit }
            let doubled = digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }
}

// MARK: - Knowing a field

/// What a form field is for.
public enum AutofillFieldKind: String, Sendable, CaseIterable {
    case name, givenName, familyName, organization, email, phone
    case street, addressLine1, addressLine2, city, region, postalCode, country
    case cardName, cardNumber, cardExpiry, cardExpiryMonth, cardExpiryYear, cardSecurityCode
    case oneTimeCode

    public var isCard: Bool { [.cardName, .cardNumber, .cardExpiry, .cardExpiryMonth, .cardExpiryYear, .cardSecurityCode].contains(self) }
    public var isAddress: Bool { !isCard && self != .oneTimeCode }
}

/// A form field as the page describes it.
public struct AutofillFieldDescriptor: Equatable, Sendable {
    public var tag: String
    public var type: String
    public var autocomplete: String
    public var name: String
    public var id: String
    public var placeholder: String
    public var label: String

    public init(tag: String = "input", type: String = "text", autocomplete: String = "", name: String = "", id: String = "", placeholder: String = "", label: String = "") {
        self.tag = tag.lowercased()
        self.type = type.lowercased()
        self.autocomplete = autocomplete.lowercased()
        self.name = name
        self.id = id
        self.placeholder = placeholder
        self.label = label
    }
}

/// Tells what a field is for: from its `autocomplete` token first, as the
/// HTML standard defines them, and failing that from its name, id, label
/// and placeholder, in English and the languages of the largest shops.
public enum AutofillClassifier {
    static let tokens: [String: AutofillFieldKind] = [
        "name": .name, "given-name": .givenName, "family-name": .familyName, "organization": .organization,
        "email": .email, "tel": .phone, "tel-national": .phone,
        "street-address": .street, "address-line1": .addressLine1, "address-line2": .addressLine2,
        "address-level2": .city, "address-level1": .region, "postal-code": .postalCode,
        "country": .country, "country-name": .country,
        "cc-name": .cardName, "cc-number": .cardNumber, "cc-exp": .cardExpiry, "cc-exp-month": .cardExpiryMonth,
        "cc-exp-year": .cardExpiryYear, "cc-csc": .cardSecurityCode, "one-time-code": .oneTimeCode,
    ]

    /// Most specific first: "card number" before "number", "last name" before "name".
    static let patterns: [(AutofillFieldKind, String)] = [
        (.cardSecurityCode, "cvc|cvv|csc|security.?code|card.?verification|kartenprüf"),
        (.cardNumber, "card.?num|cc.?num|cardnumber|credit.?card|numéro.?de.?carte|kartennummer|número.?de.?tarjeta"),
        (.cardName, "name.?on.?card|card.?holder|cardholder|cc.?name|titulaire|karteninhaber"),
        (.cardExpiryMonth, "exp.*month|cc.?month|card.?month|mm$"),
        (.cardExpiryYear, "exp.*year|cc.?year|card.?year|yy(yy)?$"),
        (.cardExpiry, "expir|exp.?date|mm.?/?.?yy|valid.?thru|gültig"),
        (.oneTimeCode, "one.?time|otp|verification.?code|2fa|security.?code.*(sms|text)|auth.?code"),
        (.email, "e.?mail"),
        (.phone, "phone|mobile|tel\\b|telephone|téléphone|telefon"),
        (.organization, "company|organi[sz]ation|firma|entreprise|empresa"),
        (.givenName, "first.?name|given.?name|fname|vorname|prénom|nombre$"),
        (.familyName, "last.?name|family.?name|surname|lname|nachname|apellido"),
        (.addressLine2, "address.?(line)?.?2|addr2|apartment|apt|suite|unit\\b|adresszusatz"),
        (.addressLine1, "address.?(line)?.?1|addr1|street|straße|strasse|adresse|dirección|address"),
        (.city, "city|town|locality|ort\\b|ville|ciudad|stadt"),
        (.region, "state|province|region|county|bundesland"),
        (.postalCode, "zip|postal|post.?code|postcode|plz|código.?postal|code.?postal"),
        (.country, "country|land\\b|pays|país"),
        (.name, "full.?name|^name$|your.?name|\\bname\\b"),
    ]

    public static func kind(of field: AutofillFieldDescriptor) -> AutofillFieldKind? {
        guard !["hidden", "password", "submit", "button", "checkbox", "radio", "file", "image", "reset", "search"].contains(field.type) else { return nil }
        // "shipping postal-code", "section-1 cc-number": the last token says what it is.
        if let token = field.autocomplete.split(separator: " ").last.map(String.init), let kind = tokens[token] { return kind }
        if field.autocomplete == "off" || field.autocomplete.isEmpty || tokens[field.autocomplete] == nil {
            if field.type == "email" { return .email }
            if field.type == "tel" { return .phone }
            for text in [field.name, field.id, field.label, field.placeholder] where !text.isEmpty {
                let lowered = text.lowercased()
                for (kind, pattern) in patterns where lowered.range(of: pattern, options: .regularExpression) != nil {
                    return kind
                }
            }
        }
        return nil
    }

    /// Every field's kind, by position; nil where it is not one to fill.
    public static func kinds(of fields: [AutofillFieldDescriptor]) -> [AutofillFieldKind?] {
        var kinds = fields.map(kind(of:))
        // A form with one "address" field and a second one: the second is line 2.
        if let first = kinds.firstIndex(of: .addressLine1), let second = kinds[(first + 1)...].firstIndex(of: .addressLine1) {
            kinds[second] = .addressLine2
        }
        return kinds
    }
}

// MARK: - What goes where

public enum AutofillFill {
    /// The value for each field it can fill, by position. Selects are given
    /// the value as text; the page matches it to an option.
    public static func values(for kinds: [AutofillFieldKind?], address: AutofillAddress?, card: AutofillCard?) -> [Int: String] {
        var values: [Int: String] = [:]
        let hasSeparateNames = kinds.contains(.givenName) || kinds.contains(.familyName)
        let hasLine1 = kinds.contains(.addressLine1)
        for (index, kind) in kinds.enumerated() {
            guard let kind else { continue }
            let value: String?
            switch kind {
            case .name: value = address?.fullName
            case .givenName: value = address?.givenName
            case .familyName: value = address?.familyName
            case .organization: value = address?.organization
            case .email: value = address?.email
            case .phone: value = address?.phone
            case .street: value = hasLine1 ? address?.streetLines.first : address?.streetLines.joined(separator: ", ")
            case .addressLine1: value = address?.streetLines.first
            case .addressLine2: value = address.map { $0.streetLines.dropFirst().joined(separator: ", ") }
            case .city: value = address?.city
            case .region: value = address?.region
            case .postalCode: value = address?.postalCode
            case .country: value = address?.country
            case .cardName: value = card?.nameOnCard.nonEmpty ?? (hasSeparateNames ? nil : address?.fullName)
            case .cardNumber: value = card?.number
            case .cardExpiry: value = card?.expiry
            case .cardExpiryMonth: value = card.map { String(format: "%02d", $0.expiryMonth) }
            case .cardExpiryYear: value = card.map { String($0.expiryYear) }
            case .cardSecurityCode, .oneTimeCode: value = nil
            }
            if let value, !value.isEmpty { values[index] = value }
        }
        return values
    }

    /// What someone typed into a form, as an address and a card, for "Save?".
    public static func captured(kinds: [AutofillFieldKind?], values: [String]) -> (address: AutofillAddress?, card: AutofillCard?) {
        var address = AutofillAddress()
        var card = AutofillCard()
        var lines: [String] = []
        var given = "", family = ""
        for (kind, value) in zip(kinds, values) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind, !text.isEmpty else { continue }
            switch kind {
            case .name: address.fullName = text
            case .givenName: given = text
            case .familyName: family = text
            case .organization: address.organization = text
            case .email: address.email = text
            case .phone: address.phone = text
            case .street, .addressLine1, .addressLine2: lines.append(text)
            case .city: address.city = text
            case .region: address.region = text
            case .postalCode: address.postalCode = text
            case .country: address.country = text
            case .cardName: card.nameOnCard = text
            case .cardNumber: card.number = text.filter(\.isNumber)
            case .cardExpiry:
                let parts = text.split { !$0.isNumber }.compactMap { Int($0) }
                if parts.count == 2 { card.expiryMonth = parts[0]; card.expiryYear = parts[1] < 100 ? 2000 + parts[1] : parts[1] }
            case .cardExpiryMonth: card.expiryMonth = Int(text.filter(\.isNumber)) ?? 0
            case .cardExpiryYear:
                let year = Int(text.filter(\.isNumber)) ?? 0
                card.expiryYear = year < 100 && year > 0 ? 2000 + year : year
            case .cardSecurityCode, .oneTimeCode: continue
            }
        }
        if address.fullName.isEmpty { address.fullName = [given, family].filter { !$0.isEmpty }.joined(separator: " ") }
        address.street = lines.joined(separator: "\n")
        let hasAddress = !address.streetLines.isEmpty && (!address.city.isEmpty || !address.postalCode.isEmpty)
        let hasCard = AutofillCard.isPlausible(card.number)
        if hasCard, card.nameOnCard.isEmpty { card.nameOnCard = address.fullName }
        return (hasAddress ? address : nil, hasCard ? card : nil)
    }
}

// MARK: - Where it is kept

/// Addresses and cards in an encrypted file next to the passwords', sealed
/// with the same key: still one Keychain item, and one prompt at most.
public actor AutofillVault {
    public struct Contents: Codable, Equatable, Sendable {
        public var addresses: [AutofillAddress] = []
        public var cards: [AutofillCard] = []
        public init() {}
    }

    private static let magic = Data("SBAF1".utf8)
    private let fileURL: URL
    private let keyProvider: any VaultKeyProvider
    /// The passwords' file. While it exists a missing key is a problem to
    /// report, never a reason to make a new one: that would lock it for good.
    private let passwordVault: URL?
    private var cache: Contents?

    public init(fileURL: URL, keyProvider: any VaultKeyProvider, passwordVault: URL? = nil) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
        self.passwordVault = passwordVault
    }

    public func contents() throws -> Contents {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else { return Contents() }
        guard data.prefix(Self.magic.count) == Self.magic, let raw = try keyProvider.existingKey() else {
            throw CredentialStoreError.io("the AutoFill file cannot be opened")
        }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: raw), authenticating: Self.magic)
        let contents = try JSONDecoder().decode(Contents.self, from: plain)
        cache = contents
        return contents
    }

    public func save(_ address: AutofillAddress) throws {
        try mutate { contents in
            if let index = contents.addresses.firstIndex(where: { $0.id == address.id }) { contents.addresses[index] = address }
            else { contents.addresses.append(address) }
        }
    }

    public func save(_ card: AutofillCard) throws {
        try mutate { contents in
            if let index = contents.cards.firstIndex(where: { $0.id == card.id }) { contents.cards[index] = card }
            else { contents.cards.append(card) }
        }
    }

    public func deleteAddress(_ id: UUID) throws { try mutate { $0.addresses.removeAll { $0.id == id } } }
    public func deleteCard(_ id: UUID) throws { try mutate { $0.cards.removeAll { $0.id == id } } }

    private func mutate(_ change: (inout Contents) -> Void) throws {
        var contents = try self.contents()
        change(&contents)
        let raw: Data
        if let existing = try keyProvider.existingKey() {
            raw = existing
        } else if let passwordVault, FileManager.default.fileExists(atPath: passwordVault.path) {
            throw CredentialStoreError.keyUnavailable("The key of the saved passwords is missing from the Keychain.")
        } else {
            raw = try keyProvider.createKey()
        }
        let plain = try JSONEncoder().encode(contents)
        guard let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: raw), authenticating: Self.magic).combined else {
            throw CredentialStoreError.io("could not seal the AutoFill file")
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = fileURL.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Self.magic + sealed, attributes: [.posixPermissions: 0o600]) else {
            throw CredentialStoreError.io("could not write the AutoFill file")
        }
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        cache = contents
    }
}

extension StringProtocol {
    var nonEmpty: String? { isEmpty ? nil : String(self) }
}
