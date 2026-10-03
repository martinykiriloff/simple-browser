import Foundation
import BrowserKit

// Unit checks for BrowserKit, as a plain executable: `swift run BrowserKitChecks`.
// Same arrangement as PasswordKitChecks, for the same reason: no XCTest on a
// Command Line Tools-only Mac.

// `--shortcut-table` prints the README's shortcut table instead;
// `--performance-table` the budget table; `--performance-verdict <json>`
// checks a run's numbers against the budget and fails on a regression.
if CommandLine.arguments.contains("--shortcut-table") {
    print(Shortcuts.readmeTable())
    exit(0)
}
if CommandLine.arguments.contains("--performance-table") {
    print(PerformanceBudget.readmeTable())
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--performance-verdict"), CommandLine.arguments.indices.contains(index + 1) {
    guard let data = FileManager.default.contents(atPath: CommandLine.arguments[index + 1]),
          let measure = try? JSONDecoder().decode(PerformanceMeasure.self, from: data) else {
        print("✘ no performance report at \(CommandLine.arguments[index + 1])")
        exit(1)
    }
    print(PerformanceBudget.report(measure))
    print(PerformanceBudget.passes(measure) ? "✔ within the performance budget" : "✘ over the performance budget")
    exit(PerformanceBudget.passes(measure) ? 0 : 1)
}

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
    check("the start page says nothing", PageSecurity.of(u("keel://start"), hasOnlySecureContent: false) == .none)
    check("no page says nothing", PageSecurity.of(nil, hasOnlySecureContent: false) == .none)
    let original = u("https://news.example/2026/story?id=7&x=a%20b#part")
    let reader = ReaderPage.url(token: "abc123", original: original)
    check("a Reader address carries its article's address, intact", ReaderPage.original(of: reader) == original, reader as Any)
    check("…and its token", ReaderPage.token(of: reader) == "abc123" && ReaderPage.isReader(reader))
    check("the start page is not a Reader page", !ReaderPage.isReader(u("keel://start")) && ReaderPage.original(of: u("keel://start")) == nil)
    check("a Reader address naming a script or a file has no article", ReaderPage.original(of: u("keel://reader/x?url=javascript:alert(1)")) == nil
          && ReaderPage.original(of: u("keel://reader/x?url=file:///etc/passwd")) == nil)
    var article = ReaderArticle(url: original, title: "Tom & Jerry <script>alert(1)</script>", byline: "A \"Writer\"", site: "News", published: "2026-03-12T09:30:00Z",
                                language: "en", words: 1150, html: "<p>Body</p>")
    let page = ReaderPage.html(article, appearance: ReaderAppearance())
    check("the title is text, never markup", page.contains("Tom &amp; Jerry &lt;script&gt;alert(1)&lt;/script&gt;") && !page.contains("<script>alert"))
    check("the byline too", page.contains("A &quot;Writer&quot;"))
    check("the page forbids script, frames and forms", page.contains("Content-Security-Policy") && page.contains("default-src 'none'") && page.contains("form-action 'none'"))
    check("…and sends no referrer to the images it loads", page.contains("name=\"referrer\" content=\"no-referrer\""))
    check("reading time, at 230 words a minute", article.minutes == 5 && page.contains("5 min read"))
    check("a short article is one minute, not none", ReaderArticle(url: original, title: "t", words: 12, html: "").minutes == 1)
    check("the date is written for a person", page.contains("2026") && !page.contains("T09:30"))
    article.published = "yesterday-ish"
    check("a date that is not one is left out", !ReaderPage.html(article, appearance: ReaderAppearance()).contains("yesterday"))
    article.language = "en\" onload=\"x"
    check("a language that is not one is left out", !ReaderPage.html(article, appearance: ReaderAppearance()).contains("onload"))
    var look = ReaderAppearance()
    check("Reader starts in New York, 19 points, medium, matching the system", look.font == .newYork && look.size == 19 && look.width == .medium && look.theme == .auto)
    look.grow(); look.grow()
    check("larger, by steps", look.size == 22)
    for _ in 0..<20 { look.shrink() }
    check("smaller stops at 14", look.size == 14 && !look.canShrink && look.canGrow)
    look.theme = .sepia
    check("the look is set on the page's root", ReaderPage.html(article, appearance: look).contains("data-theme=\"sepia\"") && look.attributes["style"]?.contains("--size: 14px") == true)
    check("a Reader page that lost its article sends the tab to the article", ReaderPage.redirect(to: original).contains("url=https://news.example/2026/story?id=7&amp;x=a%20b#part"))
    check("a site is its origin", SitePermissions.site(of: u("https://Meet.Example.com:443/room/7?x=1")) == "https://meet.example.com")
    check("…with a port that is not the default", SitePermissions.site(of: u("http://localhost:8767/")) == "http://localhost:8767")
    check("…and http is another site than https", SitePermissions.site(of: u("http://meet.example.com/")) != SitePermissions.site(of: u("https://meet.example.com/")))
    check("WebKit's port 0 is the default port", SitePermissions.site(scheme: "https", host: "meet.example.com", port: 0) == "https://meet.example.com")
    check("the browser's own pages are no site", SitePermissions.site(of: u("keel://start")) == nil && SitePermissions.site(of: u("file:///x")) == nil)
    var permissions = SitePermissions()
    let meet = "https://meet.example.com"
    check("nothing chosen: a camera request is asked about", PermissionDecision.decide([.camera], site: meet, stored: permissions) == .ask)
    check("nothing chosen: a pop-up is blocked, not asked about", PermissionDecision.decide([.popups], site: meet, stored: permissions) == .deny)
    permissions.set(.allow, for: .camera, site: meet)
    check("allowed: not asked again", PermissionDecision.decide([.camera], site: meet, stored: permissions) == .allow)
    check("…for that permission only", PermissionDecision.decide([.microphone], site: meet, stored: permissions) == .ask)
    check("…and that site only", PermissionDecision.decide([.camera], site: "https://other.example", stored: permissions) == .ask)
    check("camera allowed, microphone not chosen: the pair is asked about", PermissionDecision.decide([.camera, .microphone], site: meet, stored: permissions) == .ask)
    permissions.set(.deny, for: .microphone, site: meet)
    check("one refusal refuses the pair", PermissionDecision.decide([.camera, .microphone], site: meet, stored: permissions) == .deny)
    check("allowed once counts, for what it was given for", PermissionDecision.decide([.location], site: meet, stored: permissions, allowedOnce: [.location]) == .allow
          && PermissionDecision.decide([.notifications], site: meet, stored: permissions, allowedOnce: [.location]) == .ask)
    check("a stored refusal beats allowed once", PermissionDecision.decide([.microphone], site: meet, stored: permissions, allowedOnce: [.microphone]) == .deny)
    permissions.set(.allow, for: .popups, site: meet)
    check("pop-ups allowed for a site are let through", PermissionDecision.decide([.popups], site: meet, stored: permissions) == .allow)
    permissions.set(.allow, for: .camera, site: "https://a.example")
    check("sites are listed by name, choices in a fixed order", permissions.sites.map(\.site) == ["https://a.example", meet]
          && permissions.sites[1].choices.map(\.permission) == [.camera, .microphone, .popups])
    permissions.set(nil, for: .camera, site: "https://a.example")
    check("forgetting the last choice forgets the site", permissions.sites.map(\.site) == [meet])
    let encoded = try JSONEncoder().encode(permissions)
    check("choices survive being saved", try JSONDecoder().decode(SitePermissions.self, from: encoded) == permissions)
    check("the question names the site and the thing", SitePermission.question(for: [.camera, .microphone], site: "meet.example.com") == "“meet.example.com” would like to use your camera and microphone."
          && SitePermission.question(for: [.location], site: "maps.example") == "“maps.example” would like to know where you are.")
    let site443 = u("https://bank.example/login")
    var problem = CertificateProblem(url: site443, kind: .init(errorCode: -1202), fingerprint: "ab12cd34", subject: "bank.example", issuer: "Nobody <b>", expires: Date(timeIntervalSince1970: 0))
    check("the error codes that are about certificates", [-1201, -1202, -1203, -1204].allSatisfy(CertificateProblem.Kind.isCertificateError)
          && !CertificateProblem.Kind.isCertificateError(-1200) && !CertificateProblem.Kind.isCertificateError(-1009))
    check("…by kind", CertificateProblem.Kind(errorCode: -1201) == .expired && CertificateProblem.Kind(errorCode: -1203) == .unknownIssuer)
    var exceptions = CertificateExceptions()
    check("no exception to begin with", !exceptions.allows(host: "bank.example", port: 443, fingerprint: "ab12cd34") && !exceptions.covers(site443))
    exceptions.accept(problem)
    check("an exception is for the certificate accepted", exceptions.allows(host: "BANK.example", port: 443, fingerprint: "ab12cd34"))
    check("…not for another the site presents later", !exceptions.allows(host: "bank.example", port: 443, fingerprint: "ffff0000"))
    check("…nor for another port or host", !exceptions.allows(host: "bank.example", port: 8443, fingerprint: "ab12cd34")
          && !exceptions.allows(host: "evil.example", port: 443, fingerprint: "ab12cd34"))
    check("a page reached on an exception is known to be", exceptions.covers(site443) && !exceptions.covers(u("https://other.example/")) && !exceptions.covers(u("http://bank.example/")))
    problem.fingerprint = ""
    var none = CertificateExceptions()
    none.accept(problem)
    check("a certificate that could not be read is never excepted", none.isEmpty && !none.allows(host: "bank.example", port: 443, fingerprint: ""))
    problem.fingerprint = "ab12cd34"
    let warning = WarningPage.url(token: "t1", original: site443)
    check("a warning's address carries the page it is about", WarningPage.original(of: warning) == site443 && WarningPage.token(of: warning) == "t1" && WarningPage.isWarning(warning))
    check("…which is never an http page or a script", WarningPage.original(of: u("keel://warning/t?url=http://x.example/")) == nil
          && WarningPage.original(of: u("keel://warning/t?url=javascript:1")) == nil)
    check("a warning is not a Reader page or the start page", !ReaderPage.isReader(warning) && !WarningPage.isWarning(u("keel://start")))
    check("the warning's two buttons", WarningPage.action(of: u("keel://warning-action/back")) == .back
          && WarningPage.action(of: u("keel://warning-action/proceed?token=t1")) == .proceed(token: "t1")
          && WarningPage.action(of: u("keel://warning-action/proceed")) == nil && WarningPage.action(of: u("https://warning-action/back")) == nil)
    let warningHTML = WarningPage.html(problem, token: "t1")
    check("the warning names the site and shows the certificate, as text", warningHTML.contains("<b>bank.example</b>") && warningHTML.contains("Nobody &lt;b&gt;")
          && warningHTML.contains("AB12 CD34") && warningHTML.contains("Expired"))
    check("…and runs no script", warningHTML.contains("default-src 'none'") && !warningHTML.contains("<script"))
    check("a page on an accepted certificate is Not Secure, whatever else", PageSecurity.of(site443, hasOnlySecureContent: true, certificateAccepted: true) == .untrusted
          && PageSecurity.untrusted.label == "Not Secure")
    var item = DownloadItem(url: u("https://files.example/big.zip"), page: u("https://www.example.com/downloads"), path: "/Users/x/Downloads/big.zip", total: 10_000_000)
    item.received = 3_200_000
    check("a download knows how far it is", item.fraction == 0.32 && item.fileName == "big.zip" && item.isActive)
    check("…and where it came from: the page, not the file's server", item.source == "example.com")
    // Sizes are written for the Mac's region (3.2 MB here, 3,2 MB there),
    // so what is expected is put together from the same parts.
    let some = DownloadFormat.size(3_200_000), all = DownloadFormat.size(10_000_000)
    check("sizes are in Finder's units", some.hasSuffix(" MB") && some.hasPrefix("3") && all == "10 MB", [some, all])
    check("under way: how much, how fast, how long", DownloadFormat.status(item, speed: 1_200_000, secondsLeft: 5.6) == "\(some) of \(all) · \(DownloadFormat.size(1_200_000))/s · 6 seconds left",
          DownloadFormat.status(item, speed: 1_200_000, secondsLeft: 5.6))
    check("…without a guess while there is nothing to go by", DownloadFormat.status(item) == "\(some) of \(all)", DownloadFormat.status(item))
    item.total = nil
    check("…and without a total the server never gave", DownloadFormat.status(item, speed: 500_000) == "\(some) · 500 KB/s", DownloadFormat.status(item, speed: 500_000))
    item.total = 10_000_000
    item.state = .paused
    check("paused", DownloadFormat.status(item) == "Paused · \(some) of \(all)", DownloadFormat.status(item))
    item.state = .finished
    check("finished: its size and where from", DownloadFormat.status(item) == "10 MB · example.com")
    item.state = .failed
    item.failure = "The network connection was lost."
    check("failed: why", DownloadFormat.status(item) == "Failed: The network connection was lost.")
    check("time left is said as a person would", DownloadFormat.duration(0.2) == "1 second" && DownloadFormat.duration(7) == "7 seconds" && DownloadFormat.duration(42) == "45 seconds"
          && DownloadFormat.duration(95) == "2 minutes" && DownloadFormat.duration(3600) == "1 hour" && DownloadFormat.duration(4200) == "1 hour 10 minutes",
          [0.2, 7, 42, 95, 3600, 4200].map(DownloadFormat.duration))
    check("small sizes are bytes", DownloadFormat.size(512) == "512 bytes")

    var meter = DownloadMeter()
    meter.record(bytes: 0, at: 0)
    check("no speed from one reading", meter.speed == nil && meter.secondsLeft(total: 1000) == nil)
    meter.record(bytes: 500_000, at: 1)
    meter.record(bytes: 1_000_000, at: 2)
    check("speed from recent readings", meter.speed == 500_000)
    check("time left from speed", meter.secondsLeft(total: 3_000_000) == 4)
    meter.record(bytes: 1_100_000, at: 8)
    check("old readings are forgotten: a download that slowed is slow", (meter.speed ?? 0) < 20_000, meter.speed as Any)
    meter.record(bytes: 200, at: 9)
    check("starting again starts the measure again", meter.speed == nil)

    check("files that run are dangerous", ["Installer.dmg", "setup.PKG", "run.command", "tool.sh", "Thing.app", "payload.jar", "x.scpt", "invoice.pdf.exe"].allSatisfy(DownloadRisk.isDangerous))
    check("…documents, pictures and archives are not", ["report.pdf", "photo.jpeg", "notes.txt", "archive.zip", "song.mp3", "sheet.xlsx", "README"].allSatisfy { !DownloadRisk.isDangerous(fileName: $0) })
    check("…and a trailing dot or space hides nothing", DownloadRisk.isDangerous(fileName: "evil.command. "))

    var list = DownloadList()
    let first = DownloadItem(url: u("https://a.example/1.zip"), path: "/d/1.zip", state: .finished)
    let second = DownloadItem(url: u("https://a.example/2.zip"), path: "/d/2.zip", received: 50, total: 100)
    let third = DownloadItem(url: u("https://a.example/3.zip"), path: "/d/3.zip", received: 10, total: 300)
    list.add(first); list.add(second); list.add(third)
    check("the newest download is first", list.items.map(\.fileName) == ["3.zip", "2.zip", "1.zip"])
    check("overall progress is of what is under way", list.fraction == 0.15, list.fraction as Any)
    let saved = try JSONEncoder().encode(list)
    var relaunched = try JSONDecoder().decode(DownloadList.self, from: saved)
    relaunched.markInterrupted { $0 == second.id }
    check("after a relaunch, what was under way is paused if it can go on", relaunched[second.id]?.state == .paused && relaunched[second.id]?.canResume == true)
    check("…and failed, saying why, if it cannot", relaunched[third.id]?.state == .failed && relaunched[third.id]?.failure?.contains("quit") == true)
    check("…what had finished is as it was", relaunched[first.id] == first)
    relaunched.clearFinished()
    check("Clear removes what is over, and keeps what is paused", relaunched.items.map(\.fileName) == ["2.zip"])
    var full = DownloadList()
    let running = DownloadItem(url: u("https://a.example/run.zip"), path: "/d/run.zip")
    full.add(running)
    for n in 0..<(DownloadList.limit + 20) { full.add(DownloadItem(url: u("https://a.example/\(n)"), path: "/d/\(n)", state: .finished)) }
    check("the list is kept to a length, never at the cost of a download under way", full.items.count == DownloadList.limit && full[running.id] != nil)
    check("zoom steps up", PageZoom.larger(than: 1) == 1.1 && PageZoom.larger(than: 1.1) == 1.25 && PageZoom.larger(than: 5) == 5)
    check("zoom steps down", PageZoom.smaller(than: 1) == 0.9 && PageZoom.smaller(than: 0.25) == 0.25)
    check("zoom between steps moves to the next step", PageZoom.larger(than: 1.2) == 1.25 && PageZoom.smaller(than: 1.2) == 1.1)
    check("up then down is back where it was", PageZoom.steps.dropLast().allSatisfy { PageZoom.smaller(than: PageZoom.larger(than: $0)) == $0 })
    check("zoom label", PageZoom.label(1.25) == "125%" && PageZoom.label(0.67) == "67%" && PageZoom.label(1) == "100%")
    check("zoom is kept per site: www and the scheme do not matter", PageZoom.key(for: u("https://www.Example.com/a?b")) == "example.com"
          && PageZoom.key(for: u("http://example.com:8080/")) == "example.com")
    check("…a subdomain is another site", PageZoom.key(for: u("https://docs.example.com/")) == "docs.example.com")
    check("…and the browser's own pages have none", PageZoom.key(for: u("keel://start")) == nil && PageZoom.key(for: nil) == nil)
    check("100% is forgotten rather than remembered", PageZoom.setting(1, for: "a.example", in: ["a.example": 1.5, "b.example": 2]) == ["b.example": 2])
    check("another level is remembered", PageZoom.setting(1.25, for: "a.example", in: [:]) == ["a.example": 1.25])
    check("only trouble gets words", PageSecurity.secure.label == nil && PageSecurity.local.label == nil
          && PageSecurity.notSecure.label == "Not Secure" && PageSecurity.mixed.label == "Not Secure")
}

