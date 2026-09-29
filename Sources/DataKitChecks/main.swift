import Foundation
import DataKit

// Unit checks for DataKit: `swift run DataKitChecks`.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
}

func url(_ text: String) -> URL { URL(string: text)! }

// MARK: History

do {
    let history = try HistoryStore(path: nil)
    let now = Date()
    let day: TimeInterval = 86_400
    try history.recordVisit(url("https://github.com/"), title: "GitHub", typed: true, at: now.addingTimeInterval(-2 * day))
    try history.recordVisit(url("https://github.com/"), title: "GitHub", at: now.addingTimeInterval(-1 * day))
    try history.recordVisit(url("https://github.com/"), at: now.addingTimeInterval(-day + 20))           // a reload
    try history.recordVisit(url("https://news.example/a"), title: "A news story", at: now.addingTimeInterval(-3600))
    try history.recordVisit(url("https://old.example/"), title: "Old", at: now.addingTimeInterval(-400 * day))
    try history.recordVisit(url("about:blank"), at: now)
    try history.recordVisit(url("file:///etc/hosts"), at: now)

    check("only web pages are recorded", history.visitCount == 4, history.visitCount)
    let github = try history.page(for: url("https://github.com/"))
    check("a reload within a minute is not another visit", github?.visitCount == 2, github?.visitCount as Any)
    check("an empty title does not erase a known one", github?.title == "GitHub")
    check("typed visits are counted", github?.typedCount == 1)

    let recent = try history.visits()
    check("visits come newest first", recent.first?.url.host() == "news.example", recent.map { $0.url.host() ?? "" })
    check("search matches the title", try history.visits(matching: "news story").map(\.url.host) == ["news.example"])
    check("search matches the address", try history.visits(matching: "old.exa").count == 1)
    check("every word must match", try history.visits(matching: "github news").isEmpty)
    check("% and _ are literal in a search", try history.visits(matching: "100%").isEmpty && history.visits(matching: "_").isEmpty)

    let suggestions = try history.pages(matching: "git", now: now)
    check("the address bar finds a page by part of its address", suggestions.first?.url.host() == "github.com")
    let top = try history.topPages(now: now)
    check("the most visited, recent page is top", top.first?.url.host() == "github.com", top.map { $0.url.host() ?? "" })
    let old = try history.page(for: url("https://old.example/"))
    check("frecency: a recent visit beats an old one", (github?.score(now: now) ?? 0) > (old?.score(now: now) ?? 0))

    try history.updateTitle("GitHub · Build software", for: url("https://github.com/"))
    check("titles can arrive later", try history.page(for: url("https://github.com/"))?.title == "GitHub · Build software")

    try history.deleteVisits(since: now.addingTimeInterval(-7200))
    check("clearing the last two hours removes that visit", try history.page(for: url("https://news.example/a")) == nil)
    check("…and nothing older", try history.page(for: url("https://github.com/"))?.visitCount == 2)

    if let visit = try history.visits(matching: "github").first {
        try history.deleteVisit(visit.id)
        check("deleting one visit lowers the count", try history.page(for: url("https://github.com/"))?.visitCount == 1)
    }
    try history.prune(olderThan: now.addingTimeInterval(-365 * day))
    check("pruning drops pages older than a year", try history.page(for: url("https://old.example/")) == nil)

    try history.deleteVisits(since: .distantPast)
    let remaining = try history.topPages()
    check("clearing everything leaves nothing", history.visitCount == 0 && remaining.isEmpty)
} catch {
    check("history checks", false, error)
}

do {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
    try HistoryStore(path: file.path).recordVisit(url("https://example.com/"), title: "Example")
    check("history survives reopening", try HistoryStore(path: file.path).page(for: url("https://example.com/"))?.title == "Example")
} catch {
    check("history on disk", false, error)
}

// MARK: Bookmarks

