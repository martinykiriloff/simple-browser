import Foundation
import BrowserKit

// Unit checks for BrowserKit, as a plain executable: `swift run BrowserKitChecks`.
// Same arrangement as PasswordKitChecks, for the same reason: no XCTest on a
// Command Line Tools-only Mac.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
}

// MARK: Profile roster

do {
    let empty = ProfileRoster(profiles: [])
    check("a roster is never empty", empty.profiles.count == 1 && empty.profiles[0].name == "Default")
    check("the only profile is the last used", empty.lastUsedID == empty.profiles[0].id)
}

do {
    let a = Profile(name: "Work")
    let roster = ProfileRoster(profiles: [a], lastUsedID: ProfileID())
    check("an unknown last-used id falls back to the first profile", roster.lastUsedID == a.id)
}

do {
    var roster = ProfileRoster(profiles: [Profile(name: "Default")])
    let second = roster.add()
    check("a blank name becomes Profile N", second.name == "Profile 2", second.name)
    check("each profile has its own data store", second.dataStoreIdentifier != roster.profiles[0].dataStoreIdentifier)
    check("a new profile takes an unused colour", second.accent != roster.profiles[0].accent, second.accent)

    let work = roster.add(name: "  Work ")
    check("names are trimmed", work.name == "Work", work.name)
    let work2 = roster.add(name: "work")
    check("a taken name, in any case, gets a number", work2.name == "work 2", work2.name)

    let store = work.dataStoreIdentifier
    check("rename succeeds", roster.rename(work.id, to: "Client"))
    check("rename changes the name", roster.profile(work.id)?.name == "Client")
    check("rename keeps the data store, so sessions survive", roster.profile(work.id)?.dataStoreIdentifier == store)
    check("rename to an existing name is numbered", roster.rename(work2.id, to: "Client") && roster.profile(work2.id)?.name == "Client 2", roster.profile(work2.id)?.name)
    check("rename to its own name leaves it alone", roster.rename(work.id, to: "Client") && roster.profile(work.id)?.name == "Client")
    check("rename of an unknown profile fails", !roster.rename(ProfileID(), to: "x"))

    roster.markUsed(work.id)
    check("markUsed moves last used", roster.lastUsedID == work.id)
    roster.markUsed(ProfileID())
    check("markUsed ignores an unknown id", roster.lastUsedID == work.id)

    check("removing returns the profile", roster.remove(work.id)?.id == work.id)
    check("removing the last-used profile moves last used", roster.lastUsedID == roster.profiles[0].id)
    check("removing an unknown profile does nothing", roster.remove(ProfileID()) == nil && roster.profiles.count == 3)
}

do {
    var roster = ProfileRoster(profiles: [Profile(name: "Only")])
    check("the last profile cannot be removed", roster.remove(roster.profiles[0].id) == nil && roster.profiles.count == 1)
}

do {
    var roster = ProfileRoster(profiles: [Profile(name: "Default")])
    roster.add(name: "Work")
    let data = try JSONEncoder().encode(roster)
    let decoded = try JSONDecoder().decode(ProfileRoster.self, from: data)
    check("the roster round-trips through JSON", decoded == roster)
} catch {
    check("the roster round-trips through JSON", false, error)
}

// MARK: Eviction

do {
    let now = Date()
    func tab(_ minutesAgo: Double, pinned: Bool = false) -> TabState {
        TabState(isPinned: pinned, lastActive: now.addingTimeInterval(-minutesAgo * 60))
    }
    let tabs = (0..<6).map { tab(Double($0)) }          // tabs[0] used most recently
    let policy = EvictionPolicy(liveBudget: 4)
    let shown: Set<TabID> = [tabs[0].id, tabs[5].id]
    let chosen = policy.tabsToHibernate(live: tabs, protected: shown, pressure: .normal, now: now, inactivityLimit: nil)
    check("over budget: the least recently used go first", chosen == [tabs[4].id, tabs[3].id], chosen.count)
    check("tabs on screen are never chosen, however old", !chosen.contains(tabs[5].id))
    let critical = policy.tabsToHibernate(live: tabs, protected: shown, pressure: .critical, now: now, inactivityLimit: nil)
    check("critical pressure keeps only what is on screen", Set(critical) == Set(tabs.map(\.id)).subtracting(shown), critical.count)
    let idle = [tab(0), tab(45), tab(10)]
    let byTime = EvictionPolicy(liveBudget: 10).tabsToHibernate(live: idle, protected: [idle[0].id], pressure: .normal, now: now)
    check("under budget, a tab idle past the limit still sleeps", byTime == [idle[1].id], byTime.count)
    let pinned = [tab(0), tab(90, pinned: true)]
    check("pinned tabs never sleep", EvictionPolicy(liveBudget: 1).tabsToHibernate(live: pinned, protected: [pinned[0].id], pressure: .critical, now: now).isEmpty)
}