// MARK: Tab groups and pins

do {
    let a = TabID(), b = TabID(), c = TabID(), d = TabID(), e = TabID()
    let g = TabGroupID(), h = TabGroupID()
    typealias E = TabArrangement.Entry
    let order = TabArrangement.arranged([E(id: a), E(id: b, groupID: g), E(id: c), E(id: d, groupID: g), E(id: e, isPinned: true)])
    check("pinned tabs come first", order.first?.id == e, order.map(\.id))
    check("a group's tabs are side by side, where its first tab was", order.map(\.id) == [e, a, b, d, c], order.map(\.id))
    let settled = [E(id: e, isPinned: true), E(id: a), E(id: b, groupID: g), E(id: d, groupID: g), E(id: c)]
    check("tabs already in order stay put", TabArrangement.arranged(settled) == settled)
    check("a pinned tab is in no group", TabArrangement.arranged([E(id: a, groupID: g, isPinned: true), E(id: b, groupID: g)]).map(\.id) == [a, b])

    check("a tab joining a group goes after its last tab", TabArrangement.insertionIndex(for: c, joining: g, in: settled) == 4)
    check("…and a new group starts where the tab is", TabArrangement.insertionIndex(for: c, joining: h, in: settled) == 4)
    check("…never among the pinned tabs", TabArrangement.insertionIndex(for: a, joining: h, in: [E(id: e, isPinned: true), E(id: a)]) == 1)

    var groups = [g: TabGroup(id: g, name: "Work", color: .blue), h: TabGroup(id: h, name: "Empty")]
    let sidebar = TabArrangement.sidebar(settled, groups: groups)
    check("the sidebar: pinned tabs as icons, then rows", sidebar.pinned == [e]
          && sidebar.rows == [.tab(a, inGroup: false), .group(g), .tab(b, inGroup: true), .tab(d, inGroup: true), .tab(c, inGroup: false)], sidebar.rows)
    groups[g]?.isCollapsed = true
    check("a collapsed group shows its name only", TabArrangement.sidebar(settled, groups: groups).rows == [.tab(a, inGroup: false), .group(g), .tab(c, inGroup: false)])
    check("…but not hiding the tab in front", TabArrangement.sidebar(settled, groups: groups, selected: d).rows.contains(.tab(d, inGroup: true)))
    check("a group with no tabs is forgotten", TabArrangement.emptyGroups([g, h], in: settled) == [h])
    check("a new group takes a colour not yet used", TabArrangement.nextColor(after: [.blue, .red]) == .yellow && TabArrangement.nextColor(after: []) == .blue)

    let old = #"{"url":"https://example.com/","title":"A"}"#
    let tab = try? JSONDecoder().decode(SessionSnapshot.Tab.self, from: Data(old.utf8))
    check("a session tab written before groups still reads", tab?.title == "A" && tab?.isPinned == false && tab?.groupID == nil)
    let window = SessionSnapshot.Window(profileID: ProfileID(), frame: .init(x: 0, y: 0, width: 1, height: 1),
                                        tabs: [.init(url: nil, title: "B", state: nil, groupID: g, isPinned: false)], selected: 0,
                                        groups: [TabGroup(id: g, name: "Work", color: .green, isCollapsed: true)])
    let round = (try? JSONEncoder().encode(window)).flatMap { try? JSONDecoder().decode(SessionSnapshot.Window.self, from: $0) }
    check("groups and pins survive the session file", round == window)
}

