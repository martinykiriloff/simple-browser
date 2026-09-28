import Foundation
import BlockKit

// Unit checks for BlockKit, as a plain executable: `swift run BlockKitChecks`.
// (Tests/BlockKitTests holds the partitioner's oracle tests for machines with XCTest.)

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
}

/// As the app parses: every selector checked (here, none refused).
func rules(_ line: String) -> [ContentRule] { FilterParser.parse(line, rejecting: []).rules }
func first(_ line: String) -> ContentRule? { rules(line).first }

/// Whether a converted url-filter matches an address. NSRegularExpression is
/// a superset of WebKit's subset, so this checks meaning, not acceptance;
/// acceptance is checked by compiling in the app.
func matches(_ filter: String, _ url: String) -> Bool {
    guard let pattern = FilterParser.urlFilter(filter),
          let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
    return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
}

// MARK: Addresses

check("|| matches the site", matches("||ads.example.com^", "https://ads.example.com/banner.js"))
check("|| matches its subdomains, however deep", matches("||example.com^", "https://a.b.example.com/x"))
check("|| matches any scheme", matches("||example.com^", "wss://example.com/socket"))
check("|| does not match a longer name", !matches("||example.com^", "https://example.community/"))
check("|| does not match a name that ends the same", !matches("||example.com^", "https://notexample.com/"))
check("|| does not match the name in a path", !matches("||example.com^", "https://evil.test/?u=https://example.com/"))
check("|| does not match the name in a query of another site", !matches("||ads.com^", "https://site.test/page?ref=ads.com/"))
check("a separator at the end matches the end of the address", matches("/banner^", "https://site.test/banner"))
check("…and a separator character", matches("/banner^", "https://site.test/banner?x=1"))
check("…but not a longer word", !matches("/banner^", "https://site.test/banners"))
check("a star matches anything", matches("/ads/*/banner", "https://site.test/ads/2026/09/banner.png"))
check("dots are literal", !matches("ads.js", "https://site.test/adsxjs"))
check("| anchors the start", matches("|https://cdn.", "https://cdn.site.test/") && !matches("|https://cdn.", "https://site.test/?https://cdn."))
check("| anchors the end", matches(".swf|", "https://site.test/a.swf") && !matches(".swf|", "https://site.test/a.swf?x"))
check("question marks and pluses are literal", matches("/ad?size=", "https://site.test/ad?size=1") && !matches("/ad?size=", "https://site.test/asize="))
check("non-ASCII filters are left out", FilterParser.urlFilter("||пример.рф^") == nil)
let patterns = ["||example.com^", "/banner^", "/ads/*/x", "|https://a", ".swf|", "a|b", "x(1)[2]{3}"].compactMap(FilterParser.urlFilter)
check("no pattern uses what WebKit's subset lacks: alternation, counted repeats",
      patterns.allSatisfy { pattern in
          let bare = pattern.replacingOccurrences(of: "\\|", with: "").replacingOccurrences(of: "\\{", with: "").replacingOccurrences(of: "\\}", with: "")
          return !bare.contains("|") && !bare.contains("{")
      }, patterns)

// MARK: Network filters

check("comments, headers and blank lines are nothing", rules("! Title: x\n[Adblock Plus 2.0]\n\n   \n").isEmpty)
let plain = rules("/ads/banner.")
check("a plain filter blocks what pages load, never the page itself", plain.count == 2 && plain[0].action.type == .block
      && plain[0].trigger.resourceType?.contains("document") == false && plain[0].trigger.resourceType?.contains("script") == true, plain)
check("…and frames only when they are third-party", plain.count == 2 && plain[1].trigger.resourceType == ["document"] && plain[1].trigger.loadType == ["third-party"])
let third = rules("||tracker.example^$third-party")
check("third-party is one rule: the page is never third-party to itself", third.count == 1 && third[0].trigger.loadType == ["third-party"] && third[0].trigger.resourceType == nil, third)
check("~third-party is first-party", first("||cdn.example^$~third-party")?.trigger.loadType == ["first-party"])
check("types are translated", first("||x.example^$script,image,stylesheet,xmlhttprequest")?.trigger.resourceType == ["fetch", "image", "script", "style-sheet"])
check("subdocument means frames, not the page", first("||x.example^$subdocument")?.trigger.resourceType == ["document"] && first("||x.example^$subdocument")?.trigger.loadType == ["third-party"])
check("a negated type leaves the others", first("||x.example^$~image")?.trigger.resourceType?.contains("image") == false
      && first("||x.example^$~image")?.trigger.resourceType?.contains("script") == true)
check("domain= becomes if-domain, with subdomains", first("/ad.js$domain=news.example|blog.example")?.trigger.ifDomain == ["*news.example", "*blog.example"])
check("domain=~ becomes unless-domain", first("/ad.js$domain=~news.example")?.trigger.unlessDomain == ["*news.example"])
check("match-case", first("/Ad.js$match-case")?.trigger.urlFilterIsCaseSensitive == true)
check("a dollar inside a filter is not an option list", first("/path$money/x.js")?.trigger.urlFilter.contains("\\$money") == true, first("/path$money/x.js")?.trigger.urlFilter as Any)

