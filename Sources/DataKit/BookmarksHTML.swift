import Foundation

/// The bookmarks file every browser can export and read: Netscape's HTML.
/// A folder is `<DT><H3>name</H3>` followed by a `<DL>…</DL>` holding what
/// is in it; a bookmark is `<DT><A HREF="…">name</A>`. Chrome, Edge, Brave,
/// Opera, Vivaldi, Arc, Firefox, Safari, DuckDuckGo and Orion all write it,
/// each a little differently — Safari omits some of the `<DL>`s, Firefox
/// marks its toolbar — so the parser is forgiving: it follows the `<DL>`
/// nesting where there is any, and otherwise keeps every bookmark it finds.
///
/// This is how bookmarks come in from a browser Keel cannot read on disk, or
/// one on another Mac: the person exports the file and imports it here.
public enum BookmarksHTML {

    /// The bookmarks in `data`, split into the toolbar (the folder a browser
    /// marks as its bar, or names like one) and everything else. Nil when
    /// `data` is not a bookmarks file.
    public static func parse(_ data: Data) -> BrowserImport.Contents? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let chars = Array(text)
        let lowered = text.lowercased()
        guard lowered.contains("netscape-bookmark") || (lowered.contains("<dl") && lowered.contains("<a ")) else { return nil }

        // A folder while it is being filled: a reference type, so the stack
        // and the tree share the same nodes.
        final class Folder {
            var title: String
            var isToolbar: Bool
            var children: [Either] = []
            init(title: String = "", isToolbar: Bool = false) { self.title = title; self.isToolbar = isToolbar }
        }
        enum Either { case folder(Folder); case bookmark(BrowserImport.Bookmark) }

        let root = Folder()
        var stack = [root]
        // The folder whose `<DL>` is expected next.
        var pending: Folder?
        var index = 0
        let count = chars.count

        while index < count {
            guard chars[index] == "<" else { index += 1; continue }
            // A comment: skip to its end.
            if match(chars, at: index, "<!--") {
                index = find(chars, "-->", from: index + 4).map { $0 + 3 } ?? count
                continue
            }
            guard let gt = indexOf(chars, ">", from: index) else { break }
            let tag = String(chars[(index + 1)..<gt])
            let name = tagName(tag)
            switch name {
            case "dl":
                stack.append(pending ?? stack.last!)
                pending = nil
                index = gt + 1
            case "/dl":
                if stack.count > 1 { stack.removeLast() }
                pending = nil
                index = gt + 1
            case "h3":
                let (inner, after) = content(chars, openEnd: gt, tag: "h3", upTo: count)
                let folder = Folder(title: unescape(inner), isToolbar: attribute("personal_toolbar_folder", in: tag) == "true")
                stack.last!.children.append(.folder(folder))
                pending = folder
                index = after
            case "a":
                let (inner, after) = content(chars, openEnd: gt, tag: "a", upTo: count)
                if let href = attribute("href", in: tag), let url = URL(string: unescape(href)),
                   url.scheme?.hasPrefix("http") == true || url.scheme == "ftp" {
                    let title = unescape(inner)
                    stack.last!.children.append(.bookmark(BrowserImport.Bookmark(title: title.isEmpty ? (url.host() ?? url.absoluteString) : title, url: url)))
                }
                index = after
            default:
                index = gt + 1
            }
        }

        func tree(_ folder: Folder) -> [BrowserImport.Bookmark] {
            folder.children.map { child in
                switch child {
                case .bookmark(let bookmark): return bookmark
                case .folder(let sub): return BrowserImport.Bookmark(title: sub.title, children: tree(sub))
                }
            }
        }

        // The toolbar: the folder marked as the bar, or named like one; its
        // bookmarks become the favorites bar, the rest go to a folder.
        let top = root.children
        func looksLikeBar(_ folder: Folder) -> Bool {
            folder.isToolbar || ["bookmarks bar", "bookmarks toolbar", "favorites bar", "favourites bar", "bookmark bar", "favorites", "favourites"].contains(folder.title.lowercased())
        }
        var bar: Folder?
        for case .folder(let folder) in top where looksLikeBar(folder) { bar = folder; break }