// MARK: Command palette

do {
    check("fuzzy: the letters in order", FuzzyMatch.score("gh", in: "GitHub") != nil && FuzzyMatch.score("hg", in: "GitHub") == nil)
    check("fuzzy: case and accents do not matter", FuzzyMatch.score("cafe", in: "Café Olé") != nil)
    check("fuzzy: word starts beat letters inside words",
          FuzzyMatch.score("np", in: "New Private Window")! > FuzzyMatch.score("np", in: "Snapshot Panel")!)
    check("fuzzy: a run beats scattered letters", FuzzyMatch.score("tab", in: "Reopen Closed Tab")! > FuzzyMatch.score("tab", in: "Tomato sandwich crab")!)
    check("fuzzy: a prefix beats the same letters later", FuzzyMatch.score("clear", in: "Clear History…")! > FuzzyMatch.score("clear", in: "Nuclear Reactors")!)
    check("fuzzy: nothing typed matches everything", FuzzyMatch.score("", in: "x") == 0)

    typealias I = CommandPalette.Item
    let now = Date()
    let items = [
        I(id: "t1", kind: .tab, title: "Pull requests · keel", detail: "https://github.com/pulls", lastUsed: now),
        I(id: "t2", kind: .tab, title: "Inbox (3) - Mail", detail: "https://mail.example.com/", lastUsed: now.addingTimeInterval(-60)),
        I(id: "c1", kind: .command, title: "Translate Page", detail: "View"),
        I(id: "c2", kind: .command, title: "Clear History…", detail: "History"),
        I(id: "b1", kind: .bookmark, title: "Swift Forums", detail: "https://forums.swift.org/"),
        I(id: "h1", kind: .history, title: "Translate a page in Safari", detail: "https://support.apple.com/translate"),
    ]
    check("nothing typed: open tabs, the most recent first", CommandPalette.rank("", items).map(\.id) == ["t1", "t2"])
    check("a command is found by its words", CommandPalette.rank("transl", items).first?.id == "c1", CommandPalette.rank("transl", items).map(\.id))
    check("…and history that matches as well comes after it", CommandPalette.rank("transl", items).map(\.id).contains("h1"))
    check("a tab is found by its site", CommandPalette.rank("github", items).first?.id == "t1")
    check("bookmarks are searched", CommandPalette.rank("forums", items).first?.id == "b1")
    check("what does not match is left out", !CommandPalette.rank("clear", items).map(\.id).contains("t2"))

    // #13's promise: with a hundred tabs open, any of them is under three
    // keys away after ⌘K, against every menu command as well. Titles as
    // people have them: sites with many tabs of their own, alike on purpose.
    let sites: [(String, [String])] = [
        ("github.com", ["Pull requests", "Issues · keel", "Actions · keel", "swift-nio: Event-driven network framework", "apple/swift: The Swift Programming Language",
                        "Notifications", "Release v1.4 · keel", "Settings · Branches", "Compare changes", "Insights · Contributors"]),
        ("mail.google.com", ["Inbox (12) - Gmail", "Starred - Gmail", "Sent Mail - Gmail", "Drafts (2) - Gmail", "Invoice for September - Gmail"]),
        ("docs.google.com", ["Q4 planning - Google Docs", "Roadmap 2027 - Google Sheets", "Team offsite notes - Google Docs", "Budget - Google Sheets", "Hiring plan - Google Docs"]),
        ("developer.apple.com", ["WKWebView | Apple Developer Documentation", "NSWindowTab | Apple Developer Documentation", "WKWebExtension | Apple Developer Documentation",
                                 "Human Interface Guidelines: Sidebars", "WWDC25 videos", "Notarizing macOS software", "App Sandbox", "NSSplitViewController"]),
        ("stackoverflow.com", ["swift - How to reorder NSWindow tabs", "macos - NSOutlineView drag and drop", "javascript - fetch with credentials", "css - flexbox gap not working in Safari",
                               "git - undo last commit", "python - list comprehension with two loops"]),
        ("en.wikipedia.org", ["Tasmanian tiger - Wikipedia", "Byzantine Empire - Wikipedia", "Fourier transform - Wikipedia", "Great Barrier Reef - Wikipedia", "Ada Lovelace - Wikipedia",
                              "Quantum entanglement - Wikipedia", "Mount Kilimanjaro - Wikipedia"]),
        ("youtube.com", ["Lo-fi beats to code to - YouTube", "How WebKit renders a page - YouTube", "Sourdough for beginners - YouTube", "F1 Monza highlights - YouTube", "Home - YouTube"]),
        ("news.ycombinator.com", ["Hacker News", "Show HN: A native macOS browser | Hacker News", "Ask HN: Who is hiring? | Hacker News"]),
        ("linear.app", ["SB-120 Sidebar with vertical tabs", "SB-121 Split view", "SB-130 Passkeys", "My issues", "Cycle 14"]),
        ("figma.com", ["Browser chrome – Figma", "Icons – Figma", "Onboarding flow – Figma"]),
        ("amazon.com", ["Amazon.com: USB-C hub", "Your Orders", "Amazon.com: mechanical keyboard", "Shopping Cart"]),
        ("maps.apple.com", ["Coffee near me - Maps", "Sofia Airport - Maps"]),
        ("nytimes.com", ["The Morning: Election results", "Wordle — The New York Times", "Cooking: Weeknight pasta"]),
        ("slack.com", ["#general - Acme - Slack", "#browser-team - Acme - Slack", "Threads - Acme - Slack"]),
        ("notion.so", ["Engineering wiki", "Meeting notes 29 Sep", "Reading list", "OKRs"]),
        ("reddit.com", ["r/macapps", "r/swift", "r/MechanicalKeyboards", "r/AskHistorians"]),
        ("calendar.google.com", ["Google Calendar - Week of 28 September"]),
        ("booking.com", ["Hotels in Lisbon", "Your booking: Porto"]),
        ("spotify.com", ["Discover Weekly - Spotify"]),
        ("weather.com", ["Sofia 10-day forecast"]),
        ("mdn.dev", ["Array.prototype.flatMap() - MDN", "Fetch API - MDN", "CSS Grid Layout - MDN", "IntersectionObserver - MDN"]),
        ("swift.org", ["Swift Evolution", "Swift 6 migration guide"]),
        ("vercel.com", ["Deployments – Vercel"]),
        ("figjam.com", ["Retro board"]),
        ("zoom.us", ["Zoom Meeting"]),
        ("translate.google.com", ["Google Translate"]),
        ("duckduckgo.com", ["best trackpad gestures at DuckDuckGo"]),
        ("apple.com", ["MacBook Pro - Apple", "Apple Support"]),
        ("localhost:3000", ["Dashboard – Local", "Login – Local", "Storybook"]),
        ("figma.com", ["Design system – Figma", "Marketing site – Figma"]),
    ]
    var tabs: [I] = []
    for (host, titles) in sites {
        for (index, title) in titles.enumerated() {
            tabs.append(I(id: "tab\(tabs.count)", kind: .tab, title: title, detail: "https://\(host)/\(index)",
                          lastUsed: now.addingTimeInterval(-Double(tabs.count) * 97)))
        }
    }
    let commands = ["New Window", "New Private Window", "New Tab", "Open Location…", "Close Tab", "Close Window", "Reopen Closed Tab", "Undo", "Redo", "Cut", "Copy", "Paste",
                    "Paste and Go", "Select All", "Find…", "Find Next", "Find Previous", "Use Selection for Find", "Reload Page", "Reload Page From Origin", "Stop",
                    "Actual Size", "Zoom In", "Zoom Out", "Show Reader", "Translate Page", "Show Original", "Enter Full Screen", "Show Sidebar", "Back", "Forward", "Home",
                    "Reopen Last Closed Window", "Reopen All Windows from Last Session", "Show All History", "Clear History…", "Add Bookmark…", "Add to Reading List",
                    "Show Bookmarks", "Hide Favorites Bar", "New Profile…", "Rename Profile…", "Delete Profile…", "Show Developer Tools", "JavaScript Console",
                    "Inspect Elements", "Network", "Sources", "Dock to Bottom", "Dock to Right", "Separate Window", "Show Recording Log", "WebKit Web Inspector",
                    "Debug in Safari…", "Minimize", "Zoom", "Downloads", "Bring All to Front", "Settings…", "Passwords…", "Check for Updates…", "Pin Tab",
                    "New Tab Group", "Remove Tab from Group", "Switch to Profile Work", "Switch to Profile Default"]
        .enumerated().map { I(id: "cmd\($0.offset)", kind: .command, title: $0.element, detail: "Menu") }
    let everything = tabs + commands
    check("a hundred tabs to test against", tabs.count == 100, tabs.count)
    var worst = 0
    var far: [String] = []
    for tab in tabs {
        let keys = CommandPalette.keystrokes(toReach: tab.id, in: everything) ?? 99
        worst = max(worst, keys)
        if keys >= 3 { far.append("\(tab.title) (\(keys))") }
    }
    check("with 100 tabs, every tab is under three keys away after ⌘K", worst < 3, far)
    let hints = CommandPalette.hints(everything)
    check("every tab has a hint, and no two the same", hints.count == 100 && Set(hints.values.map { "\($0.letter)\($0.number)" }).count == 100)
    check("…a letter from its title where it can", tabs.filter { tab in hints[tab.id].map { h in tab.title.lowercased().contains(h.letter) } ?? false }.count >= 95)
    check("commands have none", commands.allSatisfy { hints[$0.id] == nil })
    let first = tabs[0], hint = hints[first.id]!
    check("typing the hint's letter puts the tab at its number", CommandPalette.rank(String(hint.letter), everything).firstIndex { $0.id == first.id } == hint.number - 1)
    check("two letters search as usual", CommandPalette.rank("pu", everything).first?.id == first.id)
}