let skipped = FilterParser.parse("""
/^https?:\\/\\/ads\\./
||x.example^$redirect=noop.js
||x.example^$csp=script-src 'none'
||x.example^$removeparam=utm_source
/ad.js$domain=a.example|~b.a.example
/ad.js$domain=example.*
ad
""")
check("what cannot be said exactly is left out, and counted by reason", skipped.rules.isEmpty && skipped.skipped[.regex] == 1
      && skipped.skipped[.unsupportedOption] == 3 && skipped.skipped[.mixedDomains] == 1 && skipped.skipped[.tooBroad] == 1
      && skipped.skipped[.unrepresentable] == 1, skipped.skipped)
check("a star in the address is a filter like any other", first("||example.*^$script") != nil)
check("from= is domain=", first("/ad.js$from=news.example")?.trigger.ifDomain == ["*news.example"])

// MARK: Exceptions

let exception = rules("@@||cdn.example^$script")
check("@@ is ignore-previous-rules", exception.count == 1 && exception[0].isException && exception[0].trigger.resourceType == ["script"])
let site = rules("@@||news.example^$document")
check("@@…$document leaves the whole site alone", site.count == 1 && site[0].isException && site[0].trigger.urlFilter == ".*" && site[0].trigger.ifDomain == ["*news.example"], site)
let mixed = FilterParser.parse("@@||good.example^\n||bad.example^\n##.ad\n@@||fine.example^$image\n||worse.example^$third-party")
check("the result is canonical: every exception after every action rule", (try? RulePartitioner.validateCanonical(mixed.rules)) != nil, mixed.rules.map(\.action.type))
check("counts", mixed.networkFilters == 2 && mixed.exceptions == 2 && mixed.cosmeticFilters == 1, mixed)

// Acceptance: exceptions keep working across partitions.
var many = (0..<40).map { "||ads\($0).example^$third-party" }
many.append("@@||ads7.example^$third-party")
many.append("@@||ads33.example^$third-party")
let parsed = FilterParser.parse(many.joined(separator: "\n"))
let parts = (try? RulePartitioner.partition(parsed.rules, limit: 12)) ?? []
check("partitioned into several lists", parts.count == 4, parts.map(\.count))
check("every list carries every exception", parts.allSatisfy { $0.filter(\.isException).count == 2 })
check("every list is within the limit", parts.allSatisfy { $0.count <= 12 })
check("no action rule is lost or repeated", parts.flatMap { $0.filter { !$0.isException } }.count == 40)
func blocked(_ url: String, in lists: [[ContentRule]]) -> Bool {
    lists.contains { list in
        var blocking = false
        for rule in list {
            guard let regex = try? NSRegularExpression(pattern: rule.trigger.urlFilter, options: [.caseInsensitive]),
                  regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
            blocking = !rule.isException
        }
        return blocking
    }
}
check("a blocked site is blocked whichever list it landed in", blocked("https://ads33.example/x.js", in: [Array(parsed.rules.filter { !$0.isException })]) && blocked("https://ads20.example/x.js", in: parts))
check("an excepted site is let through by every list", !blocked("https://ads7.example/x.js", in: parts) && !blocked("https://ads33.example/x.js", in: parts))
let naive = stride(from: 0, to: parsed.rules.count, by: 12).map { Array(parsed.rules[$0 ..< min($0 + 12, parsed.rules.count)]) }
check("…which slicing without the partitioner gets wrong", blocked("https://ads7.example/x.js", in: naive))

// MARK: Hiding

let generic = rules("##.ad-banner\n##.sponsored\n##.ad-banner")
check("generic selectors share a rule, once each", generic.count == 1 && generic[0].action.type == .cssDisplayNone
      && generic[0].action.selector == ".ad-banner,\n.sponsored" && generic[0].trigger.urlFilter == ".*", generic)
check("a shared rule comes apart into its selectors, commas inside them intact",
      FilterParser.separated(rules("##:is(.a, .b)\n##[title=\"x, y\"]\n##.c")[0])?.map(\.action.selector) == [":is(.a, .b)", "[title=\"x, y\"]", ".c"])
check("a rule with one selector does not come apart", FilterParser.separated(rules("##:is(.a, .b)")[0]) == nil)
check("a site's selector is for that site", first("news.example,blog.example##.promo")?.trigger.ifDomain == ["*news.example", "*blog.example"])
check("~site is everywhere but there", first("~news.example##.promo")?.trigger.unlessDomain == ["*news.example"])
let excepted = rules("##.ad\n##.banner\nnews.example#@#.ad")
check("an exception takes its selector out of the shared rule", excepted.contains { $0.action.selector == ".banner" && $0.trigger.unlessDomain == nil }
      && excepted.contains { $0.action.selector == ".ad" && $0.trigger.unlessDomain == ["*news.example"] }, excepted)
