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

print(failures == 0 ? "✔ all \(passed) DataKit checks passed" : "✘ \(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
