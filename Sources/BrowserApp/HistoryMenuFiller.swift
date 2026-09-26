import AppKit
import DataKit

/// The recent pages at the bottom of the History menu, filled when it opens.
@MainActor
final class HistoryMenuFiller: NSObject, NSMenuDelegate {
    static let tag = 7_001
    private let recent: () -> [HistoryStore.Visit]

    init(recent: @escaping () -> [HistoryStore.Visit]) {
        self.recent = recent
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.tag { menu.removeItem(item) }
        let visits = recent()
        guard !visits.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = Self.tag
        menu.addItem(separator)
        var seen: Set<URL> = []
        for visit in visits where seen.insert(visit.url).inserted {
            let title = visit.title.isEmpty ? (visit.url.host() ?? visit.url.absoluteString) : visit.title
            let item = NSMenuItem(title: title.count > 60 ? String(title.prefix(59)) + "…" : title,
                                  action: #selector(AppDelegate.openHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = visit.url
            item.toolTip = visit.url.absoluteString
            item.tag = Self.tag
            menu.addItem(item)
        }
    }
}