// MARK: Extensions

do {
    let all = ExtensionPermissionWording.describe(permissions: ["storage", "tabs", "activeTab"], matchPatterns: ["<all_urls>"])
    check("extensions: all sites is said first, in plain words", all.first == "Read and change your data on all websites", all)
    check("extensions: …then the rest", all.contains("See the addresses and titles of your open tabs") && all.contains("Store its own data"), all)
    check("extensions: activeTab is not said when it can read sites anyway", !all.contains { $0.contains("when you click") })
    check("extensions: a few sites are named", ExtensionPermissionWording.describeSites(["*://*.github.com/*", "https://gitlab.com/*"]) == "Read and change your data on github.com and gitlab.com")
    check("extensions: many sites are counted", ExtensionPermissionWording.describeSites(["*://a.com/*", "*://b.com/*", "*://c.com/*", "*://d.com/*", "*://e.com/*"])
          == "Read and change your data on a.com, b.com, c.com and 2 more sites")
    check("extensions: *://*/* is every site", ExtensionPermissionWording.host(of: "*://*/*") == "*")
    check("extensions: only activeTab is the page you click on", ExtensionPermissionWording.describe(permissions: ["activeTab"], matchPatterns: [])
          == ["Read and change the page you are on when you click it"])
    check("extensions: site access grants what it says", ExtensionSiteAccess.onClick.granted(from: ["<all_urls>"]).isEmpty
          && ExtensionSiteAccess.allRequested.granted(from: ["<all_urls>"]) == ["<all_urls>"]
          && ExtensionSiteAccess.sites(["example.com"]).granted(from: ["<all_urls>"]) == ["*://example.com/*", "*://*.example.com/*"])

    let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])
    var crx3 = Data("Cr24".utf8) + Data([3, 0, 0, 0, 5, 0, 0, 0]) + Data([9, 9, 9, 9, 9]) + zip
    check("extensions: a .crx gives the zip inside", CRXPackage.zip(from: crx3) == zip)
    check("extensions: a zip is a zip", CRXPackage.zip(from: zip) == zip)
    crx3[4] = 7
    check("extensions: an unknown .crx is refused", CRXPackage.zip(from: crx3) == nil && CRXPackage.zip(from: Data("hello".utf8)) == nil)
}