do {
    let bookmarks = try BookmarkStore(path: nil)
    check("two fixed folders exist", bookmarks.favoritesID != bookmarks.menuID && bookmarks.favorites.isEmpty)
    let github = try bookmarks.addBookmark(url: url("https://github.com/"), title: "GitHub", in: bookmarks.favoritesID)
    let news = try bookmarks.addBookmark(url: url("https://news.example/"), title: "News", in: bookmarks.favoritesID)
    let first = try bookmarks.addBookmark(url: url("https://first.example/"), title: "First", in: bookmarks.favoritesID, at: 0)
    check("insertion keeps the order asked for", bookmarks.favorites.map(\.title) == ["First", "GitHub", "News"], bookmarks.favorites.map(\.title))

    let work = try bookmarks.addFolder("Work", in: bookmarks.menuID)
    try bookmarks.move(news, to: work)
    check("moving into a folder", try bookmarks.children(of: work).map(\.title) == ["News"])
    check("…takes it out of the old one", bookmarks.favorites.map(\.title) == ["First", "GitHub"])
    try bookmarks.move(first, to: bookmarks.favoritesID, at: 2)
    check("reordering within a folder", bookmarks.favorites.map(\.title) == ["GitHub", "First"], bookmarks.favorites.map(\.title))
    for i in 0..<60 { try bookmarks.move(github, to: bookmarks.favoritesID, at: i % 2 == 0 ? 0 : 2) }
    check("positions survive many moves", bookmarks.favorites.count == 2)

    let inner = try bookmarks.addFolder("Inner", in: work)
    do { try bookmarks.move(work, to: inner); check("a folder cannot go inside itself", false) }
    catch { check("a folder cannot go inside itself", error as? BookmarkStore.StoreError == .cannotMoveIntoItself) }
    do { try bookmarks.delete(bookmarks.favoritesID); check("Favorites cannot be deleted", false) }
    catch { check("Favorites cannot be deleted", error as? BookmarkStore.StoreError == .fixedFolder) }
    do { try bookmarks.addBookmark(url: url("https://x/"), title: "x", in: github); check("a bookmark is not a folder", false) }
    catch { check("a bookmark is not a folder", error as? BookmarkStore.StoreError == .notAFolder) }

    check("the star knows a bookmarked page", try bookmarks.bookmark(for: url("https://github.com/"))?.id == github)
    check("…and one that is not", try bookmarks.bookmark(for: url("https://nothing.example/")) == nil)
    check("search finds by title", try bookmarks.search("git").map(\.id) == [github])
    check("search finds by address", try bookmarks.search("news.exa").map(\.id) == [news])
    let folders = try bookmarks.folders()
    check("the folder picker lists every folder with its depth", folders.map { "\($0.depth)\($0.node.title)" } == ["0Favorites", "0Bookmarks Menu", "1Work", "2Inner"],
          folders.map { "\($0.depth)\($0.node.title)" })

    try bookmarks.rename(github, to: "GitHub · Code")
    check("rename", try bookmarks.node(github)?.title == "GitHub · Code")
    try bookmarks.delete(work)
    let gone = try bookmarks.node(news) == nil
    let innerGone = try bookmarks.node(inner) == nil
    check("deleting a folder deletes what is in it", gone && innerGone)

    let a = try bookmarks.addToReadingList(url: url("https://long.read/"), title: "Long read")
    try bookmarks.addToReadingList(url: url("https://other.read/"), title: "Other", at: Date().addingTimeInterval(10))
    check("the reading list is newest first", try bookmarks.readingList().map(\.title) == ["Other", "Long read"])
    try bookmarks.markRead(a)
    check("read items can be hidden", try bookmarks.readingList(includeRead: false).map(\.title) == ["Other"])
    let again = try bookmarks.addToReadingList(url: url("https://long.read/"), title: "Long read")
    let unread = try bookmarks.readingList(includeRead: false)
    check("adding it again brings it back unread, not twice", again == a && unread.count == 2)
    try bookmarks.removeFromReadingList(a)
    check("remove from the reading list", try bookmarks.readingList().count == 1)
} catch {
    check("bookmark checks", false, error)
}

// MARK: Importing from other browsers