        var contents = BrowserImport.Contents()
        contents.bookmarksBar = bar.map(tree) ?? []
        contents.otherBookmarks = top.compactMap { child -> BrowserImport.Bookmark? in
            switch child {
            case .folder(let folder): return folder === bar ? nil : BrowserImport.Bookmark(title: folder.title, children: tree(folder))
            case .bookmark(let bookmark): return bookmark
            }
        }
        guard contents.bookmarksBar.contains(where: { $0.count > 0 }) || contents.otherBookmarks.contains(where: { $0.count > 0 }) else { return nil }
        return contents
    }

    // MARK: - Scanning

    /// The tag's name, lowercased: the letters (and a leading `/`) after `<`.
    private static func tagName(_ tag: String) -> String {
        var name = ""
        for character in tag {
            if character == "/" && name.isEmpty { name.append(character) }
            else if character.isLetter || character.isNumber { name.append(character) }
            else { break }
        }
        return name.lowercased()
    }

    /// An attribute's value, case-insensitive on the name. Handles quoted
    /// and unquoted values.
    private static func attribute(_ name: String, in tag: String) -> String? {
        let lower = tag.lowercased()
        var search = lower.startIndex
        while let range = lower.range(of: name, range: search..<lower.endIndex) {
            search = range.upperBound
            var index = range.upperBound
            while index < lower.endIndex, lower[index] == " " { index = lower.index(after: index) }
            guard index < lower.endIndex, lower[index] == "=" else { continue }
            index = lower.index(after: index)
            while index < lower.endIndex, lower[index] == " " { index = lower.index(after: index) }
            guard index < lower.endIndex else { return "" }
            // Map back to the original string to keep the value's case.
            let offset = lower.distance(from: lower.startIndex, to: index)
            let start = tag.index(tag.startIndex, offsetBy: offset)
            if tag[start] == "\"" || tag[start] == "'" {
                let quote = tag[start]
                let valueStart = tag.index(after: start)
                guard let end = tag[valueStart...].firstIndex(of: quote) else { return String(tag[valueStart...]) }
                return String(tag[valueStart..<end])
            } else {
                let end = tag[start...].firstIndex { $0 == " " || $0 == ">" } ?? tag.endIndex
                return String(tag[start..<end])
            }
        }
        return nil
    }

    /// The text from just after an open tag to its matching close tag, and
    /// the index just past that close tag. If there is no close tag, the
    /// text is empty and scanning carries on after the open tag.
    private static func content(_ chars: [Character], openEnd gt: Int, tag: String, upTo count: Int) -> (String, Int) {
        guard let close = find(chars, "</" + tag, from: gt + 1) else { return ("", gt + 1) }
        let text = String(chars[(gt + 1)..<close])
        let after = indexOf(chars, ">", from: close).map { $0 + 1 } ?? count
        return (text, after)
    }

    private static func match(_ chars: [Character], at index: Int, _ needle: String) -> Bool {
        let needleChars = Array(needle)
        guard index + needleChars.count <= chars.count else { return false }
        for offset in needleChars.indices where Character(chars[index + offset].lowercased()) != needleChars[offset] { return false }
        return true
    }

    private static func indexOf(_ chars: [Character], _ character: Character, from: Int) -> Int? {
        var index = from
        while index < chars.count { if chars[index] == character { return index }; index += 1 }
        return nil
    }

    /// The first index of `needle` (compared case-insensitively) at or after `from`.
    private static func find(_ chars: [Character], _ needle: String, from: Int) -> Int? {
        var index = from
        while index < chars.count { if match(chars, at: index, needle.lowercased()) { return index }; index += 1 }
        return nil
    }

    /// HTML entities a bookmarks file uses: the named five and numeric ones.
    private static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<amp]
            rest = rest[amp...]
            guard let semicolon = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semicolon) <= 10 else {
                result.append("&"); rest = rest.dropFirst(); continue
            }
            let entity = rest[rest.index(after: rest.startIndex)..<semicolon]
            switch entity {
            case "amp": result.append("&")
            case "lt": result.append("<")
            case "gt": result.append(">")
            case "quot": result.append("\"")
            case "apos", "#39": result.append("'")
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let value = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                } else if entity.hasPrefix("#"), let value = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                } else {
                    result.append("&"); result.append(contentsOf: entity); result.append(";")
                }
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
