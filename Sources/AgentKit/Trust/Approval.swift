import Foundation

/// How much an action can cost the person if the agent was misled.
public enum ActionRisk: Sendable, Equatable {
    case safe
    case consequential(Kind, reason: String)

    /// The kinds of action that always need the person (PRD: "Actions that
    /// always require human approval").
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case payment, credential, purchase, send, delete, upload, download, permission, crossProfile, script

        public var label: String {
            switch self {
            case .payment: return "payments"
            case .credential: return "entering passwords"
            case .purchase: return "purchases"
            case .send: return "sending messages"
            case .delete: return "deleting data"
            case .upload: return "uploading files"
            case .download: return "downloading files"
            case .permission: return "granting site permissions"
            case .crossProfile: return "reaching another profile"
            case .script: return "running scripts in a signed-in session"
            }
        }
    }

    public var kind: Kind? {
        if case .consequential(let kind, _) = self { return kind }
        return nil
    }

    public var reason: String? {
        if case .consequential(_, let reason) = self { return reason }
        return nil
    }
}

/// What the page says about the element a tool is about to act on. The app
/// fills it from the automation agent; everything else here is pure.
public struct ElementFacts: Sendable, Equatable, Codable {
    public var role: String
    public var name: String
    /// `type` of an input or button ("password", "submit", "file").
    public var type: String?
    /// `autocomplete` of an input ("cc-number", "current-password").
    public var autocomplete: String?
    /// For a button or a submit: the form's method and action, and the
    /// autocomplete/type of the fields inside it.
    public var formMethod: String?
    public var formAction: String?
    public var formFields: [String]
    /// The element's ref in the latest snapshot.
    public var ref: String?

    public init(role: String, name: String, type: String? = nil, autocomplete: String? = nil,
                formMethod: String? = nil, formAction: String? = nil, formFields: [String] = [], ref: String? = nil) {
        self.role = role; self.name = name; self.type = type; self.autocomplete = autocomplete
        self.formMethod = formMethod; self.formAction = formAction; self.formFields = formFields; self.ref = ref
    }
}

/// Decides which tool calls are consequential. Errs on the side of asking:
/// a needless prompt costs a click, a missed one can cost money.
public enum ActionClassifier {
    static let paymentWords = ["pay", "place order", "buy", "purchase", "checkout", "check out", "confirm order", "complete order",
                               "submit order", "subscribe", "donate", "book now", "confirm payment", "upgrade", "add funds", "transfer"]
    static let sendWords = ["send", "post", "publish", "reply", "tweet", "share", "comment", "invite", "email", "message"]
    static let deleteWords = ["delete", "remove", "destroy", "erase", "discard", "drop", "archive", "unsubscribe", "cancel subscription",
                              "close account", "deactivate", "revoke", "empty trash", "wipe"]
    static let credentialWords = ["sign in", "log in", "login", "signin", "authorize", "allow access", "grant access"]
    static let paymentFields = ["cc-number", "cc-csc", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-name", "cc-type", "transaction-amount"]
    static let credentialFields = ["current-password", "new-password", "one-time-code", "password"]

    /// Risk of a call before the element is known (tools that need no element).
    public static func risk(tool: String, arguments: JSONValue, mode: SessionMode.Kind) -> ActionRisk {
        switch tool {
        case "upload_files":
            return .consequential(.upload, reason: "Uploads files from this Mac to the page.")
        case "handle_dialog":
            return .safe
        case "storage":
            let action = arguments["action"]?.string ?? "list"
            if mode == .borrowed, action != "list", action != "get" {
                return .consequential(.delete, reason: "Changes cookies or storage of your signed-in session.")
            }
            return .safe
        case "evaluate":
            return mode == .borrowed
                ? .consequential(.script, reason: "Runs JavaScript inside your signed-in session, where it can do anything you can.")
                : .safe
        case "mock_network":
            return .safe
        default:
            return .safe
        }
    }

    /// Risk of acting on an element: a click on "Place order", typing into a
    /// password field, submitting a form with card fields.
    public static func risk(tool: String, element: ElementFacts, typedText: String? = nil) -> ActionRisk {
        let name = element.name.lowercased()
        let fields = Set(element.formFields.map { $0.lowercased() })
        let isInput = ["textbox", "searchbox", "combobox", "spinbutton"].contains(element.role) || tool == "fill" || tool == "type_text"
        let autocomplete = (element.autocomplete ?? "").lowercased()
        let type = (element.type ?? "").lowercased()

        if isInput, tool != "click", tool != "hover" {
            if type == "password" || credentialFields.contains(where: { autocomplete.contains($0) }) {
                return .consequential(.credential, reason: "Types into a password field.")
            }
            if paymentFields.contains(where: { autocomplete.contains($0) }) || looksLikeCardNumber(typedText) {
                return .consequential(.payment, reason: "Types card details.")
            }
            if tool == "press_key", (typedText ?? "").lowercased() == "enter", !fields.isDisjoint(with: paymentFields) {
                return .consequential(.payment, reason: "Submits a form with card fields.")
            }
            return .safe
        }
        guard tool == "click" || tool == "press_key" || tool == "drag" else { return .safe }
        if type == "file" { return .consequential(.upload, reason: "Opens a file upload.") }
        let isButton = ["button", "link", "menuitem", "tab", "checkbox", "switch"].contains(element.role) || type == "submit"
        guard isButton || type == "submit" else { return .safe }
        if !fields.isDisjoint(with: paymentFields) || contains(name, any: paymentWords) {
            return .consequential(.payment, reason: "“\(element.name)” looks like it pays or places an order.")
        }
        if !fields.isDisjoint(with: credentialFields) || (type == "submit" && contains(name, any: credentialWords)) {
            return .consequential(.credential, reason: "Submits a sign-in form.")
        }
        if contains(name, any: deleteWords) {
            return .consequential(.delete, reason: "“\(element.name)” looks like it deletes something.")
        }
        let sends = contains(name, any: sendWords)
        let posts = (element.formMethod ?? "").lowercased() == "post"
        if sends && (posts || type == "submit" || element.role == "button") {
            return .consequential(.send, reason: "“\(element.name)” looks like it sends or publishes.")
        }
        if element.role == "link", (element.formAction ?? "").isEmpty, contains(name, any: ["download"]) {
            return .consequential(.download, reason: "Downloads a file.")
        }
        return .safe
    }

    static func contains(_ text: String, any words: [String]) -> Bool {
        let padded = " " + text.replacingOccurrences(of: "·", with: " ").replacingOccurrences(of: "-", with: " ") + " "
        return words.contains { word in
            // Whole words: "pay" is in "Pay now" but not in "Display".
            guard let range = padded.range(of: word) else { return false }
            let before = padded[padded.index(before: range.lowerBound)]
            let after = range.upperBound < padded.endIndex ? padded[range.upperBound] : " "
            return !before.isLetter && !after.isLetter
        }
    }

    /// What the log must not keep in plain text.
    public static func looksLikeSecret(_ text: String) -> Bool { looksLikeCardNumber(text) }

    /// 13–19 digits passing Luhn: a card number typed into a plain field.
    public static func looksLikeCardNumber(_ text: String?) -> Bool {
        guard let text else { return false }
        let digits = text.filter(\.isNumber).compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), text.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 { let doubled = digit * 2; sum += doubled > 9 ? doubled - 9 : doubled } else { sum += digit }
        }
        return sum % 10 == 0
    }
}