// MARK: Keyboard shortcuts

do {
    let defaults = Shortcuts.effective(overrides: [:])
    check("every command has a key by default", Shortcuts.commands.allSatisfy { defaults[$0.id] != nil })
    check("no two commands share a key, and none is the Mac's own", Shortcuts.conflicts(in: defaults).isEmpty, Shortcuts.conflicts(in: defaults))
    check("⇧⌘T reads as it is written on the Mac", KeyShortcut("t", [.command, .shift]).display == "⇧⌘T")
    check("…with every modifier in the Mac's order", KeyShortcut("l", [.command, .option, .control]).display == "⌃⌥⌘L")
    check("…and named keys by their sign", KeyShortcut("left", [.command, .option]).display == "⌥⌘←" && KeyShortcut("f12", []).display == "F12")

    check("a key needs ⌘", Shortcuts.refusal(giving: KeyShortcut("k", [.shift]), to: "reload:", overrides: [:]) == "A shortcut needs ⌘, or a function key.")
    check("…unless it is a function key", Shortcuts.refusal(giving: KeyShortcut("f9", []), to: "reload:", overrides: [:]) == nil)
    check("the Mac's own keys are refused, saying whose they are", Shortcuts.refusal(giving: KeyShortcut("space", [.command]), to: "reload:", overrides: [:]) == "⌘Space is the Mac's own, for Spotlight.")
    check("a key another command has is refused, naming it", Shortcuts.refusal(giving: KeyShortcut("t"), to: "reload:", overrides: [:]) == "⌘T is “New Tab”.")
    check("…including one given by the person", Shortcuts.refusal(giving: KeyShortcut("j"), to: "reload:", overrides: ["findInPage:": KeyShortcut("j")]) == "⌘J is “Find…”.")
    check("a free key is allowed", Shortcuts.refusal(giving: KeyShortcut("j"), to: "reload:", overrides: [:]) == nil)
    check("the keys every Mac app has stay as they are", Shortcuts.refusal(giving: KeyShortcut("j"), to: "terminate:", overrides: [:]) == "“Quit Keel” keeps its key.")
    check("…as do the tab keys the window handles", Shortcuts.refusal(giving: KeyShortcut("j"), to: "tab.next", overrides: [:]) == "“Next tab” keeps its key.")

    let overrides: [String: KeyShortcut?] = ["reload:": KeyShortcut("j"), "findInPage:": nil]
    let changed = Shortcuts.effective(overrides: overrides)
    check("a change applies", changed["reload:"] == KeyShortcut("j"))
    check("a key can be taken away", changed["findInPage:"] == .some(nil))
    check("…and the rest keep theirs", changed["newWindow:"] == KeyShortcut("n"))
    check("a change to a fixed key is ignored", Shortcuts.effective(overrides: ["terminate:": KeyShortcut("j")])["terminate:"] == KeyShortcut("q"))
    let clash = Shortcuts.conflicts(in: Shortcuts.effective(overrides: ["reload:": KeyShortcut("t")]))
    check("two commands on one key is a conflict, naming both", clash.count == 1 && clash[0].commands == ["newWindowForTab:", "reload:"], clash)

    let table = Shortcuts.readmeTable()
    check("the README table lists every command", Shortcuts.commands.filter { !["hide:", "hideOtherApplications:", "terminate:", "performMiniaturize:", "toggleFullScreen:", "showSettings:"].contains($0.id) }
        .allSatisfy { table.contains("| \($0.title) |") })
    // The README is checked when the checks run from the repository.
    if let readme = try? String(contentsOfFile: "README.md", encoding: .utf8) {
        check("the README's shortcut table is the catalogue's", readme.contains(table), "regenerate it from Shortcuts.readmeTable()")
    }
    let encoded = try? JSONEncoder().encode(["reload:": KeyShortcut("j", [.command, .shift])])
    let decoded = encoded.flatMap { try? JSONDecoder().decode([String: KeyShortcut].self, from: $0) }
    check("changes survive a round trip through settings", decoded?["reload:"] == KeyShortcut("j", [.command, .shift]))
}