// MARK: Session

do {
    let work = ProfileID(), gone = ProfileID()
    let page = SessionSnapshot.Tab(url: URL(string: "https://example.com/a"), title: "A", state: Data([1, 2, 3]))
    let blank = SessionSnapshot.Tab(url: nil, title: "New Tab", state: nil)
    let session = SessionSnapshot(windows: [
        .init(profileID: work, frame: .init(x: 10, y: 20, width: 800, height: 600), tabs: [blank, page, page], selected: 9),
        .init(profileID: gone, frame: .init(x: 0, y: 0, width: 1, height: 1), tabs: [page], selected: 0),
        .init(profileID: work, frame: .init(x: 0, y: 0, width: 1, height: 1), tabs: [blank], selected: 0),
    ])
    let data = try JSONEncoder().encode(session)
    check("a session round-trips through JSON", try JSONDecoder().decode(SessionSnapshot.self, from: data) == session)
    let windows = session.restorable(profiles: [work])
    check("a deleted profile's windows are not restored", windows.count == 1, windows.count)
    check("empty tabs are dropped, the rest keep their order", windows.first?.tabs == [page, page])
    check("a selection past the end is clamped", windows.first?.selected == 1)
    check("a session of blank tabs is empty", SessionSnapshot(windows: [.init(profileID: work, frame: .init(x: 0, y: 0, width: 1, height: 1), tabs: [blank], selected: 0)]).isEmpty)
    check("restore when asked", StartupChoice.shouldRestore(choice: .lastSession, uncleanExit: false, restartForUpdate: false, hasSession: true))
    check("a new window when asked", !StartupChoice.shouldRestore(choice: .newWindow, uncleanExit: false, restartForUpdate: false, hasSession: true))
    check("always restore after a crash", StartupChoice.shouldRestore(choice: .newWindow, uncleanExit: true, restartForUpdate: false, hasSession: true))
    check("always restore after an update", StartupChoice.shouldRestore(choice: .newWindow, uncleanExit: false, restartForUpdate: true, hasSession: true))
    check("nothing to restore, nothing restored", !StartupChoice.shouldRestore(choice: .lastSession, uncleanExit: true, restartForUpdate: true, hasSession: false))
} catch {
    check("session checks", false, error)
}

// MARK: Address bar

