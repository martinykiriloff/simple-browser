import Foundation

/// One profile's browsing history: every visit, and per page its title, how
/// often and how recently it was visited, and whether it was typed.
///
/// Feeds the History window, the History menu, the address bar's
/// suggestions and the start page's frequently visited sites.
public final class HistoryStore {
    public struct Visit: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let url: URL
        public let title: String
        public let visitedAt: Date
    }

    public struct Page: Equatable, Sendable {
        public let url: URL
        public let title: String
        public let visitCount: Int
        public let typedCount: Int
        public let lastVisit: Date

        /// Chrome's "frecency", simplified: visits weigh more when recent,
        /// and a page someone typed weighs more than one they were sent to.
        public func score(now: Date = .now) -> Double {
            let days = max(0, now.timeIntervalSince(lastVisit) / 86_400)
            let recency = days < 1 ? 100.0 : days < 4 ? 70 : days < 14 ? 50 : days < 31 ? 30 : days < 90 ? 10 : 1
            return Double(visitCount + typedCount * 3) * recency
        }
    }

    private let db: SQLiteDatabase

    /// `nil` keeps it in memory: for tests, and never written for private windows.
    public init(path: String?) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS pages (
                url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 0, typed_count INTEGER NOT NULL DEFAULT 0,
                last_visit REAL NOT NULL)
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL REFERENCES pages(url) ON DELETE CASCADE,
                visited_at REAL NOT NULL)
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS visits_time ON visits(visited_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS visits_url ON visits(url)")
    }

    /// Only pages a person can go back to: http and https. A reload within a
    /// minute of the last visit to the same page is not a new visit.
    public func recordVisit(_ url: URL, title: String = "", typed: Bool = false, at date: Date = .now) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        try db.transaction {
            let existing = try db.query("SELECT last_visit FROM pages WHERE url = ?", [.text(key)]).first?.double("last_visit")
            let time = date.timeIntervalSince1970
            if let existing, time - existing < 60, time >= existing {
                // A reload, or the page reached again moments later: the same visit.
                try db.execute("UPDATE pages SET last_visit = ?, typed_count = typed_count + ?, title = CASE WHEN ? = '' THEN title ELSE ? END WHERE url = ?",
                               [.double(time), .int(typed ? 1 : 0), .text(title), .text(title), .text(key)])
                try db.execute("UPDATE visits SET visited_at = ? WHERE id = (SELECT MAX(id) FROM visits WHERE url = ?)", [.double(time), .text(key)])
                return
            }
            try db.execute("""
                INSERT INTO pages (url, title, visit_count, typed_count, last_visit) VALUES (?, ?, 1, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = CASE WHEN excluded.title = '' THEN pages.title ELSE excluded.title END,
                    visit_count = pages.visit_count + 1,
                    typed_count = pages.typed_count + excluded.typed_count,
                    last_visit = MAX(pages.last_visit, excluded.last_visit)
                """, [.text(key), .text(title), .int(typed ? 1 : 0), .double(time)])
            try db.execute("INSERT INTO visits (url, visited_at) VALUES (?, ?)", [.text(key), .double(time)])
        }
    }

    /// Pages from another browser's history, with its counts, so the most
    /// visited sites are the same here from the start. Counts are taken as
    /// the larger of the two, not added, so importing again changes nothing;
    /// each page gets its last visit, for the History window.
    @discardableResult
    public func importPages(_ pages: [BrowserImport.Page]) throws -> Int {
        var added = 0
        try db.transaction {
            for page in pages {
                guard let scheme = page.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                let key = page.url.absoluteString, time = page.lastVisit.timeIntervalSince1970
                let known = try db.query("SELECT 1 FROM pages WHERE url = ?", [.text(key)]).isEmpty == false
                try db.execute("""
                    INSERT INTO pages (url, title, visit_count, typed_count, last_visit) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        title = CASE WHEN pages.title = '' THEN excluded.title ELSE pages.title END,
                        visit_count = MAX(pages.visit_count, excluded.visit_count),
                        typed_count = MAX(pages.typed_count, excluded.typed_count),
                        last_visit = MAX(pages.last_visit, excluded.last_visit)
                    """, [.text(key), .text(page.title), .int(Int64(max(1, page.visitCount))), .int(Int64(page.typedCount)), .double(time)])
                if try db.query("SELECT 1 FROM visits WHERE url = ? AND visited_at = ?", [.text(key), .double(time)]).isEmpty {
                    try db.execute("INSERT INTO visits (url, visited_at) VALUES (?, ?)", [.text(key), .double(time)])
                }
                if !known { added += 1 }
            }
        }
        return added
    }

    /// Titles arrive after the page loads.
    public func updateTitle(_ title: String, for url: URL) throws {
        guard !title.isEmpty else { return }
        try db.execute("UPDATE pages SET title = ? WHERE url = ?", [.text(title), .text(url.absoluteString)])
    }

    /// Newest first, optionally matching words in the title or address.
    public func visits(matching query: String = "", limit: Int = 500, before: Date? = nil) throws -> [Visit] {
        var sql = "SELECT visits.id, visits.url, visits.visited_at, pages.title FROM visits JOIN pages ON pages.url = visits.url"
        var clauses: [String] = []
        var arguments: [SQLiteDatabase.Value] = []
        for word in query.split(whereSeparator: \.isWhitespace) {
            clauses.append("(pages.title LIKE ? ESCAPE '\\' OR visits.url LIKE ? ESCAPE '\\')")
            let pattern = "%" + Self.escapeLike(String(word)) + "%"
            arguments += [.text(pattern), .text(pattern)]
        }
        if let before {
            clauses.append("visits.visited_at < ?")
            arguments.append(.double(before.timeIntervalSince1970))
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY visits.visited_at DESC LIMIT ?"
        arguments.append(.int(Int64(limit)))
        return try db.query(sql, arguments).compactMap { row in
            guard let id = row.int("id"), let text = row.text("url"), let url = URL(string: text), let time = row.double("visited_at") else { return nil }
            return Visit(id: id, url: url, title: row.text("title") ?? "", visitedAt: Date(timeIntervalSince1970: time))
        }
    }

    /// Pages whose address or title matches, best first, for the address bar.
    public func pages(matching query: String, limit: Int = 8, now: Date = .now) throws -> [Page] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var clauses: [String] = []
        var arguments: [SQLiteDatabase.Value] = []
        for word in words {
            clauses.append("(title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')")
            let pattern = "%" + Self.escapeLike(word) + "%"
            arguments += [.text(pattern), .text(pattern)]
        }
        let rows = try db.query("SELECT * FROM pages WHERE " + clauses.joined(separator: " AND ") + " ORDER BY last_visit DESC LIMIT 400", arguments)
        return rows.compactMap(Self.page).sorted { $0.score(now: now) > $1.score(now: now) }.prefix(limit).map { $0 }
    }

    /// The most visited pages, weighted by recency, for the start page.
    public func topPages(limit: Int = 12, now: Date = .now) throws -> [Page] {
        try db.query("SELECT * FROM pages ORDER BY visit_count + typed_count * 3 DESC, last_visit DESC LIMIT 300")
            .compactMap(Self.page).sorted { $0.score(now: now) > $1.score(now: now) }.prefix(limit).map { $0 }
    }

    public func page(for url: URL) throws -> Page? {
        try db.query("SELECT * FROM pages WHERE url = ?", [.text(url.absoluteString)]).first.flatMap(Self.page)
    }

    public func deleteVisit(_ id: Int64) throws {
        try db.transaction {
            let url = try db.query("SELECT url FROM visits WHERE id = ?", [.int(id)]).first?.text("url")
            try db.execute("DELETE FROM visits WHERE id = ?", [.int(id)])
            if let url { try refreshPage(url) }
        }
    }

    /// Every visit to this page, and the page.
    public func deletePage(_ url: URL) throws {
        try db.execute("DELETE FROM pages WHERE url = ?", [.text(url.absoluteString)])
    }

    /// Visits at or after `date`; `.distantPast` clears everything.
    public func deleteVisits(since date: Date) throws {
        try db.transaction {
            let urls = try db.query("SELECT DISTINCT url FROM visits WHERE visited_at >= ?", [.double(date.timeIntervalSince1970)]).compactMap { $0.text("url") }
            try db.execute("DELETE FROM visits WHERE visited_at >= ?", [.double(date.timeIntervalSince1970)])
            for url in urls { try refreshPage(url) }
        }
    }

    /// Keeps a year, as Safari does by default.
    public func prune(olderThan date: Date) throws {
        try deleteVisits(before: date)
    }

    private func deleteVisits(before date: Date) throws {
        try db.transaction {
            try db.execute("DELETE FROM visits WHERE visited_at < ?", [.double(date.timeIntervalSince1970)])
            try db.execute("DELETE FROM pages WHERE url NOT IN (SELECT url FROM visits)")
        }
    }

    public var visitCount: Int { (try? db.query("SELECT COUNT(*) AS n FROM visits").first?.int("n")).map { Int($0) } ?? 0 }

    /// After visits go: the page's counts follow, and a page with none left goes.
    private func refreshPage(_ url: String) throws {
        let row = try db.query("SELECT COUNT(*) AS n, MAX(visited_at) AS last FROM visits WHERE url = ?", [.text(url)]).first
        let count = row?.int("n") ?? 0
        if count == 0 {
            try db.execute("DELETE FROM pages WHERE url = ?", [.text(url)])
        } else {
            try db.execute("UPDATE pages SET visit_count = ?, typed_count = MIN(typed_count, ?), last_visit = ? WHERE url = ?",
                           [.int(count), .int(count), .double(row?.double("last") ?? 0), .text(url)])
        }
    }

    private static func page(_ row: [String: SQLiteDatabase.Value]) -> Page? {
        guard let text = row.text("url"), let url = URL(string: text), let last = row.double("last_visit") else { return nil }
        return Page(url: url, title: row.text("title") ?? "", visitCount: Int(row.int("visit_count") ?? 0),
                    typedCount: Int(row.int("typed_count") ?? 0), lastVisit: Date(timeIntervalSince1970: last))
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}