// MARK: The error page

do {
    let offline = ErrorPage.explanation(domain: "NSURLErrorDomain", code: -1009, host: "example.com")
    check("offline is said plainly", offline.title == "You’re offline" && offline.advice.contains("Connect"))
    let missing = ErrorPage.explanation(domain: "NSURLErrorDomain", code: -1003, host: "nosuch.example")
    check("an unknown host names the site", missing.title == "Can’t find “nosuch.example”")
    let refused = ErrorPage.explanation(domain: "NSURLErrorDomain", code: -1004, host: "example.com")
    check("a refused connection says so", refused.title == "“example.com” refused the connection")
    check("an unknown error is still a sentence", ErrorPage.explanation(domain: "WebKitErrorDomain", code: 999, host: nil).title == "This page could not be loaded")
    check("a port WebKit keeps closed is explained", ErrorPage.explanation(domain: "WebKitErrorDomain", code: 103, host: "127.0.0.1").title == "That address uses a port that is kept closed")
    let html = ErrorPage.html(explanation: refused, url: "http://example.com/<x>", detail: "Could not connect to the server.")
    check("the page follows light and dark", html.contains("color-scheme: light dark") && html.contains("prefers-color-scheme: dark"))
    check("…the accent colour", html.contains("background: AccentColor"))
    check("…and higher contrast", html.contains("prefers-contrast: more"))
    check("Try Again goes back to the address, escaped", html.contains("href=\"http://example.com/&lt;x&gt;\""))
    check("the system's own words are kept in Details", html.contains("<summary>Details</summary><p>Could not connect to the server.</p>"))
}