do {
    func u(_ s: String) -> URL { URL(string: s)! }
    let google = SearchEngine.all.first { $0.id == "google" }!
    check("an engine searches with the words encoded", google.searchURL(for: "a&b c")?.absoluteString == "https://www.google.com/search?q=a%26b%20c")
    check("suggestions URL", SearchEngine.default.suggestURL(for: "swift")?.absoluteString == "https://duckduckgo.com/ac/?q=swift&type=list")
    check("OpenSearch answers parse", SearchEngine.parseSuggestions(Data(#"["sw",["swift","swiftui"]]"#.utf8)) == ["swift", "swiftui"])
    check("a broken answer is no suggestions", SearchEngine.parseSuggestions(Data("oops".utf8)).isEmpty)
    check("a custom engine needs %s", SearchEngine.custom(template: "https://search.example/?q=x") == nil)
    check("a custom engine is named after its host", SearchEngine.custom(template: "https://www.search.example/?q=%s")?.name == "search.example")
    check("a custom engine must be a web address", SearchEngine.custom(template: "javascript:alert(%s)") == nil)

    check("typeable drops scheme and www", SuggestionRanker.typeable(u("https://www.github.com/")) == "github.com")
    check("typeable keeps the path", SuggestionRanker.typeable(u("https://github.com/apple/swift")) == "github.com/apple/swift")

    let candidates = [SuggestionRanker.Candidate(title: "GitHub", url: u("https://github.com/apple/swift"), score: 50),
                      SuggestionRanker.Candidate(title: "GitLab", url: u("https://gitlab.com/"), score: 10)]
    let completion = SuggestionRanker.completion(for: "git", candidates: candidates)
    check("git completes to the best host, not the whole path", completion?.text == "hub.com", completion?.text as Any)
    check("…and goes to the site", completion?.url.absoluteString == "https://github.com/", completion?.url as Any)
    check("typing a path completes the path", SuggestionRanker.completion(for: "github.com/ap", candidates: candidates)?.text == "ple/swift")
    check("case does not matter", SuggestionRanker.completion(for: "GIT", candidates: candidates)?.text == "hub.com")
    let local = [SuggestionRanker.Candidate(title: "Dev", url: u("http://127.0.0.1:8767/tabs?x=1"), score: 1)]
    check("completion keeps the port and scheme", SuggestionRanker.completion(for: "127.0", candidates: local)?.url.absoluteString == "http://127.0.0.1:8767/",
          SuggestionRanker.completion(for: "127.0", candidates: local)?.url as Any)
    check("words are not completed", SuggestionRanker.completion(for: "git hub", candidates: candidates) == nil)
    check("nothing completes when nothing starts with it", SuggestionRanker.completion(for: "hub", candidates: candidates) == nil)
    check("a complete address is not completed further", SuggestionRanker.completion(for: "gitlab.com", candidates: candidates) == nil)

    let ranked = SuggestionRanker.rank(
        query: "git", tabs: [(id: "t1", title: "GitHub", url: u("https://github.com/apple/swift"))],
        bookmarks: [.init(title: "GitHub", url: u("https://github.com/apple/swift")), .init(title: "Git docs", url: u("https://git-scm.com/doc"))],
        history: [.init(title: "GitLab", url: u("https://gitlab.com/"), score: 5), .init(title: "News", url: u("https://news.example/"), score: 99)],
        searches: ["github copilot", "git"], engine: .default)
    check("an open tab comes first, as Switch to Tab", ranked.first?.kind == .switchToTab(id: "t1"), ranked.map(\.title))
    check("the same page is not listed twice", ranked.filter { $0.url.host() == "github.com" }.count == 1)
    check("bookmarks before history", (ranked.firstIndex { $0.title == "Git docs" } ?? 99) < (ranked.firstIndex { $0.title == "GitLab" } ?? -1))
    check("pages that do not match are left out", !ranked.contains { $0.title == "News" })
    check("the typed search is offered, once", ranked.filter { $0.kind == .search && $0.detail.lowercased() == "git" }.count == 1, ranked.map(\.detail))
    check("the engine's suggestions follow", ranked.last?.detail == "github copilot", ranked.map(\.detail))
    check("an empty query suggests nothing", SuggestionRanker.rank(query: " ", tabs: [], bookmarks: [], history: [], searches: [], engine: .default).isEmpty)

    check("https with only secure content is secure", PageSecurity.of(u("https://example.com/"), hasOnlySecureContent: true) == .secure)
    check("https that loaded http parts is mixed", PageSecurity.of(u("https://example.com/"), hasOnlySecureContent: false) == .mixed)
    check("http is not secure", PageSecurity.of(u("http://example.com/"), hasOnlySecureContent: false) == .notSecure)
    check("http is not secure whatever WebKit says about content", PageSecurity.of(u("http://example.com/"), hasOnlySecureContent: true) == .notSecure)
    for local in ["http://localhost:3000/", "http://127.0.0.1:8767/x", "http://app.localhost/", "http://[::1]:8080/"] {
        check("\(local) is this Mac", PageSecurity.of(u(local), hasOnlySecureContent: false) == .local)
    }
    for trick in ["http://127.0.0.1.evil.example/", "http://localhost.evil.example/", "http://127.evil.example/"] {
        check("\(trick) is not this Mac", PageSecurity.of(u(trick), hasOnlySecureContent: false) == .notSecure)
    }
    check("the start page says nothing", PageSecurity.of(u("simplebrowser://start"), hasOnlySecureContent: false) == .none)
    check("no page says nothing", PageSecurity.of(nil, hasOnlySecureContent: false) == .none)
    check("only trouble gets words", PageSecurity.secure.label == nil && PageSecurity.local.label == nil
          && PageSecurity.notSecure.label == "Not Secure" && PageSecurity.mixed.label == "Not Secure")
}

print(failures == 0 ? "✔ \(passed) checks passed" : "\(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
