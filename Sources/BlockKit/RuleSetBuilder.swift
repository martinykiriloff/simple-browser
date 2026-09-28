import Foundation
import CryptoKit

/// Everything between downloaded filter lists and what is handed to
/// `WKContentRuleListStore`: parse, put in canonical order, split into lists
/// WebKit will take, and name them so an unchanged set is never compiled twice.
public enum RuleSetBuilder {

    /// Bump when the conversion changes, so rule lists compiled by an older
    /// version of the converter are not taken for current.
    public static let converterVersion = 1

    /// Action rules per compiled list. Far under WebKit's 150,000: smaller
    /// lists compile faster, and when WebKit rejects one, less has to be
    /// searched for the rule it did not like.
    public static let actionsPerList = 30_000

    public struct Built: Sendable {
        public var actions: [ContentRule]
        public var exceptions: [ContentRule]
        public var networkFilters: Int
        public var cosmeticFilters: Int
        public var exceptionFilters: Int
        public var skipped: [FilterParser.Skip: Int]

        public var ruleCount: Int { actions.count + exceptions.count }
        public var skippedTotal: Int { skipped.values.reduce(0, +) }

        /// The lists to compile: each with every exception at its end.
        public func lists(actionsPerList: Int = RuleSetBuilder.actionsPerList) -> [[ContentRule]] {
            guard !actions.isEmpty else { return [] }
            return stride(from: 0, to: actions.count, by: actionsPerList).map { start in
                Array(actions[start ..< min(start + actionsPerList, actions.count)]) + exceptions
            }
        }
    }

    /// The lists are parsed as one text: an exception in one list has to be
    /// able to excuse a filter in another.
    ///
    /// - Parameter rejected: see `FilterParser.parse(_:rejecting:)`.
    public static func build(texts: [String], rejecting rejected: Set<String>? = nil) -> Built {
        let parsed = FilterParser.parse(texts.joined(separator: "\n"), rejecting: rejected)
        return Built(actions: parsed.rules.filter { !$0.isException }, exceptions: parsed.rules.filter(\.isException),
                     networkFilters: parsed.networkFilters, cosmeticFilters: parsed.cosmeticFilters,
                     exceptionFilters: parsed.exceptions, skipped: parsed.skipped)
    }

    public static func selectors(in texts: [String]) -> [String] {
        FilterParser.selectors(in: texts.joined(separator: "\n"))
    }

    public static func json(_ rules: [ContentRule]) throws -> String {
        String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
    }

    /// Names the compiled result of these list files. Same files, same
    /// converter: same name, and the compiled lists on disk are still good.
    public static func fingerprint(of texts: [String]) -> String {
        var hash = SHA256()
        hash.update(data: Data("converter \(converterVersion)\n".utf8))
        for text in texts {
            hash.update(data: Data("\(text.utf8.count)\n".utf8))
            hash.update(data: Data(text.utf8))
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a downloaded file is a filter list at all, and whole. A
    /// captive portal's sign-in page, or half a download, must not replace
    /// a list that works.
    public static func looksLikeFilterList(_ text: String) -> Bool {
        let head = text.prefix(4000).lowercased()
        if head.contains("<html") || head.contains("<!doctype") { return false }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 5 else { return false }
        return head.contains("[adblock") || lines.prefix(200).contains { $0.hasPrefix("!") || $0.hasPrefix("||") || $0.contains("##") }
    }
}