// MARK: Performance budget

do {
    let good = PerformanceMeasure(launchToWindow: 0.5, launchToPage: 1, newTabMedian: 0.2, newTabWorst: 0.5, memory20Tabs: 800, memory50Tabs: 1900,
                                  memory50TabsAfterSaver: 1200, idleCPUPercent: 1, idleSeconds: 20, build: "test")
    check("a run within every budget passes", PerformanceBudget.passes(good))
    var slow = good
    slow.launchToPage = PerformanceBudget.launchToPage + 0.01
    check("one number over its budget fails the run", !PerformanceBudget.passes(slow))
    check("…and the report says which", PerformanceBudget.report(slow).contains("✘ Cold launch to start page") && !PerformanceBudget.report(slow).contains("✘ Cold launch to first window"))
    check("the report shows seconds to two places and megabytes whole", PerformanceBudget.report(good).contains("0.50 s (budget") && PerformanceBudget.report(good).contains("800 MB (budget"))
    if let readme = try? String(contentsOfFile: "README.md", encoding: .utf8) {
        check("the README's budget table is the code's", readme.contains(PerformanceBudget.readmeTable()), "regenerate it from PerformanceBudget.readmeTable()")
    }
    let encoded = try? JSONEncoder().encode(good)
    check("a run's numbers survive the trip through JSON", encoded.flatMap { try? JSONDecoder().decode(PerformanceMeasure.self, from: $0) } == good)
}

