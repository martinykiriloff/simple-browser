import Foundation

/// Where tabs go when they are pinned or grouped. The tab strip and the
/// sidebar show the same order: pinned tabs first, then every group's tabs
/// side by side, where the group's first tab was.
public enum TabArrangement {
    public struct Entry: Equatable, Sendable {
        public let id: TabID
        public var groupID: TabGroupID?
        public var isPinned: Bool
        public init(id: TabID, groupID: TabGroupID? = nil, isPinned: Bool = false) {
            self.id = id
            self.groupID = groupID
            self.isPinned = isPinned
        }
    }

    /// The order the tabs should be in. Stable: tabs already in order stay
    /// where they are. A pinned tab is in no group.
    public static func arranged(_ entries: [Entry]) -> [Entry] {
        let pinned = entries.filter(\.isPinned)
        var rest: [Entry] = []
        var placed: Set<TabGroupID> = []
        for entry in entries where !entry.isPinned {
            guard let group = entry.groupID else { rest.append(entry); continue }
            guard !placed.contains(group) else { continue }
            placed.insert(group)
            rest += entries.filter { !$0.isPinned && $0.groupID == group }
        }
        return pinned + rest
    }

    /// Where a tab moved into `group` goes: after the group's last tab, or
    /// where it is now when the group has no other tabs. An index into
    /// `entries` after the tab has been taken out of it.
    public static func insertionIndex(for id: TabID, joining group: TabGroupID, in entries: [Entry]) -> Int {
        let others = entries.filter { $0.id != id }
        if let last = others.lastIndex(where: { $0.groupID == group && !$0.isPinned }) { return last + 1 }
        let pinnedCount = others.filter(\.isPinned).count
        return max(pinnedCount, min(entries.firstIndex { $0.id == id } ?? others.count, others.count))
    }

    /// One line of the sidebar's list of tabs.
    public enum Row: Equatable, Sendable {
        case group(TabGroupID)
        case tab(TabID, inGroup: Bool)
    }

    /// Pinned tabs, shown as icons at the top, and the rows under them.
    /// A collapsed group shows its header only, unless the tab in front is
    /// in it: that one stays in sight.
    public static func sidebar(_ entries: [Entry], groups: [TabGroupID: TabGroup], selected: TabID? = nil) -> (pinned: [TabID], rows: [Row]) {
        let ordered = arranged(entries)
        var rows: [Row] = []
        var shown: Set<TabGroupID> = []
        for entry in ordered where !entry.isPinned {
            guard let groupID = entry.groupID, let group = groups[groupID] else {
                rows.append(.tab(entry.id, inGroup: false))
                continue
            }
            if !shown.contains(groupID) {
                shown.insert(groupID)
                rows.append(.group(groupID))
            }
            if !group.isCollapsed || entry.id == selected { rows.append(.tab(entry.id, inGroup: true)) }
        }
        return (ordered.filter(\.isPinned).map(\.id), rows)
    }

    /// Groups nobody is in any more, to forget.
    public static func emptyGroups(_ groups: some Sequence<TabGroupID>, in entries: [Entry]) -> [TabGroupID] {
        let used = Set(entries.compactMap { $0.isPinned ? nil : $0.groupID })
        return groups.filter { !used.contains($0) }
    }

    /// A colour no group of the window has yet, as Chrome and Safari pick.
    public static func nextColor(after used: [GroupColor]) -> GroupColor {
        let order: [GroupColor] = [.blue, .red, .yellow, .green, .pink, .purple, .teal, .orange, .graphite]
        return order.first { !used.contains($0) } ?? order[used.count % order.count]
    }
}
