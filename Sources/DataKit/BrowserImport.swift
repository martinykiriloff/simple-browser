import Foundation
import Compression

/// Reading another browser's bookmarks, history, open tabs and (for
/// Chromium) its saved sign-ins, straight from its files: no export. Every
/// file is copied before it is read, since a running browser holds its
/// databases locked, and nothing of the other browser is ever written.
public enum BrowserImport {

    public enum Browser: String, CaseIterable, Sendable {
        case chrome, brave, edge, arc, vivaldi, chromium, firefox, safari

        public var name: String {
            switch self {
            case .chrome: return "Google Chrome"
            case .brave: return "Brave"
            case .edge: return "Microsoft Edge"
            case .arc: return "Arc"
            case .vivaldi: return "Vivaldi"
            case .chromium: return "Chromium"
            case .firefox: return "Firefox"
            case .safari: return "Safari"
            }
        }

        var isChromium: Bool { self != .firefox && self != .safari }

        /// Where its profiles are, under ~/Library/Application Support.
        var supportPath: String? {
            switch self {
            case .chrome: return "Google/Chrome"
            case .brave: return "BraveSoftware/Brave-Browser"
            case .edge: return "Microsoft Edge"
            case .arc: return "Arc/User Data"
            case .vivaldi: return "Vivaldi"
            case .chromium: return "Chromium"
            case .firefox: return "Firefox"
            case .safari: return nil
            }
        }

        /// The Keychain item a Chromium browser keeps its password key in.
        public var safeStorageService: String? {
            switch self {
            case .chrome: return "Chrome Safe Storage"
            case .brave: return "Brave Safe Storage"
            case .edge: return "Microsoft Edge Safe Storage"
            case .arc: return "Arc Safe Storage"
            case .vivaldi: return "Vivaldi Safe Storage"
            case .chromium: return "Chromium Safe Storage"
            case .firefox, .safari: return nil
            }
        }
    }

    /// One profile of one browser, to import from.
    public struct Source: Equatable, Sendable {
        public let browser: Browser
        public let profile: String
        public let directory: URL
        /// Safari's folder is there but macOS keeps it from other apps
        /// until SimpleBrowser has Full Disk Access.
        public let needsFullDiskAccess: Bool

        public var title: String { profile.isEmpty ? browser.name : "\(browser.name) — \(profile)" }
        /// What this browser keeps that can be brought over.
        public var offersPasswords: Bool { browser.isChromium }
        public var offersOpenTabs: Bool { browser != .safari }
    }

    public struct Bookmark: Equatable, Sendable {
        public var title: String
        public var url: URL?
        public var children: [Bookmark]
        public init(title: String, url: URL? = nil, children: [Bookmark] = []) {
            self.title = title
            self.url = url
            self.children = children
        }
        public var isFolder: Bool { url == nil }
        /// How many bookmarks, folders not counted.
        public var count: Int { isFolder ? children.reduce(0) { $0 + $1.count } : 1 }
    }

    public struct Page: Equatable, Sendable {
        public let url: URL
        public let title: String
        public let visitCount: Int
        public let typedCount: Int
        public let lastVisit: Date
    }

    public struct Tab: Equatable, Sendable {
        public let url: URL
        public let title: String
    }

    public struct Login: Equatable, Sendable {
        public let origin: String
        public let username: String
        /// As the browser stores it: Chromium's "v10" and AES.
        public let encryptedPassword: Data
    }

    /// What was found.
    public struct Contents: Equatable, Sendable {
        public var bookmarksBar: [Bookmark] = []
        /// Everything else, folders kept.
        public var otherBookmarks: [Bookmark] = []
        public var readingList: [Tab] = []
        public var history: [Page] = []
        /// Each window's tabs, in order.
        public var windows: [[Tab]] = []
        public var logins: [Login] = []
        public init() {}
    }

