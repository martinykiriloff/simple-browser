import AppKit
import BrowserKit

/// Pinned tabs and tab groups, for every window. A tab knows its group and
/// whether it is pinned; the organizer keeps the groups' names, colours and
/// whether they are collapsed, keeps each group's tabs side by side and the
/// pinned ones first, and tells the sidebars and the tab strip when
/// anything changed.
@MainActor
final class TabOrganizer {
    static let didChange = Notification.Name("TabOrganizer.didChange")

    /// Every open tab. Set by the app delegate.
    var controllers: () -> [BrowserWindowController] = { [] }
    /// Opens pages in new tabs beside a tab: for a saved group.
    var openTabs: ((BrowserWindowController, [URL]) -> [BrowserWindowController])?

    private(set) var groups: [TabGroupID: TabGroup] = [:]

    // MARK: - Reading

    /// The tabs of the window `browser` is in, in the tab strip's order.
    func tabs(besides browser: BrowserWindowController) -> [BrowserWindowController] {
        let all = controllers()
        let windows = browser.window?.tabbedWindows ?? [browser.window].compactMap { $0 }
        return windows.compactMap { window in all.first { $0.window === window } }
    }

    func entries(_ tabs: [BrowserWindowController]) -> [TabArrangement.Entry] {
        tabs.map { TabArrangement.Entry(id: $0.tab, groupID: $0.groupID, isPinned: $0.isPinned) }
    }

    func group(_ id: TabGroupID?) -> TabGroup? { id.flatMap { groups[$0] } }

    /// The groups of a window, in the order they appear.
    func groups(besides browser: BrowserWindowController) -> [TabGroup] {
        var seen: Set<TabGroupID> = []
        return tabs(besides: browser).compactMap { tab in
            guard let id = tab.groupID, seen.insert(id).inserted else { return nil }
            return groups[id]
        }
    }

    func tabs(in group: TabGroupID) -> [BrowserWindowController] {
        controllers().filter { $0.groupID == group }
    }

    // MARK: - Pinning

    func setPinned(_ tabs: [BrowserWindowController], _ pinned: Bool) {
        for tab in tabs {
            tab.isPinned = pinned
            if pinned { tab.groupID = nil }
        }
        tabs.first.map(arrange(besides:))
        changed()
    }

    // MARK: - Groups

    /// A new group of these tabs, named and coloured, where the first of them is.
    @discardableResult
    func newGroup(with tabs: [BrowserWindowController], name: String = "") -> TabGroupID? {
        guard let first = tabs.first else { return nil }
        let used = groups(besides: first).map(\.color)
        let group = TabGroup(name: name, color: TabArrangement.nextColor(after: used))
        groups[group.id] = group
        add(tabs, to: group.id)
        return group.id
    }

    /// Moves the tabs into the group, after its last tab.
    func add(_ tabs: [BrowserWindowController], to group: TabGroupID) {
        guard groups[group] != nil else { return }
        for tab in tabs {
            tab.isPinned = false
            tab.groupID = group
            if let strip = tab.window?.tabGroup, let window = tab.window {
                let order = entries(self.tabs(besides: tab))
                let index = TabArrangement.insertionIndex(for: tab.tab, joining: group, in: order)
                if strip.windows.firstIndex(of: window) != index { strip.insertWindow(window, at: min(index, strip.windows.count - 1)) }
            }
        }
        tabs.first.map(arrange(besides:))
        changed()
    }

    func removeFromGroup(_ tabs: [BrowserWindowController]) {
        for tab in tabs {
            guard let group = tab.groupID else { continue }
            // Out of the group, just after it, as Chrome does.
            let others = self.tabs(besides: tab).filter { $0 !== tab }
            tab.groupID = nil
            if let strip = tab.window?.tabGroup, let window = tab.window,
               let last = others.lastIndex(where: { $0.groupID == group }) {
                strip.insertWindow(window, at: last + 1)
            }
        }
        tabs.first.map(arrange(besides:))
        changed()
    }

    /// A tab dragged in the sidebar: before `other` (or last), in `group` (or none).
    func move(_ tab: BrowserWindowController, before other: BrowserWindowController?, group: TabGroupID?) {
        tab.isPinned = false
        tab.groupID = group.flatMap { groups[$0] == nil ? nil : $0 }
        if let strip = tab.window?.tabGroup, let window = tab.window {
            let others = tabs(besides: tab).filter { $0 !== tab }
            let index = other.flatMap { other in others.firstIndex { $0 === other } } ?? others.count
            strip.insertWindow(window, at: index)
        }
        arrange(besides: tab)
        changed()
    }

    func rename(_ group: TabGroupID, to name: String) {
        groups[group]?.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        changed()
    }

