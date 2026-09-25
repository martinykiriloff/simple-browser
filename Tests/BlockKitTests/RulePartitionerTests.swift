import XCTest
@testable import BlockKit

/// A model of WebKit's content-blocker evaluation, used as an oracle.
///
/// Deliberately simplistic on matching (substring instead of the real regex
/// subset) -- what is being tested is *ordering and partitioning semantics*,
/// not WebKit's URL matcher.
enum Oracle {
    static func matches(_ rule: ContentRule, url: String, domain: String) -> Bool {
        guard url.contains(rule.trigger.urlFilter) else { return false }
        if let domains = rule.trigger.ifDomain, !domains.contains(domain) { return false }
        return true
    }

    /// One compiled list: rules apply in order; an exception clears what precedes it.
    static func evaluate(
        list: [ContentRule], url: String, domain: String
    ) -> Set<ContentRule.ActionType> {
        var accumulated: Set<ContentRule.ActionType> = []
        for rule in list where matches(rule, url: url, domain: domain) {
            if rule.isException { accumulated.removeAll() }
            else { accumulated.insert(rule.action.type) }
        }
        return accumulated
    }

    /// Several lists on one controller: independent evaluation, union of results.
    static func evaluate(
        lists: [[ContentRule]], url: String, domain: String
    ) -> Set<ContentRule.ActionType> {
        lists.reduce(into: Set<ContentRule.ActionType>()) {
            $0.formUnion(evaluate(list: $1, url: url, domain: domain))
        }
    }
}

// MARK: - Fixtures

private func block(_ filter: String, _ domains: [String]? = nil) -> ContentRule {
    ContentRule(trigger: .init(urlFilter: filter, ifDomain: domains),
                action: .init(type: .block))
}

private func hide(_ filter: String, _ selector: String) -> ContentRule {
    ContentRule(trigger: .init(urlFilter: filter),
                action: .init(type: .cssDisplayNone, selector: selector))
}

private func allow(_ filter: String, _ domains: [String]? = nil) -> ContentRule {
    ContentRule(trigger: .init(urlFilter: filter, ifDomain: domains),
                action: .init(type: .ignorePreviousRules))
}

/// The obvious-but-wrong implementation, kept so the regression stays visible.
private func naiveSlice(_ rules: [ContentRule], _ limit: Int) -> [[ContentRule]] {
    stride(from: 0, to: rules.count, by: limit).map {
        Array(rules[$0 ..< min($0 + limit, rules.count)])
    }
}

// MARK: - Tests

final class RulePartitionerTests: XCTestCase {

    func testExceptionIsReplicatedIntoEveryChunk() throws {
        let rules = [block("/ads/"), block("/track/"), block("/pixel/"),
                     allow("/ads/", ["good.com"])]
        let chunks = try RulePartitioner.partition(rules, limit: 3)

        XCTAssertGreaterThan(chunks.count, 1, "fixture must actually split")
        for chunk in chunks {
            XCTAssertTrue(chunk.contains { $0.isException },
                          "every chunk must carry the exception")
        }
        XCTAssertEqual(
            Oracle.evaluate(lists: chunks, url: "https://good.com/ads/x.js", domain: "good.com"),
            Oracle.evaluate(list: rules,   url: "https://good.com/ads/x.js", domain: "good.com")
        )
    }

    /// Guards the regression: without replication the whitelist silently fails.
    func testNaiveSlicingBreaksWhitelists() {
        let rules = [block("/ads/"), block("/track/"), block("/pixel/"),
                     allow("/ads/", ["good.com"])]
        let url = "https://good.com/ads/x.js"

        XCTAssertEqual(Oracle.evaluate(list: rules, url: url, domain: "good.com"), [])
        XCTAssertEqual(
            Oracle.evaluate(lists: naiveSlice(rules, 3), url: url, domain: "good.com"),
            [.block],
            "naive slicing is expected to leak a block past the whitelist"
        )
    }

    func testChunksRespectTheLimit() throws {
        let rules = (0..<10).map { block("/a\($0)/") } + [allow("/a3/"), allow("/a7/")]
        let chunks = try RulePartitioner.partition(rules, limit: 6)

        XCTAssertEqual(chunks.count, 3)                       // ceil(10 / (6 - 2))
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 6) }
    }

    func testExceptionsExhaustingBudgetThrows() {
        let rules = [block("/x/")] + (0..<5).map { allow("/e\($0)/") }
        XCTAssertThrowsError(try RulePartitioner.partition(rules, limit: 5)) { error in
            XCTAssertEqual(error as? RulePartitioner.Failure,
                           .unsatisfiable(exceptionCount: 5, limit: 5))
        }
    }

    func testNonCanonicalInputIsRejected() {
        // An action *after* an exception: hoisting would flip the outcome.
        let rules = [allow("/ads/"), block("/ads/")]
        XCTAssertThrowsError(try RulePartitioner.partition(rules, limit: 50)) { error in
            XCTAssertEqual(error as? RulePartitioner.Failure, .notCanonical(index: 1))
        }
    }

    func testCanonicalizationMatchesABPSemantics() {
        // In ABP, `@@` always wins regardless of position.
        let rules = RulePartitioner.canonicalized([allow("/ads/"), block("/ads/")])
        XCTAssertEqual(
            Oracle.evaluate(list: rules, url: "https://x.com/ads/a.js", domain: "x.com"),
            [], "exception must win after canonicalization"
        )
    }

    func testOnlyExceptionsProducesSingleChunk() throws {
        let chunks = try RulePartitioner.partition([allow("/a/"), allow("/b/")], limit: 10)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 2)
    }

    func testEmptyInput() throws {
        XCTAssertTrue(try RulePartitioner.partition([], limit: 10).isEmpty)
    }

    /// Differential test: partitioned evaluation must equal single-list
    /// evaluation for every probe, across many randomly generated rule sets.
    func testDifferentialAgainstSingleListEvaluation() throws {
        var rng = SeededGenerator(seed: 7)
        let fragments = ["/ads/", "/track/", "/pixel/", "/beacon/", "/cdn/"]
        let domains   = ["good.com", "bad.com", "news.org"]

        for _ in 0..<3_000 {
            var rules: [ContentRule] = []
            for _ in 0..<Int.random(in: 4...14, using: &rng) {
                let fragment = fragments.randomElement(using: &rng)!
                let domain: [String]? = Bool.random(using: &rng)
                    ? [domains.randomElement(using: &rng)!] : nil
                switch Double.random(in: 0..<1, using: &rng) {
                case ..<0.55: rules.append(block(fragment, domain))
                case ..<0.80: rules.append(hide(fragment, ".ad"))
                default:      rules.append(allow(fragment, domain))
                }
            }

            rules = RulePartitioner.canonicalized(rules)
            let limit = Int.random(in: 3...8, using: &rng)
            guard limit - rules.filter(\.isException).count >= 1 else { continue }

            let chunks = try RulePartitioner.partition(rules, limit: limit)
            for fragment in fragments {
                for domain in domains {
                    let url = "https://\(domain)\(fragment)z.js"
                    XCTAssertEqual(
                        Oracle.evaluate(lists: chunks, url: url, domain: domain),
                        Oracle.evaluate(list: rules,   url: url, domain: domain),
                        "mismatch for \(url) with limit \(limit)"
                    )
                }
            }
        }
    }
}

/// Deterministic RNG so a failure is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