    public struct Parts: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bookmarks = Parts(rawValue: 1)
        public static let history = Parts(rawValue: 2)
        public static let openTabs = Parts(rawValue: 4)
        public static let passwords = Parts(rawValue: 8)
        public static let all: Parts = [.bookmarks, .history, .openTabs, .passwords]
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self { case .unreadable(let what): return "could not read \(what)" }
        }
    }

    // MARK: - Finding browsers

    /// Every profile of every browser on this Mac. `home` is the user's
    /// home folder; tests point it at fixtures.
    public static func sources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Source] {
        let support = home.appendingPathComponent("Library/Application Support")
        var found: [Source] = []
        for browser in Browser.allCases {
            switch browser {
            case .safari:
                let folder = home.appendingPathComponent("Library/Safari")
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                let readable = FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("Bookmarks.plist").path)
                    || FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("History.db").path)
                found.append(Source(browser: .safari, profile: "", directory: folder, needsFullDiskAccess: !readable))
            case .firefox:
                found += firefoxProfiles(in: support.appendingPathComponent("Firefox"))
            default:
                guard let path = browser.supportPath else { continue }
                found += chromiumProfiles(browser, in: support.appendingPathComponent(path))
            }
        }
        return found
    }

    static func chromiumProfiles(_ browser: Browser, in root: URL) -> [Source] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, info) in cache { names[folder] = (info as? [String: Any])?["name"] as? String }
        }
        let folders = entries.filter { name in
            (name == "Default" || name.hasPrefix("Profile ")) &&
                (fm.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("Bookmarks").path)
                 || fm.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("History").path))
        }.sorted { a, b in a == "Default" || (b != "Default" && a.localizedStandardCompare(b) == .orderedAscending) }
        return folders.map { folder in
            // One profile needs no name.
            let name = folders.count == 1 ? "" : names[folder] ?? folder
            return Source(browser: browser, profile: name, directory: root.appendingPathComponent(folder), needsFullDiskAccess: false)
        }
    }

    static func firefoxProfiles(in root: URL) -> [Source] {
        guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        var profiles: [(name: String, path: URL)] = []
        var name = "", path = "", relative = true, inProfile = false
        func flush() {
            if inProfile, !path.isEmpty {
                profiles.append((name, relative ? root.appendingPathComponent(path) : URL(fileURLWithPath: path)))
            }
            name = ""; path = ""; relative = true
        }
        for line in ini.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                flush()
                inProfile = line.hasPrefix("[Profile")
            } else if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals], value = String(line[line.index(after: equals)...])
                if key == "Name" { name = value } else if key == "Path" { path = value } else if key == "IsRelative" { relative = value == "1" }
            }
        }
        flush()
        let usable = profiles.filter { FileManager.default.fileExists(atPath: $0.path.appendingPathComponent("places.sqlite").path) }
        return usable.map { Source(browser: .firefox, profile: usable.count == 1 ? "" : $0.name, directory: $0.path, needsFullDiskAccess: false) }
    }

    // MARK: - Reading

    public static func read(_ source: Source, parts: Parts = .all) throws -> Contents {
        switch source.browser {
        case .firefox: return try readFirefox(source.directory, parts: parts)
        case .safari: return try readSafari(source.directory, parts: parts)
        default: return try readChromium(source.directory, parts: parts)
        }
    }

    // MARK: Chromium

    static func readChromium(_ folder: URL, parts: Parts) throws -> Contents {
        var contents = Contents()
        if parts.contains(.bookmarks), let data = try? Data(contentsOf: folder.appendingPathComponent("Bookmarks")) {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = json["roots"] as? [String: Any] else { throw Failure.unreadable("the bookmarks") }
            func node(_ value: Any?) -> Bookmark? {
                guard let dict = value as? [String: Any] else { return nil }
                let title = dict["name"] as? String ?? ""
                if dict["type"] as? String == "url" {
                    return (dict["url"] as? String).flatMap(URL.init(string:)).map { Bookmark(title: title, url: $0) }
                }
                return Bookmark(title: title, children: (dict["children"] as? [Any] ?? []).compactMap(node))
            }
            contents.bookmarksBar = node(roots["bookmark_bar"])?.children ?? []
            contents.otherBookmarks = ["other", "synced"].compactMap { node(roots[$0]) }.flatMap(\.children)
        }
        if parts.contains(.history), let db = try copyOpen(folder.appendingPathComponent("History")) {
            let rows = try db.query("""
                SELECT url, title, visit_count, typed_count, last_visit_time FROM urls
                WHERE hidden = 0 AND visit_count > 0 ORDER BY last_visit_time DESC LIMIT 20000
                """)
            contents.history = rows.compactMap { row in
                guard let url = row.text("url").flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
                return Page(url: url, title: row.text("title") ?? "", visitCount: Int(row.int("visit_count") ?? 1),
                            typedCount: Int(row.int("typed_count") ?? 0), lastVisit: chromiumDate(row.int("last_visit_time") ?? 0))
            }
        }
        if parts.contains(.openTabs) {
            contents.windows = chromiumOpenTabs(folder)
        }
        if parts.contains(.passwords), let db = try copyOpen(folder.appendingPathComponent("Login Data")) {
            let rows = try db.query("SELECT origin_url, username_value, password_value, blacklisted_by_user FROM logins")
            contents.logins = rows.compactMap { row in
                guard (row.int("blacklisted_by_user") ?? 0) == 0, let origin = row.text("origin_url"), !origin.isEmpty,
                      case .blob(let data)? = row["password_value"], !data.isEmpty else { return nil }
                return Login(origin: origin, username: row.text("username_value") ?? "", encryptedPassword: data)
            }
        }
        return contents
    }

    /// Chromium keeps time as microseconds since 1601.
    static func chromiumDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    /// The tabs of the last session, from the newest session file.
    static func chromiumOpenTabs(_ folder: URL) -> [[Tab]] {
        let fm = FileManager.default
        let sessions = folder.appendingPathComponent("Sessions")
        var candidates = ((try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Session_") }
        candidates.append(folder.appendingPathComponent("Current Session"))
        let newest = candidates.filter { fm.fileExists(atPath: $0.path) }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let newest, let data = try? Data(contentsOf: newest) else { return [] }
        return ChromiumSession.windows(from: data)
    }

    // MARK: Firefox

    static func readFirefox(_ folder: URL, parts: Parts) throws -> Contents {
        var contents = Contents()
        if parts.contains(.bookmarks) || parts.contains(.history), let db = try copyOpen(folder.appendingPathComponent("places.sqlite")) {
            if parts.contains(.bookmarks) {
                let rows = try db.query("""
                    SELECT b.id, b.type, b.parent, b.position, b.title, b.guid, p.url FROM moz_bookmarks b
                    LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
                    """)
                var children: [Int64: [[String: SQLiteDatabase.Value]]] = [:]
                var roots: [String: Int64] = [:]
                for row in rows {
                    children[row.int("parent") ?? 0, default: []].append(row)
                    if let guid = row.text("guid"), let id = row.int("id") { roots[guid] = id }
                }
                func tree(_ parent: Int64) -> [Bookmark] {
                    (children[parent] ?? []).compactMap { row in
                        switch row.int("type") {
                        case 1:
                            guard let url = row.text("url").flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
                            return Bookmark(title: row.text("title") ?? url.absoluteString, url: url)
                        case 2:
                            return Bookmark(title: row.text("title") ?? "", children: tree(row.int("id") ?? -1))
                        default:
                            return nil
                        }
                    }
                }
                contents.bookmarksBar = roots["toolbar_____"].map(tree) ?? []
                contents.otherBookmarks = ["menu________", "unfiled_____", "mobile______"].compactMap { roots[$0] }.flatMap(tree)
            }
            if parts.contains(.history) {
                let rows = try db.query("""
                    SELECT url, title, visit_count, typed, last_visit_date FROM moz_places
                    WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 20000
                    """)
                contents.history = rows.compactMap { row in
                    guard let url = row.text("url").flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
                    return Page(url: url, title: row.text("title") ?? "", visitCount: Int(row.int("visit_count") ?? 1),
                                typedCount: Int(row.int("typed") ?? 0), lastVisit: Date(timeIntervalSince1970: Double(row.int("last_visit_date") ?? 0) / 1_000_000))
                }
            }
        }
        if parts.contains(.openTabs) {
            let candidates = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4"].map { folder.appendingPathComponent($0) }
            if let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               let data = try? Data(contentsOf: file), let json = MozLZ4.decode(data) {
                contents.windows = firefoxWindows(json)
            }
        }
        return contents
    }

    static func firefoxWindows(_ json: Data) -> [[Tab]] {
        guard let session = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let windows = session["windows"] as? [[String: Any]] else { return [] }
        return windows.map { window in
            (window["tabs"] as? [[String: Any]] ?? []).compactMap { tab in
                let entries = tab["entries"] as? [[String: Any]] ?? []
                let index = (tab["index"] as? Int ?? entries.count) - 1
                guard entries.indices.contains(index), let url = (entries[index]["url"] as? String).flatMap(URL.init(string:)),
                      url.scheme?.hasPrefix("http") == true else { return nil }
                return Tab(url: url, title: entries[index]["title"] as? String ?? "")
            }
        }.filter { !$0.isEmpty }
    }

    // MARK: Safari

    static func readSafari(_ folder: URL, parts: Parts) throws -> Contents {
        var contents = Contents()
        if parts.contains(.bookmarks) {
            let file = folder.appendingPathComponent("Bookmarks.plist")
            guard let data = try? Data(contentsOf: file) else { throw Failure.unreadable("Safari’s bookmarks (Full Disk Access)") }
            guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw Failure.unreadable("Safari’s bookmarks")
            }
            func node(_ dict: [String: Any]) -> Bookmark? {
                switch dict["WebBookmarkType"] as? String {
                case "WebBookmarkTypeLeaf":
                    guard let url = (dict["URLString"] as? String).flatMap(URL.init(string:)) else { return nil }
                    let title = (dict["URIDictionary"] as? [String: Any])?["title"] as? String ?? url.absoluteString
                    return Bookmark(title: title, url: url)
                case "WebBookmarkTypeList":
                    return Bookmark(title: dict["Title"] as? String ?? "", children: (dict["Children"] as? [[String: Any]] ?? []).compactMap(node))
                default:
                    return nil
                }
            }
            for top in root["Children"] as? [[String: Any]] ?? [] {
                switch top["Title"] as? String {
                case "BookmarksBar":
                    contents.bookmarksBar = node(top)?.children ?? []
                case "com.apple.ReadingList":
                    contents.readingList = (node(top)?.children ?? []).compactMap { item in item.url.map { Tab(url: $0, title: item.title) } }
                default:
                    if let folder = node(top) {
                        if (top["Title"] as? String) == "BookmarksMenu" { contents.otherBookmarks += folder.children } else { contents.otherBookmarks.append(folder) }
                    }
                }
            }
        }
        if parts.contains(.history) {
            guard let db = try copyOpen(folder.appendingPathComponent("History.db")) else {
                throw Failure.unreadable("Safari’s history (Full Disk Access)")
            }
            let rows = try db.query("""
                SELECT i.url AS url, i.visit_count AS visit_count, MAX(v.visit_time) AS last_visit,
                       (SELECT title FROM history_visits WHERE history_item = i.id AND title IS NOT NULL ORDER BY visit_time DESC LIMIT 1) AS title
                FROM history_items i JOIN history_visits v ON v.history_item = i.id
                GROUP BY i.id ORDER BY last_visit DESC LIMIT 20000
                """)
            contents.history = rows.compactMap { row in
                guard let url = row.text("url").flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
                return Page(url: url, title: row.text("title") ?? "", visitCount: Int(row.int("visit_count") ?? 1), typedCount: 0,
                            lastVisit: Date(timeIntervalSinceReferenceDate: row.double("last_visit") ?? 0))
            }
        }
        return contents
    }

    // MARK: - Files

    /// A copy of the database and its journal, opened: the browser's own may
    /// be locked, and must not be touched. Nil when there is none.
    static func copyOpen(_ file: URL) throws -> SQLiteDatabase? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return nil }
        let folder = fm.temporaryDirectory.appendingPathComponent("SimpleBrowser-import-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        do {
            try fm.copyItem(at: file, to: copy)
        } catch {
            throw Failure.unreadable(file.lastPathComponent)
        }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: file.path + suffix) {
            try? fm.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
        }
        let db = try SQLiteDatabase(path: copy.path)
        db.onClose = { try? fm.removeItem(at: folder) }
        return db
    }
}

