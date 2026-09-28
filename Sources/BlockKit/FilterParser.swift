import Foundation

/// Converts filter lists in Adblock Plus syntax (EasyList, EasyPrivacy and
/// their relatives) into WebKit content-blocker rules.
///
/// WebKit's rules are less expressive than the lists', so conversion is
/// conservative: a filter that cannot be expressed exactly is left out and
/// counted, never approximated into something that blocks more than its
/// author meant. A page that breaks is worse than an ad that shows.
public enum FilterParser {

    /// Why a line produced no rule.
    public enum Skip: String, Sendable, CaseIterable {
        /// `/regex/` filters: WebKit accepts only a small regex subset.
        case regex
        /// An option WebKit has no counterpart for (`redirect=`, `csp=`, …).
        case unsupportedOption
        /// Scriptlets, extended CSS and HTML filtering.
        case unsupportedCosmetic
        /// A selector WebKit's CSS parser would reject, taking the list with it.
        case invalidSelector
        /// Includes and excludes mixed (`domain=a.com|~b.a.com`); WebKit
        /// allows `if-domain` or `unless-domain`, not both.
        case mixedDomains
        /// Characters or domain forms (`example.*`) WebKit cannot take.
        case unrepresentable
        /// Too short to be anything but a mistake: it would match everything.
        case tooBroad
    }

    public struct Result: Sendable {
        /// In canonical order: every exception after every action rule,
        /// which is what `RulePartitioner` requires.
        public var rules: [ContentRule] = []
        public var networkFilters = 0
        public var cosmeticFilters = 0
        public var exceptions = 0
        public var skipped: [Skip: Int] = [:]

        public var skippedTotal: Int { skipped.values.reduce(0, +) }
    }

    /// How many generic hiding selectors share one rule. One rule per
    /// selector would triple the rule count for nothing.
    ///
    /// Sharing has a price, measured: WebKit compiles a rule whose selector
    /// list has one selector its CSS parser rejects, and then the whole rule
    /// hides nothing. So selectors only share a rule once every one of them
    /// has been accepted by WebKit's own parser (`selectors(in:)`, then
    /// `parse(_:rejecting:)`); unchecked, each gets a rule to itself.
    static let selectorsPerRule = 50

    /// Between the selectors that share a rule. A line break is white space
    /// to CSS and cannot occur inside a filter, which is one line, so a
    /// shared rule can always be taken apart again exactly.
    public static let selectorSeparator = ",\n"

    /// The rules a shared hiding rule was made of, one selector each; nil
    /// for any other rule. For when WebKit refuses the shared rule: the
    /// selector it does not like is then one of these.
    public static func separated(_ rule: ContentRule) -> [ContentRule]? {
        guard rule.action.type == .cssDisplayNone, let selector = rule.action.selector, selector.contains(selectorSeparator) else { return nil }
        return selector.components(separatedBy: selectorSeparator).map {
            ContentRule(trigger: rule.trigger, action: .init(type: .cssDisplayNone, selector: $0))
        }
    }

