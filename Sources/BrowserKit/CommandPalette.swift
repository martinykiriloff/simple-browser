import Foundation

/// Fuzzy matching: every character of the query, in order, anywhere in the
/// text. "gh" finds "GitHub", "ntw" finds "New Tab Window". Matches at the
/// start of words and runs of characters score higher than scattered ones.
public enum FuzzyMatch {
    /// Nil when the text does not hold the query's characters in order.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = query.filter { !$0.isWhitespace }.map(fold)
        guard !q.isEmpty else { return 0 }
        let original = Array(text)
        let t = original.map(fold)
        guard q.count <= t.count else { return nil }

        // How much a match at each position is worth: the start of the text
        // or of a word (after a space or punctuation, or a camel hump) most.
        let bonus: [Int] = original.indices.map { j in
            if j == 0 { return 16 }
            let before = original[j - 1], here = original[j]
            if !before.isLetter && !before.isNumber { return 12 }
            if before.isLowercase && here.isUppercase { return 10 }
            if before.isLetter != here.isLetter { return 6 }
            return 0
        }
        let none = Int.min / 4
        // best[j]: the best score with the query so far matched and its last
        // character at j.
        var best = [Int](repeating: none, count: t.count)
        for j in t.indices where t[j] == q[0] {
            best[j] = 1 + bonus[j] - min(j, 8)
        }
        for i in 1..<q.count {
            var next = [Int](repeating: none, count: t.count)
            var bestBefore = none   // the best of best[0...j-2]
            for j in t.indices {
                if j >= 2 { bestBefore = max(bestBefore, best[j - 2]) }
                guard t[j] == q[i] else { continue }
                let run = j >= 1 && best[j - 1] > none ? best[j - 1] + 10 : none
                let gap = bestBefore > none ? bestBefore - 3 : none
                let previous = max(run, gap)
                if previous > none { next[j] = previous + 1 + bonus[j] }
            }
            best = next
        }
        guard let top = best.max(), top > none else { return nil }
        let folded = String(t)
        let whole = String(q)
        if folded == whole { return top + 40 }
        if folded.hasPrefix(whole) { return top + 25 }
        return top
    }

    /// One character, lowercased and without accents, so "e" finds "É".
    static func fold(_ character: Character) -> Character {
        let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.first ?? character
    }
}

/// ⌘K: one box for open tabs, commands, bookmarks and history.
public enum CommandPalette {
    public enum Kind: Int, Sendable, CaseIterable {
        case tab, command, savedGroup, bookmark, history

        /// Open tabs come before anything else that matches as well.
        var weight: Int {
            switch self {
            case .tab: return 30
            case .command: return 22
            case .savedGroup: return 18
            case .bookmark: return 10
            case .history: return 0
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public let title: String
        /// An address, or a command's menu ("View"), searched as well.
        public let detail: String
        /// When it was last used, for the order among equals.
        public let lastUsed: Date?
        public init(id: String, kind: Kind, title: String, detail: String = "", lastUsed: Date? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.lastUsed = lastUsed
        }
    }

    /// ⌘1–⌘9 open the first nine results; Return opens the first.
    public static let numberedResults = 9

    /// A key and a number for a tab: typing the letter puts the tab at that
    /// place in the results, so ⌘K, the letter and ⌘number open it. Shown
    /// beside every tab while nothing is typed.
    public struct Hint: Equatable, Sendable {
        public let letter: Character
        public let number: Int
    }

    /// A hint for every open tab. The most recently used choose first, each
    /// the first letter of a word of its title where one is free, then any
    /// letter of its title or site. Nine tabs to a letter, one per ⌘digit.
    public static func hints(_ items: [Item]) -> [String: Hint] {
        var taken: [Character: Int] = [:]
        var hints: [String: Hint] = [:]
        for tab in items.filter({ $0.kind == .tab }).sorted(by: newerFirst) {
            let words = tab.title.split { !$0.isLetter && !$0.isNumber }
            let initials = words.compactMap(\.first).map(FuzzyMatch.fold)
            let letters = (tab.title + host(tab.detail)).map(FuzzyMatch.fold).filter { $0.isLetter || $0.isNumber }
            var seen: Set<Character> = []
            let candidates = (initials + letters).filter { seen.insert($0).inserted }
            guard let letter = candidates.first(where: { taken[$0, default: 0] < numberedResults }) else { continue }
            taken[letter, default: 0] += 1
            hints[tab.id] = Hint(letter: letter, number: taken[letter]!)
        }
        return hints
    }

    /// What matches, best first. With nothing typed: open tabs, most
    /// recently used first. One character puts the tabs with that hint
    /// first, in their numbers' order.
    public static func rank(_ query: String, _ items: [Item], limit: Int = 50) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Array(items.filter { $0.kind == .tab }.sorted(by: newerFirst).prefix(limit))
        }
        if trimmed.count == 1, let key = trimmed.first.map(FuzzyMatch.fold) {
            let hints = hints(items)
            let hinted = items.filter { hints[$0.id]?.letter == key }.sorted { hints[$0.id]!.number < hints[$1.id]!.number }
            let ids = Set(hinted.map(\.id))
            return Array((hinted + ranked(trimmed, items.filter { !ids.contains($0.id) })).prefix(limit))
        }
        return Array(ranked(trimmed, items).prefix(limit))
    }

    private static func ranked(_ trimmed: String, _ items: [Item]) -> [Item] {
        let scored: [(Item, Int)] = items.compactMap { item in
            let title = FuzzyMatch.score(trimmed, in: item.title)
            // The address counts for less than the title.
            let detail = item.detail.isEmpty ? nil : FuzzyMatch.score(trimmed, in: host(item.detail)).map { $0 - 8 }
            guard let score = [title, detail].compactMap({ $0 }).max() else { return nil }
            return (item, score + item.kind.weight)
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.kind != b.0.kind { return a.0.kind.rawValue < b.0.kind.rawValue }
            if newerFirst(a.0, b.0) != newerFirst(b.0, a.0) { return newerFirst(a.0, b.0) }
            return a.0.title.count < b.0.title.count
        }.map(\.0)
    }

    /// The fewest keys, after ⌘K, that open `id`: what is typed, then Return
    /// or ⌘1–⌘9 for one of the first nine results. Nil if no query of
    /// up to `maxLength` characters brings it into the numbered results.
    public static func keystrokes(toReach id: String, in items: [Item], maxLength: Int = 2) -> Int? {
        guard let target = items.first(where: { $0.id == id }) else { return nil }
        let text = (target.title + " " + host(target.detail)).lowercased()
        let alphabet = Array(Set(text.map(FuzzyMatch.fold).filter { $0.isLetter || $0.isNumber })).sorted()
        var queries: [String] = [""]
        var best: Int?
        for length in 0...maxLength {
            if length > 0 {
                queries = queries.flatMap { prefix in alphabet.map { prefix + String($0) } }
            }
            for query in queries {
                let results = rank(query, items, limit: numberedResults)
                guard results.contains(where: { $0.id == id }) else { continue }
                // The characters, then Return or ⌘digit.
                best = min(best ?? length + 1, length + 1)
            }
            if best != nil { return best }
        }
        return best
    }

    private static func newerFirst(_ a: Item, _ b: Item) -> Bool {
        (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
    }

    /// "https://www.example.com/a" is searched as "example.com/a".
    public static func host(_ detail: String) -> String {
        guard let url = URL(string: detail), let host = url.host() else { return detail }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare + (url.path == "/" ? "" : url.path)
    }
}