/// Firefox's session file: "mozLz40\0", the size, then one LZ4 block.
public enum MozLZ4 {
    static let magic = Data("mozLz40\0".utf8)

    public static func decode(_ data: Data) -> Data? {
        guard data.count > 12, data.prefix(8) == magic else { return nil }
        let size = data[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard size > 0, size < 256 << 20 else { return nil }
        let block = data.dropFirst(12)
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            block.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, block.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? output : nil
    }

    /// The same format, written: for tests.
    public static func encode(_ data: Data) -> Data {
        var output = Data(count: data.count + 1024)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, data.count + 1024,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        var size = Data()
        for shift in stride(from: 0, to: 32, by: 8) { size.append(UInt8((data.count >> shift) & 0xFF)) }
        return magic + size + output.prefix(written)
    }
}

/// Chromium's session file ("SNSS"): a log of commands, each a size, an id
/// and a payload, replayed to find the windows and tabs that were open.
public enum ChromiumSession {
    enum Command: UInt8 {
        case setTabWindow = 0
        case setTabIndexInWindow = 2
        case updateTabNavigation = 6
        case setSelectedNavigationIndex = 7
        case setSelectedTabInIndex = 8
        case tabClosed = 16
        case windowClosed = 17
    }

    public static func windows(from data: Data) -> [[BrowserImport.Tab]] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4] == [0x53, 0x4E, 0x53, 0x53] else { return [] }   // "SNSS"
        struct TabRecord {
            var window: Int32?
            var index = Int32.max
            var navigations: [Int32: BrowserImport.Tab] = [:]
            var selected: Int32?
        }
        var tabs: [Int32: TabRecord] = [:]
        var closedWindows: Set<Int32> = []
        var windowOrder: [Int32] = []
        var offset = 8
        func int32(_ at: Int) -> Int32? {
            guard at + 4 <= bytes.count else { return nil }
            return Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        while offset + 3 <= bytes.count {
            let size = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard size >= 1, offset + 2 + size <= bytes.count else { break }
            let id = bytes[offset + 2]
            let payload = offset + 3
            let end = offset + 2 + size
            offset = end
            guard let command = Command(rawValue: id) else { continue }
            switch command {
            case .setTabWindow:
                guard let window = int32(payload), let tab = int32(payload + 4) else { continue }
                tabs[tab, default: TabRecord()].window = window
                if !windowOrder.contains(window) { windowOrder.append(window) }
            case .setTabIndexInWindow:
                guard let tab = int32(payload), let index = int32(payload + 4) else { continue }
                tabs[tab, default: TabRecord()].index = index
            case .setSelectedNavigationIndex:
                guard let tab = int32(payload), let index = int32(payload + 4) else { continue }
                tabs[tab, default: TabRecord()].selected = index
            case .tabClosed:
                guard let tab = int32(payload) else { continue }
                tabs[tab] = nil
            case .windowClosed:
                guard let window = int32(payload) else { continue }
                closedWindows.insert(window)
            case .setSelectedTabInIndex:
                continue
            case .updateTabNavigation:
                // A pickle: its payload size, then the tab, the index, the
                // address (UTF-8) and the title (UTF-16), each padded to 4.
                var at = payload + 4
                guard let tab = int32(at), let index = int32(at + 4) else { continue }
                at += 8
                guard let urlLength = int32(at), urlLength >= 0, at + 4 + Int(urlLength) <= end else { continue }
                let url = String(decoding: bytes[(at + 4)..<(at + 4 + Int(urlLength))], as: UTF8.self)
                at += 4 + (Int(urlLength) + 3) / 4 * 4
                var title = ""
                if let titleLength = int32(at), titleLength >= 0, at + 4 + Int(titleLength) * 2 <= end {
                    let units = stride(from: at + 4, to: at + 4 + Int(titleLength) * 2, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
                    title = String(decoding: units, as: UTF16.self)
                }
                guard let address = URL(string: url) else { continue }
                tabs[tab, default: TabRecord()].navigations[index] = BrowserImport.Tab(url: address, title: title)
            }
        }
        return windowOrder.filter { !closedWindows.contains($0) }.map { window in
            tabs.values.filter { $0.window == window }.sorted { $0.index < $1.index }.compactMap { record in
                let index = record.selected ?? record.navigations.keys.max() ?? 0
                guard let tab = record.navigations[index] ?? record.navigations[record.navigations.keys.max() ?? 0],
                      tab.url.scheme?.hasPrefix("http") == true else { return nil }
                return tab
            }
        }.filter { !$0.isEmpty }
    }

    /// A session file with these windows: for tests.
    public static func encode(_ windows: [[BrowserImport.Tab]]) -> Data {
        var data = Data("SNSS".utf8) + le(3)
        var nextTab: Int32 = 100
        func command(_ id: Command, _ payload: Data) {
            let size = payload.count + 1
            data.append(UInt8(size & 0xFF)); data.append(UInt8(size >> 8)); data.append(id.rawValue)
            data.append(payload)
        }
        for (w, tabs) in windows.enumerated() {
            let window = Int32(w + 1)
            for (index, tab) in tabs.enumerated() {
                let id = nextTab
                nextTab += 1
                command(.setTabWindow, le(window) + le(id))
                command(.setTabIndexInWindow, le(id) + le(Int32(index)))
                var pickle = le(id) + le(0)
                let url = Data(tab.url.absoluteString.utf8)
                pickle += le(Int32(url.count)) + url + Data(repeating: 0, count: (4 - url.count % 4) % 4)
                let title = tab.title.utf16.reduce(into: Data()) { $0.append(UInt8($1 & 0xFF)); $0.append(UInt8($1 >> 8)) }
                pickle += le(Int32(tab.title.utf16.count)) + title + Data(repeating: 0, count: (4 - title.count % 4) % 4)
                command(.updateTabNavigation, le(Int32(pickle.count)) + pickle)
                command(.setSelectedNavigationIndex, le(id) + le(0))
            }
        }
        // A tab closed in the first window is not brought back.
        command(.setTabWindow, le(1) + le(999))
        command(.tabClosed, le(999) + le(0))
        return data
    }

    private static func le(_ value: Int32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
