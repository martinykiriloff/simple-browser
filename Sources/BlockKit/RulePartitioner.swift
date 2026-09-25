import Foundation

/// Splits a rule set into compilable chunks for `WKContentRuleListStore`.
///
/// Three WebKit behaviours drive this design:
///
/// 1. A single compiled `WKContentRuleList` is capped at 150,000 rules.
/// 2. Several lists may be added to one `WKUserContentController`; each is
///    evaluated **independently** and the results are unioned.
/// 3. `ignore-previous-rules` cancels earlier matching actions **within its own
///    compiled list only**. It cannot reach across lists.
///
/// Together these mean every exception must be replicated into every chunk.
/// Naive slicing drops exceptions into one chunk and silently breaks whitelists
/// for every action rule that landed elsewhere -- see `RulePartitionerTests`.
public enum RulePartitioner {

    /// WebKit's hard cap on rules per compiled list.
    public static let maxRulesPerList = 150_000

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Exceptions alone consume the entire budget.
        case unsatisfiable(exceptionCount: Int, limit: Int)
        /// An action rule follows an exception rule, so partitioning would
        /// change its meaning. See `canonicalized(_:)`.
        case notCanonical(index: Int)

        public var description: String {
            switch self {
            case let .unsatisfiable(count, limit):
                return "\(count) exception rules leave no room for action rules "
                     + "(limit \(limit)). Narrow the filter-list selection."
            case let .notCanonical(index):
                return "Action rule at index \(index) follows an "
                     + "ignore-previous-rules rule. Partitioning would change its "
                     + "meaning. Call canonicalized(_:) first -- and only if these "
                     + "rules were converted from ABP syntax."
            }
        }
    }

    /// Hoists every exception to the tail, preserving relative order otherwise.
    ///
    /// - Important: Valid **only** for rules converted from ABP syntax, where
    ///   `@@` exceptions are position-independent and always defeat a matching
    ///   block. Applying this to hand-authored WebKit JSON -- where rule order
    ///   is significant -- changes behaviour.
    public static func canonicalized(_ rules: [ContentRule]) -> [ContentRule] {
        rules.filter { !$0.isException } + rules.filter(\.isException)
    }

    /// Throws unless no action rule follows an exception rule.
    public static func validateCanonical(_ rules: [ContentRule]) throws {
        var sawException = false
        for (index, rule) in rules.enumerated() {
            if rule.isException {
                sawException = true
            } else if sawException {
                throw Failure.notCanonical(index: index)
            }
        }
    }

    /// Partitions `rules` into chunks of at most `limit` rules each, replicating
    /// every exception into every chunk.
    ///
    /// - Throws: `Failure.notCanonical` if the input is not in canonical form,
    ///           `Failure.unsatisfiable` if exceptions exhaust the budget.
    public static func partition(
        _ rules: [ContentRule],
        limit: Int = maxRulesPerList
    ) throws -> [[ContentRule]] {
        precondition(limit > 0, "limit must be positive")
        try validateCanonical(rules)

        let actions    = rules.filter { !$0.isException }
        let exceptions = rules.filter(\.isException)

        guard !actions.isEmpty else {
            return exceptions.isEmpty ? [] : [exceptions]
        }

        let capacity = limit - exceptions.count
        guard capacity >= 1 else {
            throw Failure.unsatisfiable(exceptionCount: exceptions.count, limit: limit)
        }

        return stride(from: 0, to: actions.count, by: capacity).map { start in
            Array(actions[start ..< min(start + capacity, actions.count)]) + exceptions
        }
    }
}
