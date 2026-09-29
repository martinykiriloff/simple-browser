import Foundation

/// Other browsers' files as they keep them, in a scratch home folder: for
/// `DataKitChecks` and the app's self-test, which must never read the
/// person's own browsers.
public enum BrowserImportFixture {
    public static let chromeBar = ["GitHub", "Work", "Swift Forums"]
    /// The Chrome profile's most visited site.
    public static let chromeTopSite = URL(string: "https://github.com/")!
    public static let chromeLogins = [("https://accounts.example.com/", "ada@example.com", "correct horse battery"),
                                      ("https://shop.example.org/login", "ada", "hunter2 but longer")]

    /// Writes Chrome (two profiles), Firefox and Safari under `home`.
    /// `encrypt` turns a password into what Chrome stores for it. With
    /// `tabs`, the open tabs are pages of that site (`tabs` + a title), so a
    /// test that opens them loads nothing from the internet.
    public static func write(into home: URL, tabs: String? = nil, encrypt: (String) -> Data?) throws {
        func tab(_ address: String, _ title: String) -> BrowserImport.Tab {
            let local = tabs.map { $0 + (title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
            return BrowserImport.Tab(url: URL(string: local ?? address)!, title: title)
        }
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support")

        // Chrome.
        let chrome = support.appendingPathComponent("Google/Chrome")
        let profile = chrome.appendingPathComponent("Default")
        let work = chrome.appendingPathComponent("Profile 1")
        for folder in [profile, work, profile.appendingPathComponent("Sessions")] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try json(["profile": ["info_cache": ["Default": ["name": "Ada"], "Profile 1": ["name": "Work"]]]]).write(to: chrome.appendingPathComponent("Local State"))
        func url(_ name: String, _ address: String) -> [String: Any] { ["type": "url", "name": name, "url": address] }
        let bookmarks: [String: Any] = ["roots": [
            "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": [
                url("GitHub", "https://github.com/"),
                ["type": "folder", "name": "Work", "children": [url("Linear", "https://linear.app/"), url("Figma", "https://www.figma.com/")]],
                url("Swift Forums", "https://forums.swift.org/"),
            ]],
            "other": ["type": "folder", "name": "Other bookmarks", "children": [
                ["type": "folder", "name": "Recipes", "children": [url("Sourdough", "https://example.com/sourdough")]],
            ]],
            "synced": ["type": "folder", "name": "Mobile bookmarks", "children": []],
        ]]
        try json(bookmarks).write(to: profile.appendingPathComponent("Bookmarks"))
        try json(["roots": ["bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": [url("Jira", "https://jira.example.com/")]]]])
            .write(to: work.appendingPathComponent("Bookmarks"))

        let history = try SQLiteDatabase(path: profile.appendingPathComponent("History").path)
        try history.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER DEFAULT 0)")
        let now = Date()
        func chromeTime(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }
        for (address, title, visits, typed, daysAgo) in [
            ("https://github.com/", "GitHub", 120, 40, 0.1), ("https://news.ycombinator.com/", "Hacker News", 80, 30, 0.2),
            ("https://mail.google.com/mail/u/0/", "Inbox - Gmail", 60, 5, 0.3), ("https://developer.apple.com/documentation/", "Apple Developer", 25, 2, 1.5),
            ("https://en.wikipedia.org/wiki/Ada_Lovelace", "Ada Lovelace - Wikipedia", 3, 0, 20), ("chrome://settings/", "Settings", 9, 9, 0.1),
        ] {
            try history.execute("INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time) VALUES (?, ?, ?, ?, ?)",
                                [.text(address), .text(title), .int(Int64(visits)), .int(Int64(typed)), .int(chromeTime(now.addingTimeInterval(-daysAgo * 86_400)))])
        }