do {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("DataKitChecks-import-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try BrowserImportFixture.write(into: home) { Data("v10".utf8) + Data($0.utf8) }
    let sources = BrowserImport.sources(home: home)
    check("import: every browser and profile is found", sources.map(\.title) == ["Google Chrome — Ada", "Google Chrome — Work", "Firefox", "Safari"], sources.map(\.title))
    check("import: Safari's files, readable here, need no Full Disk Access", sources.last?.needsFullDiskAccess == false)

    let chrome = try BrowserImport.read(sources[0])
    check("chrome: the bookmarks bar, folders kept", chrome.bookmarksBar.map(\.title) == BrowserImportFixture.chromeBar
          && chrome.bookmarksBar[1].children.map(\.title) == ["Linear", "Figma"], chrome.bookmarksBar.map(\.title))
    check("chrome: the other bookmarks", chrome.otherBookmarks.map(\.title) == ["Recipes"] && chrome.otherBookmarks[0].count == 1)
    check("chrome: history, web pages only, with counts and times", chrome.history.count == 5 && chrome.history.first?.url == BrowserImportFixture.chromeTopSite
          && chrome.history.first?.visitCount == 120 && abs(chrome.history.first!.lastVisit.timeIntervalSinceNow + 8640) < 60, chrome.history.map(\.url))
    check("chrome: the open tabs of the last session, by window", chrome.windows.map { $0.map(\.title) } == [["Pull requests", "Hacker News"], ["Inbox (3) - Gmail"]],
          chrome.windows)
    check("chrome: sign-ins, not the sites it was told never to save", chrome.logins.map(\.origin) == BrowserImportFixture.chromeLogins.map(\.0)
          && String(decoding: chrome.logins[0].encryptedPassword.dropFirst(3), as: UTF8.self) == "correct horse battery")
    check("chrome: only what was asked for is read", try BrowserImport.read(sources[0], parts: .bookmarks).history.isEmpty)
    check("chrome: the other profile is its own", try BrowserImport.read(sources[1]).bookmarksBar.map(\.title) == ["Jira"])

    let firefox = try BrowserImport.read(sources[2])
    check("firefox: the toolbar and the menu's folders", firefox.bookmarksBar.map(\.title) == ["MDN"] && firefox.otherBookmarks.map(\.title) == ["Mozilla things"],
          (firefox.bookmarksBar.map(\.title), firefox.otherBookmarks.map(\.title)))
    check("firefox: history", Set(firefox.history.map(\.title)) == ["Mozilla", "MDN Web Docs"] && firefox.history.first { $0.title == "MDN Web Docs" }?.typedCount == 4)
    check("firefox: the open tabs, each at the page it was on, not its own pages", firefox.windows.map { $0.map(\.url.absoluteString) } == [["https://developer.mozilla.org/"]],
          firefox.windows)

    let safari = try BrowserImport.read(sources[3])
    check("safari: the favorites bar, the menu and the reading list", safari.bookmarksBar.map(\.title) == ["Apple"] && safari.otherBookmarks.map(\.title) == ["WebKit"]
          && safari.readingList.map(\.title) == ["A long read"], (safari.bookmarksBar, safari.otherBookmarks, safari.readingList))
    check("safari: history, with the newest title", safari.history.map(\.title) == ["Apple (new)"] && safari.history.first?.visitCount == 7)

    // Into the browser's own stores.
    let bookmarks = try BookmarkStore(path: nil)
    try bookmarks.addBookmark(url: url("https://forums.swift.org/"), title: "Already here", in: bookmarks.favoritesID)
    let barAdded = try bookmarks.importBookmarks(chrome.bookmarksBar, into: bookmarks.favoritesID)
    check("import: the bar becomes the favorites bar, less what is already bookmarked", barAdded == 3
          && bookmarks.favorites.map(\.title) == ["Already here", "GitHub", "Work"], bookmarks.favorites.map(\.title))
    let folder = try bookmarks.importFolder(named: "Imported from Google Chrome")
    try bookmarks.importBookmarks(chrome.otherBookmarks, into: folder)
    check("import: the rest in a folder of the Bookmarks menu", try bookmarks.children(of: folder).map(\.title) == ["Recipes"])
    let again = try bookmarks.importBookmarks(chrome.bookmarksBar, into: bookmarks.favoritesID) + bookmarks.importBookmarks(chrome.otherBookmarks, into: bookmarks.importFolder(named: "Imported from Google Chrome"))
    let menuFolders = try bookmarks.children(of: bookmarks.menuID).count
    check("import: importing again adds nothing", again == 0 && bookmarks.favorites.count == 3 && menuFolders == 1)
    let firstRead = try bookmarks.importReadingList(safari.readingList), secondRead = try bookmarks.importReadingList(safari.readingList)
    check("import: the reading list", firstRead == 1 && secondRead == 0)

    let history = try HistoryStore(path: nil)
    try history.recordVisit(url("https://news.ycombinator.com/"), title: "HN", at: Date().addingTimeInterval(-100))
    let pages = try history.importPages(chrome.history)
    check("import: history pages", pages == 4, pages)
    check("import: …so the most visited sites are the same here", try history.topPages(limit: 3).map(\.url) == [BrowserImportFixture.chromeTopSite, url("https://news.ycombinator.com/"), url("https://mail.google.com/mail/u/0/")],
          try history.topPages(limit: 3).map(\.url))
    check("import: a title already here is kept", try history.page(for: url("https://news.ycombinator.com/"))?.title == "HN")
    check("import: …and each is in the History list", try history.visits(limit: 50).count == 6)
    _ = try history.importPages(chrome.history)
    let top = try history.page(for: BrowserImportFixture.chromeTopSite)?.visitCount, visits = try history.visits(limit: 50).count
    check("import: importing again changes nothing", top == 120 && visits == 6)

    check("mozlz4: round trip", MozLZ4.decode(MozLZ4.encode(Data("hello hello hello hello".utf8))) == Data("hello hello hello hello".utf8))
    check("mozlz4: anything else is not taken", MozLZ4.decode(Data("not a session".utf8)) == nil)
    check("snss: anything else is not taken", ChromiumSession.windows(from: Data("hello".utf8)).isEmpty)
} catch {
    check("import checks", false, error)
}

print(failures == 0 ? "✔ all \(passed) DataKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