check("an exception everywhere drops the selector", rules("##.ad\n#@#.ad").isEmpty)
check("an exception for the only site drops the rule", rules("news.example##.promo\nnews.example#@#.promo").isEmpty)
let unchecked = FilterParser.parse("##.ad\n##.banner").rules
check("unchecked selectors never share a rule: one bad one would silence the rest", unchecked.count == 2 && unchecked.allSatisfy { $0.action.selector?.contains(",") == false }, unchecked)
let refused = FilterParser.parse("##.ad\n##.bad:pseudo(1)\nnews.example##.bad:pseudo(1)\n##.banner", rejecting: [".bad:pseudo(1)"])
check("a refused selector is left out wherever it appears, and counted", refused.rules.count == 1 && refused.rules[0].action.selector == ".ad,\n.banner"
      && refused.skipped[.invalidSelector] == 2, refused)
check("selectors to check are listed once each, dialects left out", FilterParser.selectors(in: "##.ad\nnews.example##.ad\n##.x:has-text(y)\n#@#.ok\n||net.example^\n##.banner") == [".ad", ".banner"])
let chunks = rules((0..<120).map { "##.ad-\($0)" }.joined(separator: "\n"))
check("120 selectors are three rules", chunks.count == 3 && chunks[2].action.selector?.components(separatedBy: FilterParser.selectorSeparator).count == 20)

let dialects = FilterParser.parse("""
example.com##+js(set-constant, ads, false)
example.com#?#.post:-abp-has(.sponsored)
example.com##.post:has-text(Sponsored)
example.com#$#body { overflow: auto !important; }
example.com#%#window.ads = false;
##.unbalanced[data-x="1"
##.open(paren
""")
check("scriptlets, extended CSS and broken selectors are left out", dialects.rules.isEmpty && dialects.skippedTotal == 7, dialects.skipped)
check("standard selectors with brackets, quotes and :has pass", ["a[href^=\"https://ads.\"]", "div:has(> .ad)", "#ad_1 > li:nth-child(2)", "[class*='sponsor']", "a[title=\"(ad)\"]"]
      .allSatisfy(FilterParser.isPlainSelector))
check("a network filter containing ## is not taken for a selector", first("/page?a=1##frag")?.action.type == .block)

// MARK: Allowlist

check("www is the same site", BlockingAllowlist.contains("www.news.example", in: ["news.example"]))
check("subdomains are covered", BlockingAllowlist.contains("live.news.example", in: ["news.example"]))
check("a name that ends the same is another site", !BlockingAllowlist.contains("fakenews.example", in: ["news.example"]))
check("no host, no match", !BlockingAllowlist.contains(nil, in: ["news.example"]))

// MARK: Building

let built = RuleSetBuilder.build(texts: ["||ads.example^\n##.ad\n@@||ads.example/ok.js", "||tracker.example^$third-party\nnews.example#@#.ad\n@@||cdn.tracker.example^"])
check("lists are built as one: an exception in one excuses a filter in another", built.actions.contains { $0.action.selector == ".ad" && $0.trigger.unlessDomain == ["*news.example"] })
check("actions and exceptions are kept apart", built.exceptions.count == 2 && built.actions.allSatisfy { !$0.isException })
let lists = built.lists(actionsPerList: 2)
check("every list to compile ends with every exception", lists.count == 2 && lists.allSatisfy { $0.suffix(2).allSatisfy(\.isException) && (try? RulePartitioner.validateCanonical($0)) != nil }, lists.map(\.count))
check("nothing to block, nothing to compile", RuleSetBuilder.build(texts: ["@@||only.exceptions^"]).lists().isEmpty)
check("the same files have the same fingerprint", RuleSetBuilder.fingerprint(of: ["a", "b"]) == RuleSetBuilder.fingerprint(of: ["a", "b"]))
check("a changed file has another", RuleSetBuilder.fingerprint(of: ["a", "b"]) != RuleSetBuilder.fingerprint(of: ["a", "c"]))
check("…and so do the same bytes split differently", RuleSetBuilder.fingerprint(of: ["ab", "c"]) != RuleSetBuilder.fingerprint(of: ["a", "bc"]))
check("a filter list is recognised", RuleSetBuilder.looksLikeFilterList("[Adblock Plus 2.0]\n! Title: EasyList\n||a.example^\n||b.example^\n##.ad\n"))
check("a sign-in page is not a filter list", !RuleSetBuilder.looksLikeFilterList("<!DOCTYPE html>\n<html>\n<body>\nPlease sign in\nto the Wi-Fi\n</body>\n</html>"))
check("a stub is not a filter list", !RuleSetBuilder.looksLikeFilterList("||a.example^"))

// MARK: JSON

let data = try JSONEncoder().encode(rules("||ads.example^$third-party,script\nnews.example##.promo"))
let json = String(decoding: data, as: UTF8.self)
check("rules encode with WebKit's key names", json.contains("\"url-filter\"") && json.contains("\"load-type\"") && json.contains("\"resource-type\"")
      && json.contains("\"if-domain\"") && json.contains("css-display-none") && !json.contains("urlFilter"), json)

print(failures == 0 ? "✔ all \(passed) BlockKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