        let logins = try SQLiteDatabase(path: profile.appendingPathComponent("Login Data").path)
        try logins.execute("CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER DEFAULT 0)")
        for (origin, username, password) in chromeLogins {
            guard let value = encrypt(password) else { continue }
            try logins.execute("INSERT INTO logins (origin_url, username_value, password_value) VALUES (?, ?, ?)", [.text(origin), .text(username), .blob(value)])
        }
        try logins.execute("INSERT INTO logins (origin_url, username_value, password_value, blacklisted_by_user) VALUES ('https://never.example/', '', x'', 1)")

        try ChromiumSession.encode([
            [tab("https://github.com/pulls", "Pull requests"), tab("https://news.ycombinator.com/", "Hacker News")],
            [tab("https://mail.google.com/mail/u/0/", "Inbox (3) - Gmail")],
        ]).write(to: profile.appendingPathComponent("Sessions/Session_13370000000000000"))

        // Firefox.
        let firefox = support.appendingPathComponent("Firefox")
        let fox = firefox.appendingPathComponent("Profiles/abcd1234.default-release")
        try fm.createDirectory(at: fox.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
        try "[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abcd1234.default-release\nDefault=1\n"
            .write(to: firefox.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        let places = try SQLiteDatabase(path: fox.appendingPathComponent("places.sqlite").path)
        try places.execute("CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed INTEGER, last_visit_date INTEGER, hidden INTEGER DEFAULT 0)")
        try places.execute("CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT)")
        try places.execute("INSERT INTO moz_places VALUES (1, 'https://www.mozilla.org/', 'Mozilla', 12, 1, ?, 0)", [.int(Int64(now.timeIntervalSince1970 * 1_000_000))])
        try places.execute("INSERT INTO moz_places VALUES (2, 'https://developer.mozilla.org/', 'MDN Web Docs', 30, 4, ?, 0)", [.int(Int64(now.timeIntervalSince1970 * 1_000_000))])
        for row in ["(1, 2, NULL, 0, 0, '', 'root________')", "(2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____')", "(3, 2, NULL, 1, 1, 'menu', 'menu________')",
                    "(4, 1, 2, 2, 0, 'MDN', 'aaaa')", "(5, 2, NULL, 3, 0, 'Mozilla things', 'bbbb')", "(6, 1, 1, 5, 0, 'Mozilla', 'cccc')"] {
            try places.execute("INSERT INTO moz_bookmarks VALUES \(row)")
        }
        let session: [String: Any] = ["windows": [["selected": 1, "tabs": [
            ["index": 2, "entries": [["url": "https://www.mozilla.org/", "title": "Mozilla"], ["url": tab("https://developer.mozilla.org/", "MDN Web Docs").url.absoluteString, "title": "MDN Web Docs"]]],
            ["index": 1, "entries": [["url": "about:preferences", "title": "Settings"]]],
        ]]]]
        try MozLZ4.encode(try json(session)).write(to: fox.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"))

        // Safari.
        let safari = home.appendingPathComponent("Library/Safari")
        try fm.createDirectory(at: safari, withIntermediateDirectories: true)
        func leaf(_ title: String, _ address: String) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": address, "URIDictionary": ["title": title]]
        }
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [leaf("Apple", "https://www.apple.com/")]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "Children": [leaf("WebKit", "https://webkit.org/")]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [leaf("A long read", "https://example.com/long-read")]],
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: safari.appendingPathComponent("Bookmarks.plist"))
        let safariHistory = try SQLiteDatabase(path: safari.appendingPathComponent("History.db").path)
        try safariHistory.execute("CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER)")
        try safariHistory.execute("CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)")
        try safariHistory.execute("INSERT INTO history_items VALUES (1, 'https://www.apple.com/', 7)")
        try safariHistory.execute("INSERT INTO history_visits VALUES (1, 1, ?, 'Apple')", [.double(now.timeIntervalSinceReferenceDate - 3600)])
        try safariHistory.execute("INSERT INTO history_visits VALUES (2, 1, ?, 'Apple (new)')", [.double(now.timeIntervalSinceReferenceDate)])
    }

    private static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}
