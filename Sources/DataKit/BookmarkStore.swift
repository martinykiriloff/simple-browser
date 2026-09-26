import Foundation

/// One profile's bookmarks and reading list.
///
/// Bookmarks are a tree under two fixed folders, as Safari has them:
/// Favorites (shown in the favorites bar and on the start page) and the
/// Bookmarks Menu. Order within a folder is kept exactly as the person
/// arranged it.
public final class BookmarkStore {
    public enum Kind: String, Sendable { case folder, bookmark }

    public struct Node: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let parent: Int64?
        public let kind: Kind
        public var title: String
        public var url: URL?
        public let position: Int
    }

    public struct ReadingItem: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let url: URL
        public let title: String
        public let addedAt: Date
        public let isRead: Bool
    }

    public enum StoreError: Error, Equatable { case notAFolder, cannotMoveIntoItself, fixedFolder }

    private let db: SQLiteDatabase
    public private(set) var favoritesID: Int64 = 0
    public private(set) var menuID: Int64 = 0

    public init(path: String?) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS nodes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                parent INTEGER REFERENCES nodes(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', url TEXT,
                position REAL NOT NULL, special TEXT UNIQUE, created REAL NOT NULL)
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS nodes_parent ON nodes(parent, position)")
        try db.execute("CREATE INDEX IF NOT EXISTS nodes_url ON nodes(url)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS reading (
                id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '',
                added REAL NOT NULL, read INTEGER NOT NULL DEFAULT 0)
            """)
        favoritesID = try special("favorites", title: "Favorites", position: 0)
        menuID = try special("menu", title: "Bookmarks Menu", position: 1)
    }

    private func special(_ name: String, title: String, position: Double) throws -> Int64 {
        if let id = try db.query("SELECT id FROM nodes WHERE special = ?", [.text(name)]).first?.int("id") { return id }
        try db.execute("INSERT INTO nodes (parent, kind, title, position, special, created) VALUES (NULL, 'folder', ?, ?, ?, ?)",
                       [.text(title), .double(position), .text(name), .double(Date().timeIntervalSince1970)])
        return db.lastInsertID
    }

    // MARK: - Reading the tree

    public func children(of folder: Int64) throws -> [Node] {
        try db.query("SELECT * FROM nodes WHERE parent = ? ORDER BY position, id", [.int(folder)]).enumerated().compactMap { index, row in
            Self.node(row, position: index)
        }
    }

    public func node(_ id: Int64) throws -> Node? {
        try db.query("SELECT * FROM nodes WHERE id = ?", [.int(id)]).first.flatMap { Self.node($0, position: 0) }
    }

    public var favorites: [Node] { (try? children(of: favoritesID)) ?? [] }

    /// Every folder a bookmark can go in, depth-first, with its depth, for pickers.
    public func folders() throws -> [(node: Node, depth: Int)] {
        var result: [(Node, Int)] = []
        func walk(_ id: Int64, _ depth: Int) throws {
            guard let node = try node(id) else { return }
            result.append((node, depth))
            for child in try children(of: id) where child.kind == .folder { try walk(child.id, depth + 1) }
        }
        try walk(favoritesID, 0)
        try walk(menuID, 0)
        return result
    }

    /// Bookmarks whose title or address matches every word.
    public func search(_ query: String, limit: Int = 50) throws -> [Node] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var clauses = ["kind = 'bookmark'"]
        var arguments: [SQLiteDatabase.Value] = []
        for word in words {
            clauses.append("(title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')")
            let pattern = "%" + HistoryStore.escapeLike(word) + "%"
            arguments += [.text(pattern), .text(pattern)]
        }
        arguments.append(.int(Int64(limit)))
        return try db.query("SELECT * FROM nodes WHERE " + clauses.joined(separator: " AND ") + " ORDER BY title LIMIT ?", arguments)
            .compactMap { Self.node($0, position: 0) }
    }

    /// The bookmark for a page, if there is one (the star fills in).
    public func bookmark(for url: URL) throws -> Node? {
        try db.query("SELECT * FROM nodes WHERE kind = 'bookmark' AND url = ? ORDER BY id LIMIT 1", [.text(url.absoluteString)])
            .first.flatMap { Self.node($0, position: 0) }
    }

    // MARK: - Changing the tree

    /// At the end of the folder, or before the item now at `index`.
    @discardableResult
    public func addBookmark(url: URL, title: String, in folder: Int64, at index: Int? = nil) throws -> Int64 {
        try insert(kind: .bookmark, title: title, url: url, in: folder, at: index)
    }

    @discardableResult
    public func addFolder(_ title: String, in folder: Int64, at index: Int? = nil) throws -> Int64 {
        try insert(kind: .folder, title: title, url: nil, in: folder, at: index)
    }

    private func insert(kind: Kind, title: String, url: URL?, in folder: Int64, at index: Int?) throws -> Int64 {
        guard try node(folder)?.kind == .folder else { throw StoreError.notAFolder }
        let position = try position(in: folder, at: index, excluding: nil)
        try db.execute("INSERT INTO nodes (parent, kind, title, url, position, created) VALUES (?, ?, ?, ?, ?, ?)",
                       [.int(folder), .text(kind.rawValue), .text(title), url.map { .text($0.absoluteString) } ?? .null,
                        .double(position), .double(Date().timeIntervalSince1970)])
        return db.lastInsertID
    }

    public func rename(_ id: Int64, to title: String) throws {
        try db.execute("UPDATE nodes SET title = ? WHERE id = ? AND special IS NULL", [.text(title), .int(id)])
    }

    public func setURL(_ id: Int64, to url: URL) throws {
        try db.execute("UPDATE nodes SET url = ? WHERE id = ? AND kind = 'bookmark'", [.text(url.absoluteString), .int(id)])
    }

    /// Moves an item (and a folder's contents) to `folder`, before the item
    /// now at `index` there, or to the end.
    public func move(_ id: Int64, to folder: Int64, at index: Int? = nil) throws {
        guard id != favoritesID, id != menuID else { throw StoreError.fixedFolder }
        guard try node(folder)?.kind == .folder else { throw StoreError.notAFolder }
        var cursor: Int64? = folder
        while let current = cursor {
            if current == id { throw StoreError.cannotMoveIntoItself }
            cursor = try node(current)?.parent
        }
        let position = try position(in: folder, at: index, excluding: id)
        try db.execute("UPDATE nodes SET parent = ?, position = ? WHERE id = ?", [.int(folder), .double(position), .int(id)])
    }

    public func delete(_ id: Int64) throws {
        guard id != favoritesID, id != menuID else { throw StoreError.fixedFolder }
        try db.execute("DELETE FROM nodes WHERE id = ?", [.int(id)])
    }

    /// A position between neighbours, renumbering the folder when they get too close.
    private func position(in folder: Int64, at index: Int?, excluding id: Int64?) throws -> Double {
        var siblings = try db.query("SELECT id, position FROM nodes WHERE parent = ? ORDER BY position, id", [.int(folder)])
            .filter { $0.int("id") != id }
        let positions = siblings.compactMap { $0.double("position") }
        let target = min(index ?? positions.count, positions.count)
        let before = target > 0 ? positions[target - 1] : positions.first.map { $0 - 2 } ?? 0
        let after = target < positions.count ? positions[target] : before + 2
        if after - before > 1e-6 { return (before + after) / 2 }
        try db.transaction {
            for (offset, row) in siblings.enumerated() {
                try db.execute("UPDATE nodes SET position = ? WHERE id = ?", [.double(Double(offset) * 2), .int(row.int("id") ?? 0)])
            }
        }
        siblings = []
        return try position(in: folder, at: index, excluding: id)
    }

    // MARK: - Reading list

    @discardableResult
    public func addToReadingList(url: URL, title: String, at date: Date = .now) throws -> Int64 {
        try db.execute("""
            INSERT INTO reading (url, title, added, read) VALUES (?, ?, ?, 0)
            ON CONFLICT(url) DO UPDATE SET title = excluded.title, added = excluded.added, read = 0
            """, [.text(url.absoluteString), .text(title), .double(date.timeIntervalSince1970)])
        return try db.query("SELECT id FROM reading WHERE url = ?", [.text(url.absoluteString)]).first?.int("id") ?? db.lastInsertID
    }

    public func readingList(includeRead: Bool = true) throws -> [ReadingItem] {
        try db.query("SELECT * FROM reading" + (includeRead ? "" : " WHERE read = 0") + " ORDER BY added DESC").compactMap { row in
            guard let id = row.int("id"), let text = row.text("url"), let url = URL(string: text) else { return nil }
            return ReadingItem(id: id, url: url, title: row.text("title") ?? "", addedAt: Date(timeIntervalSince1970: row.double("added") ?? 0),
                               isRead: row.int("read") == 1)
        }
    }

    public func readingItem(for url: URL) throws -> ReadingItem? {
        try readingList().first { $0.url == url }
    }

    public func markRead(_ id: Int64, _ read: Bool = true) throws {
        try db.execute("UPDATE reading SET read = ? WHERE id = ?", [.int(read ? 1 : 0), .int(id)])
    }

    public func removeFromReadingList(_ id: Int64) throws {
        try db.execute("DELETE FROM reading WHERE id = ?", [.int(id)])
    }

    private static func node(_ row: [String: SQLiteDatabase.Value], position: Int) -> Node? {
        guard let id = row.int("id"), let kind = row.text("kind").flatMap(Kind.init) else { return nil }
        return Node(id: id, parent: row.int("parent"), kind: kind, title: row.text("title") ?? "",
                    url: row.text("url").flatMap(URL.init(string:)), position: position)
    }
}