    /// Every selector the text would hide with, once each, for checking
    /// against a real CSS parser before `parse(_:rejecting:)`.
    public static func selectors(in text: String) -> [String] {
        var seen: Set<String> = []
        var found: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), let cosmetic = splitCosmetic(line), cosmetic.marker == "##",
                  isPlainSelector(cosmetic.selector), seen.insert(cosmetic.selector).inserted else { continue }
            found.append(cosmetic.selector)
        }
        return found
    }

    /// - Parameter rejected: selectors a CSS parser refused; nil when none
    ///   were checked, in which case no two selectors share a rule.
    public static func parse(_ text: String, rejecting rejected: Set<String>? = nil) -> Result {
        let perRule = rejected == nil ? 1 : selectorsPerRule
        var result = Result()
        var blocks: [ContentRule] = []
        var exceptions: [ContentRule] = []
        var genericSelectors: [String] = []
        var seenGeneric: Set<String> = []
        var scopedHides: [(selector: String, include: [String], exclude: [String])] = []
        // selector → domains where it must stay visible (`domain#@#selector`).
        var unhide: [String: Set<String>] = [:]
        var unhideEverywhere: Set<String> = []

        func skip(_ reason: Skip) { result.skipped[reason, default: 0] += 1 }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !line.hasPrefix("#!") else { continue }

            if let cosmetic = splitCosmetic(line) {
                guard cosmetic.marker == "##" || cosmetic.marker == "#@#" else { skip(.unsupportedCosmetic); continue }
                if cosmetic.marker == "##", rejected?.contains(cosmetic.selector) == true { skip(.invalidSelector); continue }
                guard isPlainSelector(cosmetic.selector) else {
                    skip(cosmetic.selector.hasPrefix("+js(") || cosmetic.selector.contains(":has-text(") || cosmetic.selector.contains(":-abp-")
                         ? .unsupportedCosmetic : .invalidSelector)
                    continue
                }
                guard let domains = splitDomains(cosmetic.domains, separator: ",") else { skip(.unrepresentable); continue }
                if cosmetic.marker == "#@#" {
                    // `~domain#@#sel` means nothing useful; only includes count.
                    if domains.include.isEmpty { unhideEverywhere.insert(cosmetic.selector) }
                    else { unhide[cosmetic.selector, default: []].formUnion(domains.include) }
                    result.exceptions += 1
                    continue
                }
                result.cosmeticFilters += 1
                if domains.include.isEmpty && domains.exclude.isEmpty {
                    if seenGeneric.insert(cosmetic.selector).inserted { genericSelectors.append(cosmetic.selector) }
                } else {
                    scopedHides.append((cosmetic.selector, domains.include, domains.exclude))
                }
                continue
            }

            switch network(line) {
            case .failure(let reason):
                skip(reason.skip)
            case .success(let rules):
                if rules.first?.isException == true {
                    result.exceptions += 1
                    exceptions += rules
                } else {
                    result.networkFilters += 1
                    blocks += rules
                }
            }
        }

        // Element hiding. A selector excepted everywhere is dropped; one
        // excepted on some sites stays out of the shared groups and gets a
        // rule of its own that leaves those sites alone.
        var grouped: [String] = []
        var hides: [ContentRule] = []
        for selector in genericSelectors where !unhideEverywhere.contains(selector) {
            if let sites = unhide[selector] {
                hides.append(ContentRule(trigger: .init(urlFilter: ".*", unlessDomain: sites.sorted().map { "*" + $0 }),
                                         action: .init(type: .cssDisplayNone, selector: selector)))
            } else {
                grouped.append(selector)
            }
        }
        for start in stride(from: 0, to: grouped.count, by: perRule) {
            let selectors = grouped[start ..< min(start + perRule, grouped.count)]
            hides.append(ContentRule(trigger: .init(urlFilter: ".*"),
                                     action: .init(type: .cssDisplayNone, selector: selectors.joined(separator: selectorSeparator))))
        }
        for hide in scopedHides where !unhideEverywhere.contains(hide.selector) {
            let excepted = unhide[hide.selector] ?? []
            if !hide.include.isEmpty {
                guard hide.exclude.isEmpty else { skip(.mixedDomains); result.cosmeticFilters -= 1; continue }
                let sites = hide.include.filter { !excepted.contains($0) }
                guard !sites.isEmpty else { continue }
                hides.append(ContentRule(trigger: .init(urlFilter: ".*", ifDomain: sites.map { "*" + $0 }),
                                         action: .init(type: .cssDisplayNone, selector: hide.selector)))
            } else {
                let sites = Set(hide.exclude).union(excepted).sorted()
                hides.append(ContentRule(trigger: .init(urlFilter: ".*", unlessDomain: sites.map { "*" + $0 }),
                                         action: .init(type: .cssDisplayNone, selector: hide.selector)))
            }
        }

        result.rules = hides + blocks + exceptions
        return result
    }

    // MARK: - Cosmetic filters

    static func splitCosmetic(_ line: String) -> (domains: String, marker: String, selector: String)? {
        // Longest markers first: "#@#" contains "##"'s first character.
        for marker in ["#@?#", "#@$#", "#@%#", "#?#", "#$#", "#%#", "#@#", "##"] {
            guard let range = line.range(of: marker) else { continue }
            let domains = String(line[..<range.lowerBound])
            // What precedes the marker must be a domain list, or this is a
            // network filter that happens to contain "##".
            guard domains.allSatisfy({ $0.isLetter || $0.isNumber || ".-,~*".contains($0) }) else { continue }
            return (domains, marker, String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Standard CSS only. WebKit compiles a whole list or none of it, so one
    /// selector in a dialect it does not speak would cost every other rule.
    public static func isPlainSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 1000, !selector.hasPrefix("+js(") else { return false }
        let dialect = [":has-text(", ":contains(", ":-abp-", ":xpath(", ":matches-css", ":matches-path(", ":matches-attr(", ":matches-media(",
                       ":min-text-length(", ":upward(", ":remove(", ":style(", ":watch-attr(", ":nth-ancestor(", ":others(", ":spath(",
                       ":if(", ":if-not(", ":matches-property(", ":remove-attr(", ":remove-class("]
        if dialect.contains(where: selector.contains) { return false }
        if selector.contains("{") || selector.contains("}") || selector.contains("\\") && selector.contains("\n") { return false }
        var depth = 0, square = 0
        var quote: Character?
        var previous: Character?
        for character in selector {
            defer { previous = character }
            if let open = quote {
                if character == open && previous != "\\" { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(": depth += 1
            case ")": depth -= 1
            case "[": square += 1
            case "]": square -= 1
            default: break
            }
            if depth < 0 || square < 0 { return false }
        }
        return depth == 0 && square == 0 && quote == nil
    }

    // MARK: - Domains

    /// `a.com,~b.com` → includes and excludes, lowercased. Nil when a domain
    /// cannot be given to WebKit (`example.*`, non-ASCII).
    static func splitDomains(_ list: String, separator: Character) -> (include: [String], exclude: [String])? {
        var include: [String] = [], exclude: [String] = []
        for part in list.split(separator: separator) {
            var domain = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard !domain.isEmpty else { continue }
            guard isDomain(domain) else { return nil }
            if negated { exclude.append(domain) } else { include.append(domain) }
        }
        return (include, exclude)
    }

    static func isDomain(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix(".") && !text.hasSuffix(".") && !text.hasPrefix("-")
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }

    // MARK: - Network filters

    struct Failure: Error { let skip: Skip }

    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "xmlhttprequest": "fetch", "xhr": "fetch", "subdocument": "document", "frame": "document",
        "font": "font", "media": "media", "websocket": "websocket", "ping": "ping", "beacon": "ping",
        "other": "other", "popup": "popup", "document": "document", "doc": "document",
    ]
    /// Everything but documents: what a filter with no type option applies
    /// to, besides frames.
    private static let subresourceTypes = ["image", "style-sheet", "script", "font", "media", "fetch", "websocket", "ping", "other"]
    private static let ignorableOptions: Set<String> = ["important", "first-party-only"]
    /// Options that exist but have no counterpart in WebKit. Knowing them
    /// by name is also what tells an option list from a "$" in an address.
    private static let unsupportedOptions: Set<String> = [
        "redirect", "redirect-rule", "csp", "removeparam", "rewrite", "replace", "header", "badfilter", "genericblock", "generichide",
        "elemhide", "ehide", "ghide", "specifichide", "shide", "all", "inline-script", "inline-font", "object", "object-subrequest",
        "webrtc", "empty", "mp4", "cookie", "denyallow", "to", "method", "permissions", "strict1p", "strict3p", "popunder", "app",
        "network", "urltransform", "jsonprune", "xmlprune", "stealth", "extension", "content", "jsinject", "urlblock", "uritransform",
    ]
    private static let otherOptions: Set<String> = ["domain", "from", "third-party", "3p", "first-party", "1p", "match-case"]

    private static func isOption(_ part: Substring) -> Bool {
        var name = part.lowercased()
        if name.hasPrefix("~") { name.removeFirst() }
        if let equals = name.firstIndex(of: "=") { name = String(name[..<equals]) }
        return resourceTypes[name] != nil || ignorableOptions.contains(name) || unsupportedOptions.contains(name) || otherOptions.contains(name)
    }

    static func network(_ original: String) -> Swift.Result<[ContentRule], Failure> {
        var line = original
        let isException = line.hasPrefix("@@")
        if isException { line.removeFirst(2) }

        var options: [String] = []
        // Addresses may contain "$" themselves, so the options start at the
        // first "$" after which every part is an option by name. (Only the
        // first part is checked strictly: an option's value, such as a
        // csp=, may itself contain commas.)
        var search = line.startIndex
        while let dollar = line[search...].firstIndex(of: "$") {
            search = line.index(after: dollar)
            let tail = line[search...]
            guard dollar != line.startIndex, let head = tail.split(separator: ",").first, isOption(head) else { continue }
            options = tail.split(separator: ",").map { String($0).lowercased() }
            line = String(line[..<dollar])
            break
        }

        if line.count > 1, line.hasPrefix("/"), line.hasSuffix("/") { return .failure(.init(skip: .regex)) }

        var types: [String] = [], excludedTypes: [String] = []
        var loadType: [String]?
        var include: [String] = [], exclude: [String] = []
        var caseSensitive: Bool?
        var wholeDocument = false
        for option in options {
            let negated = option.hasPrefix("~")
            let name = negated ? String(option.dropFirst()) : option
            if name.hasPrefix("domain=") || name.hasPrefix("from=") {
                let list = option[option.index(after: option.firstIndex(of: "=")!)...]
                guard let domains = splitDomains(String(list), separator: "|") else { return .failure(.init(skip: .unrepresentable)) }
                include += domains.include
                exclude += domains.exclude
            } else if name == "third-party" || name == "3p" {
                loadType = [negated ? "first-party" : "third-party"]
            } else if name == "first-party" || name == "1p" {
                loadType = [negated ? "third-party" : "first-party"]
            } else if name == "match-case" {
                caseSensitive = true
            } else if name == "document" || name == "doc", isException {
                wholeDocument = true     // `@@||site^$document`: leave this site alone
            } else if let type = resourceTypes[name] {
                if negated { excludedTypes.append(type) } else { types.append(type) }
            } else if ignorableOptions.contains(name) {
                continue
            } else {
                return .failure(.init(skip: .unsupportedOption))
            }
        }
        guard include.isEmpty || exclude.isEmpty else { return .failure(.init(skip: .mixedDomains)) }

        guard let filter = urlFilter(line) else { return .failure(.init(skip: .unrepresentable)) }
        // "ad" would match half the web. The lists do not contain such
        // filters on purpose; a truncated download might.
        let literal = line.filter { $0.isLetter || $0.isNumber }
        if literal.count < 3 && include.isEmpty && !wholeDocument { return .failure(.init(skip: .tooBroad)) }

        var trigger = ContentRule.Trigger(urlFilter: filter, urlFilterIsCaseSensitive: caseSensitive)
        if !include.isEmpty { trigger.ifDomain = include.map { "*" + $0 } }
        if !exclude.isEmpty { trigger.unlessDomain = exclude.map { "*" + $0 } }
        trigger.loadType = loadType

        if isException {
            if wholeDocument {
                // Everything loaded by pages of the site the filter names.
                guard let host = hostOfAnchoredFilter(line) else { return .failure(.init(skip: .unrepresentable)) }
                return .success([ContentRule(trigger: .init(urlFilter: ".*", ifDomain: ["*" + host]), action: .init(type: .ignorePreviousRules))])
            }
            if !types.isEmpty { trigger.resourceType = Array(Set(types)).sorted() }
            else if !excludedTypes.isEmpty { trigger.resourceType = (subresourceTypes + ["document"]).filter { !excludedTypes.contains($0) } }
            return .success([ContentRule(trigger: trigger, action: .init(type: .ignorePreviousRules))])
        }

        if !types.isEmpty {
            trigger.resourceType = Array(Set(types)).sorted()
            // In the lists "subdocument" is a frame. WebKit's "document" is
            // also the page itself, which is never third-party to itself:
            // asking for third-party loads keeps the rule to frames.
            if trigger.resourceType == ["document"], !options.contains("document"), !options.contains("doc"), trigger.loadType == nil {
                trigger.loadType = ["third-party"]
            }
            return .success([ContentRule(trigger: trigger, action: .init(type: .block))])
        }

        // No type named: everything a page loads, but never the page itself.
        // A filter like "/ads/" must not make a site with /ads/ in its
        // address unreachable.
        if trigger.loadType == ["third-party"] {
            // The page is never third-party, so one rule says it all.
            if !excludedTypes.isEmpty { trigger.resourceType = (subresourceTypes + ["document"]).filter { !excludedTypes.contains($0) } }
            return .success([ContentRule(trigger: trigger, action: .init(type: .block))])
        }
        var resources = trigger
        resources.resourceType = subresourceTypes.filter { !excludedTypes.contains($0) }
        var rules = [ContentRule(trigger: resources, action: .init(type: .block))]
        if trigger.loadType == nil, !excludedTypes.contains("document") {
            var frames = trigger
            frames.resourceType = ["document"]
            frames.loadType = ["third-party"]
            rules.append(ContentRule(trigger: frames, action: .init(type: .block)))
        }
        return .success(rules)
    }

    /// `||example.com^` → `example.com`.
    static func hostOfAnchoredFilter(_ filter: String) -> String? {
        guard filter.hasPrefix("||") else { return nil }
        let host = filter.dropFirst(2).prefix { $0 != "^" && $0 != "/" && $0 != "*" && $0 != "|" }.lowercased()
        return isDomain(host) && host.contains(".") ? host : nil
    }

    /// The filter as the regular expression WebKit wants. Its subset has no
    /// alternation and no counted repeats, which is all this needs to avoid.
    public static func urlFilter(_ filter: String) -> String? {
        var text = Substring(filter)
        guard text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        var pattern = ""
        if text.hasPrefix("||") {
            // Any scheme, any subdomains.
            pattern = "^[^:]+://+([^:/]+\\.)?"
            text = text.dropFirst(2)
        } else if text.hasPrefix("|") {
            pattern = "^"
            text = text.dropFirst()
        }
        var anchoredEnd = false
        if text.hasSuffix("|") {
            anchoredEnd = true
            text = text.dropLast()
        }
        // Leading and trailing stars say nothing.
        while text.hasPrefix("*") { text = text.dropFirst() }
        while text.hasSuffix("*"), !anchoredEnd { text = text.dropLast() }
        guard !text.isEmpty || !pattern.isEmpty else { return nil }

        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            switch character {
            case "*":
                if !pattern.hasSuffix(".*") { pattern += ".*" }
            case "^":
                // A separator: anything that is not part of a name. At the
                // end of a filter the address may simply end there.
                pattern += index == characters.count - 1 && !anchoredEnd ? "([/:?#&=].*)?$" : "[/:?#&=]"
            case ".", "+", "?", "$", "{", "}", "(", ")", "[", "]", "\\", "/", "|":
                pattern += "\\" + String(character)
            default:
                pattern.append(character)
            }
        }
        if anchoredEnd { pattern += "$" }
        return pattern.isEmpty ? nil : pattern
    }
}

/// A filter list the browser knows where to get.
public struct FilterList: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let name: String
    public let about: String
    public let url: URL
    public let onByDefault: Bool

    public init(id: String, name: String, about: String, url: URL, onByDefault: Bool) {
        self.id = id
        self.name = name
        self.about = about
        self.url = url
        self.onByDefault = onByDefault
    }

    public static let all: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", about: "Ads",
                   url: URL(string: "https://easylist.to/easylist/easylist.txt")!, onByDefault: true),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", about: "Trackers and analytics",
                   url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, onByDefault: true),
        FilterList(id: "cookies", name: "EasyList Cookie List", about: "Cookie banners",
                   url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!, onByDefault: false),
        FilterList(id: "annoyances", name: "Fanboy's Annoyances", about: "Newsletter pop-ups, social widgets, in-page notices",
                   url: URL(string: "https://secure.fanboy.co.nz/fanboy-annoyance.txt")!, onByDefault: false),
    ]
}

/// The sites a person switched blocking off for. Matching is by site, so
/// turning it off on `news.example.com` also covers `www.news.example.com`.
public enum BlockingAllowlist {
    public static func normalized(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public static func contains(_ host: String?, in sites: [String]) -> Bool {
        guard let host = host.map(normalized), !host.isEmpty else { return false }
        return sites.contains { site in host == site || host.hasSuffix("." + site) }
    }
}