/// Per-origin rules from Settings → Agents: "Ask" is the default for any
/// origin not listed.
public struct OriginRules: Codable, Sendable, Equatable {
    public enum Rule: String, Codable, Sendable, CaseIterable {
        case ask, allow, never
        public var label: String { rawValue.capitalized }
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var origin: String
        public var rule: Rule
        public var expires: Date?
        public var id: String { origin }

        public init(origin: String, rule: Rule, expires: Date? = nil) {
            self.origin = Origin.normalize(origin); self.rule = rule; self.expires = expires
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public func rule(for origin: String, now: Date = Date()) -> Rule? {
        let origin = Origin.normalize(origin)
        let live = entries.filter { $0.expires.map { $0 > now } ?? true }
        if let exact = live.first(where: { $0.origin == origin }) { return exact.rule }
        if let wildcard = live.first(where: { $0.origin.hasPrefix("*.") && Origin.matches(origin, pattern: $0.origin) }) { return wildcard.rule }
        return NeverLendable.contains(origin) ? .never : nil
    }

    public mutating func set(_ origin: String, _ rule: Rule, expires: Date? = nil) {
        let entry = Entry(origin: origin, rule: rule, expires: expires)
        if let index = entries.firstIndex(where: { $0.origin == entry.origin }) { entries[index] = entry } else { entries.append(entry) }
    }

    public mutating func remove(_ origin: String) {
        entries.removeAll { $0.origin == Origin.normalize(origin) }
    }
}

/// Email, banking and password managers are never lent to an agent, whatever
/// the person picks: a hijacked agent there costs too much.
public enum NeverLendable {
    static let hosts = [
        "mail.google.com", "accounts.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
        "mail.yahoo.com", "mail.proton.me", "account.proton.me", "app.fastmail.com", "icloud.com", "www.icloud.com",
        "appleid.apple.com", "account.apple.com", "login.microsoftonline.com",
        "paypal.com", "www.paypal.com", "wise.com", "revolut.com", "app.revolut.com",
        "vault.bitwarden.com", "my.1password.com", "lastpass.com", "keepersecurity.com", "dashlane.com",
        "coinbase.com", "www.coinbase.com", "binance.com", "kraken.com",
    ]
    static let hostWords = ["bank", "banking", "unicreditbank", "creditunion"]

    public static func contains(_ origin: String) -> Bool {
        let host = Origin.normalize(origin).split(separator: ":").first.map(String.init) ?? ""
        if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if host.hasPrefix("mail.") || host.hasPrefix("webmail.") { return true }
        let labels = host.split(separator: ".").dropLast()
        return labels.contains { label in hostWords.contains { label.contains($0) } }
    }
}