    func setColor(_ group: TabGroupID, _ color: GroupColor) {
        groups[group]?.color = color
        changed()
    }

    func setCollapsed(_ group: TabGroupID, _ collapsed: Bool) {
        groups[group]?.isCollapsed = collapsed
        changed()
    }

    /// The tabs stay, in no group.
    func ungroup(_ group: TabGroupID) {
        for tab in tabs(in: group) { tab.groupID = nil }
        groups[group] = nil
        changed()
    }

    /// Closes every tab of the group. A saved group stays saved.
    func closeGroup(_ group: TabGroupID) {
        for tab in tabs(in: group) { tab.window?.performClose(nil) }
    }

    /// Puts pinned tabs first and every group's tabs side by side.
    func arrange(besides browser: BrowserWindowController) {
        guard let strip = browser.window?.tabGroup else { return }
        let tabs = tabs(besides: browser)
        let order = TabArrangement.arranged(entries(tabs))
        for (index, entry) in order.enumerated() {
            guard let window = tabs.first(where: { $0.tab == entry.id })?.window,
                  strip.windows.firstIndex(of: window) != index else { continue }
            strip.insertWindow(window, at: index)
        }
    }

    /// Groups as a restored session had them.
    func restore(_ restored: [TabGroup]) {
        for group in restored { groups[group.id] = group }
        changed()
    }

    // MARK: - Saved groups

    func savedGroups(profile: Profile) -> [SavedTabGroup] {
        BrowserSettings.savedGroups(profile: profile.id.description)
    }

    func isSaved(_ group: TabGroupID, profile: Profile) -> Bool {
        savedGroups(profile: profile).contains { $0.id == group }
    }

    /// Kept after its tabs close, to open again from the sidebar or ⌘K.
    func save(_ group: TabGroupID, profile: Profile) {
        guard let saved = snapshot(group) else { return }
        var all = savedGroups(profile: profile).filter { $0.id != group }
        all.append(saved)
        BrowserSettings.setSavedGroups(all, profile: profile.id.description)
        changed()
    }

    func forgetSaved(_ group: TabGroupID, profile: Profile) {
        BrowserSettings.setSavedGroups(savedGroups(profile: profile).filter { $0.id != group }, profile: profile.id.description)
        changed()
    }

    /// Opens a saved group's pages in new tabs beside `browser`, as the group
    /// again; one already open is shown instead.
    func openSaved(_ saved: SavedTabGroup, besides browser: BrowserWindowController) {
        if let open = tabs(in: saved.id).first {
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let opened = openTabs?(browser, saved.pages.map(\.url)), !opened.isEmpty else { return }
        groups[saved.id] = TabGroup(id: saved.id, name: saved.name, color: saved.color)
        add(opened, to: saved.id)
        opened.first?.window?.makeKeyAndOrderFront(nil)
    }

    private func snapshot(_ group: TabGroupID) -> SavedTabGroup? {
        guard let info = groups[group] else { return nil }
        let pages = tabs(in: group).compactMap { tab in
            tab.currentURL.map { SavedTabGroup.Page(url: $0, title: tab.window?.title ?? "") }
        }
        return SavedTabGroup(id: group, name: info.name, color: info.color, pages: pages)
    }

    // MARK: - Telling everyone

    private var pending = false

    /// Once per turn of the run loop, however many changes: groups nobody
    /// is in are forgotten, saved groups follow their tabs, and every
    /// sidebar and tab reloads.
    func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            let all = self.controllers()
            for id in TabArrangement.emptyGroups(Array(self.groups.keys), in: self.entries(all)) { self.groups[id] = nil }
            self.updateSavedGroups(all)
            for tab in all { tab.syncTabAccessory() }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// A saved group's pages are what its tabs show now.
    private func updateSavedGroups(_ all: [BrowserWindowController]) {
        var profiles: [ProfileID: Profile] = [:]
        for tab in all where !tab.isPrivate { profiles[tab.profile.id] = tab.profile }
        for profile in profiles.values {
            var saved = savedGroups(profile: profile)
            var changedAny = false
            for index in saved.indices {
                guard groups[saved[index].id] != nil, let now = snapshot(saved[index].id), now != saved[index] else { continue }
                saved[index] = now
                changedAny = true
            }
            if changedAny { BrowserSettings.setSavedGroups(saved, profile: profile.id.description) }
        }
    }
}

extension GroupColor {
    var nsColor: NSColor {
        switch self {
        case .graphite: return .systemGray
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

extension TabGroup {
    /// What a group is called when it has no name: its first tab's title, as Safari does.
    func displayName(firstTab: String?) -> String {
        if !name.isEmpty { return name }
        return firstTab.map { $0.count > 24 ? String($0.prefix(23)) + "…" : $0 } ?? "Group"
    }
}
