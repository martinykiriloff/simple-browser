import AppKit
import WebKit
import DataKit
import BrowserKit

/// History → Show All History (⌘Y): every visit of one profile, grouped by
/// day, searchable, with Delete and Clear History.
@MainActor
final class HistoryWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: HistoryStore
    private let profile: Profile
    /// Opens a page: in the current tab, or a new one with ⌘.
    var open: ((URL, _ newTab: Bool) -> Void)?
    /// Clears history and the website data of the same period.
    var clear: ((Date) async -> Void)?

    let searchField = NSSearchField()
    let outline = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private struct Day { let title: String; let visits: [HistoryStore.Visit] }
    private final class DayItem: NSObject {
        let title: String
        let visits: [VisitItem]
        init(title: String, visits: [VisitItem]) { self.title = title; self.visits = visits }
    }
    private final class VisitItem: NSObject {
        let visit: HistoryStore.Visit
        init(_ visit: HistoryStore.Visit) { self.visit = visit }
    }
    private(set) var days: [NSObject] = []

    init(store: HistoryStore, profile: Profile) {
        self.store = store
        self.profile = profile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        QuietMode.apply(to: window)
        window.title = "History — \(profile.name)"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContent()
        if !window.setFrameUsingName("HistoryWindow") { window.center() }
        window.setFrameAutosaveName("HistoryWindow")
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildContent() -> NSView {
        searchField.placeholderString = "Search History"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search History")

        for (identifier, title, width) in [("title", "Title", 380.0), ("address", "Address", 240.0), ("time", "Time", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowHeight = 22
        outline.target = self
        outline.doubleAction = #selector(openSelected(_:))
        outline.setAccessibilityLabel("History")
        outline.menu = contextMenu()
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let clearButton = NSButton(title: "Clear History…", target: self, action: #selector(clearHistory(_:)))
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(delete(_:)))
        emptyLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [searchField, spacer, deleteButton, clearButton])
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        let stack = NSStackView(views: [bar, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        scroll.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(openSelected(_:))), ("Open in New Tab", #selector(openSelectedInNewTab(_:))),
                                ("Copy Link", #selector(copyLinks(_:))), ("Delete", #selector(delete(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: - Data

    func reload() {
        let visits = (try? store.visits(matching: searchField.stringValue, limit: 3_000)) ?? []
        let calendar = Calendar.current
        var grouped: [(Date, [HistoryStore.Visit])] = []
        for visit in visits {
            let day = calendar.startOfDay(for: visit.visitedAt)
            if grouped.last?.0 == day { grouped[grouped.count - 1].1.append(visit) } else { grouped.append((day, [visit])) }
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        days = grouped.map { day, visits in
            let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : formatter.string(from: day)
            return DayItem(title: title, visits: visits.map(VisitItem.init))
        }
        outline.reloadData()
        for day in days { outline.expandItem(day) }
        emptyLabel.stringValue = searchField.stringValue.isEmpty ? "No history yet" : "Nothing matches “\(searchField.stringValue)”"
        emptyLabel.isHidden = !days.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let day = item as? DayItem { return day.visits.count }
        return item == nil ? days.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let day = item as? DayItem { return day.visits[index] }
        return days[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is DayItem }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is DayItem }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        if let day = item as? DayItem {
            label.stringValue = day.title
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return tableColumn == nil || tableColumn === outlineView.tableColumns.first ? label : nil
        }
        guard let visit = (item as? VisitItem)?.visit else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "title":
            label.stringValue = visit.title.isEmpty ? (visit.url.host() ?? visit.url.absoluteString) : visit.title
            label.toolTip = visit.url.absoluteString
        case "address":
            label.stringValue = visit.url.absoluteString
            label.textColor = .secondaryLabelColor
        default:
            label.stringValue = visit.visitedAt.formatted(date: .omitted, time: .shortened)
            label.textColor = .secondaryLabelColor
        }
        return label
    }

    private var selectedVisits: [HistoryStore.Visit] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? VisitItem)?.visit }
    }

    // MARK: - Actions

    @objc func openSelected(_ sender: Any?) {
        let newTab = NSEvent.modifierFlags.contains(.command) || selectedVisits.count > 1
        for visit in selectedVisits { open?(visit.url, newTab) }
    }

    @objc func openSelectedInNewTab(_ sender: Any?) {
        for visit in selectedVisits { open?(visit.url, true) }
    }

    @objc func copyLinks(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedVisits.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
    }

    @objc func delete(_ sender: Any?) {
        for visit in selectedVisits { try? store.deleteVisit(visit.id) }
        reload()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { delete(nil) } else { super.keyDown(with: event) }
    }

    @objc func clearHistory(_ sender: Any?) {
        guard let window else { return }
        ClearHistorySheet.ask(in: window) { [weak self] since in
            guard let self else { return }
            Task { @MainActor in
                await self.clear?(since)
                self.reload()
            }
        }
    }
}

/// "Clear History…": which period, as Safari asks it.
@MainActor
enum ClearHistorySheet {
    enum Range: Int, CaseIterable {
        case lastHour, today, todayAndYesterday, all
        var title: String {
            switch self {
            case .lastHour: return "the last hour"
            case .today: return "today"
            case .todayAndYesterday: return "today and yesterday"
            case .all: return "all history"
            }
        }
        func start(now: Date = .now) -> Date {
            let calendar = Calendar.current
            switch self {
            case .lastHour: return now.addingTimeInterval(-3600)
            case .today: return calendar.startOfDay(for: now)
            case .todayAndYesterday: return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
            case .all: return .distantPast
            }
        }
    }

    static func ask(in window: NSWindow, completion: @escaping (Date) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText = "Clearing history also removes cookies and other website data from the same period, for this profile."
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        popUp.addItems(withTitles: Range.allCases.map { "Clear " + $0.title })
        popUp.selectItem(at: Range.lastHour.rawValue)
        alert.accessoryView = popUp
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, let range = Range(rawValue: popUp.indexOfSelectedItem) else { return }
            completion(range.start())
        }
    }
}