// MARK: Where the app runs from

do {
    let home = "/Users/ada"
    check("location: /Applications needs no move", AppLocation.of(bundlePath: "/Applications/Keel.app", home: home) == .applications
          && !AppLocation.applications.shouldOfferMove)
    check("location: ~/Applications neither", AppLocation.of(bundlePath: "/Users/ada/Applications/Keel.app", home: home) == .userApplications)
    check("location: macOS's temporary copy is told apart",
          AppLocation.of(bundlePath: "/private/var/folders/x/T/AppTranslocation/6A1D/d/Keel.app", home: home) == .translocated)
    check("location: the disk image", AppLocation.of(bundlePath: "/Volumes/Keel/Keel.app", home: home) == .diskImage)
    check("location: Downloads is elsewhere, and offered a move", AppLocation.of(bundlePath: "/Users/ada/Downloads/Keel.app", home: home) == .elsewhere
          && AppLocation.elsewhere.shouldOfferMove)
    check("location: only a copy of its own goes to the Trash", AppLocation.elsewhere.removesOriginal && !AppLocation.diskImage.removesOriginal
          && !AppLocation.translocated.removesOriginal)
    check("location: a build or test copy in a temporary folder is not offered a move",
          AppLocation.of(bundlePath: "/var/folders/x/T/tmp.abc/Keel.app", home: home) == .temporary && !AppLocation.temporary.shouldOfferMove)
    check("location: /Applications-something is not /Applications", AppLocation.of(bundlePath: "/Applications Old/Keel.app", home: home) == .elsewhere)
}

print(failures == 0 ? "✔ \(passed) checks passed" : "\(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
