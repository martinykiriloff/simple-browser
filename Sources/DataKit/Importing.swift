import Foundation

public extension BookmarkStore {
    /// Adds bookmarks from another browser into `folder`, folders and all.
    /// A page already bookmarked anywhere is left out, and a folder of the
    /// same name is added to rather than made again, so importing twice
    /// adds nothing the second time. Returns how many bookmarks were added.
    @discardableResult
    func importBookmarks(_ items: [BrowserImport.Bookmark], into folder: Int64) throws -> Int {
        var added = 0
        for item in items {
            if let url = item.url {
                guard try bookmark(for: url) == nil else { continue }
                try addBookmark(url: url, title: item.title.isEmpty ? (url.host() ?? url.absoluteString) : item.title, in: folder)
                added += 1
            } else {
                guard item.count > 0 else { continue }
                let existing = try children(of: folder).first { $0.kind == .folder && $0.title == item.title }
                added += try importBookmarks(item.children, into: existing?.id ?? addFolder(item.title, in: folder))
            }
        }
        return added
    }

    /// The folder imported bookmarks go in, in the Bookmarks menu: made once.
    func importFolder(named title: String) throws -> Int64 {
        if let existing = try children(of: menuID).first(where: { $0.kind == .folder && $0.title == title }) { return existing.id }
        return try addFolder(title, in: menuID)
    }

    /// Reading List items from another browser; those already there are left.
    @discardableResult
    func importReadingList(_ items: [BrowserImport.Tab]) throws -> Int {
        var added = 0
        for item in items where try readingItem(for: item.url) == nil {
            try addToReadingList(url: item.url, title: item.title)
            added += 1
        }
        return added
    }
}
