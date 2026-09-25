import AppKit
import WebKit
import BrowserKit
import InspectKit

/// The native recorder window: one timeline of everything observed for a
/// tab -- console, network, DOM, performance, navigation -- with a filter,
/// search, a detail pane, export, and a console input that evaluates in the
/// page.
///
/// It renders natively, so inspecting a janky page does not jank the
/// inspector, and it shows the recording that was already running before it
/// was opened.
@MainActor
final class InspectorPanelController: NSWindowController,
                                      NSWindowDelegate,
                                      NSTableViewDataSource,
                                      NSTableViewDelegate,
                                      NSSearchFieldDelegate {

    private let recorder: InspectorRecorder
    private let tab: TabID
    private weak var webView: WKWebView?

    private var observation: UUID?
    private var visible: [RecordedEvent] = []
    private var filterKind: InspectorEvent.Kind?
    private var searchText = ""
    private var reloadScheduled = false
    private var followTail = true

    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let splitView = NSSplitView()
    private let detailView = NSTextView()
    private let filterControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let consoleInput = NSTextField()
    private var history: [String] = []
    private var historyIndex = 0

    private static let filters: [(title: String, kind: InspectorEvent.Kind?)] = [
        ("All", nil), ("Console", .console), ("Network", .network),
        ("Performance", .performance), ("DOM", .dom), ("Navigation", .navigation),
    ]

    init(recorder: InspectorRecorder, tab: TabID, webView: WKWebView) {
        self.recorder = recorder
        self.tab = tab
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Recorder"
        window.minSize = NSSize(width: 560, height: 320)
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = buildContent()

        // First launch: a sensible place and split. Afterwards: wherever the
        // user last left it.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.layoutIfNeeded()
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.splitAutosaveName)") == nil {
            splitView.setPosition(splitView.bounds.height * 0.62, ofDividerAt: 0)
        }

        rebuildVisible()
        observation = recorder.observe { [weak self] change in
            self?.handle(change)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private static let frameAutosaveName = "InspectorPanel"
    private static let splitAutosaveName = "InspectorPanelSplit"

    func update(title: String) {
        window?.title = "Recorder — \(title)"
    }

    func windowWillClose(_ notification: Notification) {
        if let token = observation {
            recorder.removeObserver(token)
            observation = nil
        }
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let root = NSView()

        // Top bar: filter · search · clear · export
        for (index, filter) in Self.filters.enumerated() {
            filterControl.segmentCount = index + 1
            filterControl.setLabel(filter.title, forSegment: index)
        }
        filterControl.selectedSegment = 0
        filterControl.segmentStyle = .rounded
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))

        searchField.placeholderString = "Filter by text or URL"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearRecording(_:)))
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportRecording(_:)))
        let webInspectorButton = NSButton(title: "Web Inspector", target: self, action: #selector(openWebInspector(_:)))
        webInspectorButton.toolTip = "Open WebKit's Web Inspector for this page (⌥⌘I)"

        let topBar = NSStackView(views: [filterControl, searchField, webInspectorButton, clearButton, exportButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        // Table
        let columns: [(String, String, CGFloat)] = [
            ("time", "Time", 90), ("source", "Source", 50), ("kind", "Kind", 80), ("summary", "Summary", 600),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 40
            if identifier == "summary" { column.resizingMask = .autoresizingMask }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20
        tableView.style = .plain
        tableView.headerView = NSTableHeaderView()
        tableView.target = self
        tableView.doubleAction = #selector(copySelectedRow(_:))

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: tableScroll.contentView
        )

        // Detail
        detailView.isEditable = false
        detailView.isRichText = false
        detailView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detailView.textContainerInset = NSSize(width: 8, height: 8)
        detailView.autoresizingMask = [.width]
        detailView.isHorizontallyResizable = false
        detailView.textContainer?.widthTracksTextView = true
        detailView.string = "Select an event to see its details."
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailView
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true

        let split = splitView
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(detailScroll)
        // The table keeps the space when the window grows; the detail pane holds its size.
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        split.autosaveName = Self.splitAutosaveName
        split.setContentHuggingPriority(.init(1), for: .vertical)

        // Console input
        let prompt = NSTextField(labelWithString: "›")
        prompt.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        prompt.textColor = .secondaryLabelColor
        consoleInput.placeholderString = "Evaluate JavaScript in the page — ↩ to run, ↑↓ for history"
        consoleInput.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        consoleInput.bezelStyle = .roundedBezel
        consoleInput.target = self
        consoleInput.action = #selector(evaluateConsoleInput(_:))
        consoleInput.delegate = self
        (consoleInput.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottomBar = NSStackView(views: [prompt, consoleInput, statusLabel])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        consoleInput.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [topBar, split, bottomBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.distribution = .fill
        topBar.setContentHuggingPriority(.required, for: .vertical)
        bottomBar.setContentHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        return root
    }

    // MARK: - Data

    private func matches(_ recorded: RecordedEvent) -> Bool {
        guard recorded.tab == tab else { return false }
        if let kind = filterKind, recorded.event.kind != kind { return false }
        if searchText.isEmpty { return true }
        return InspectorEventFormatter.summary(recorded.event)
            .localizedCaseInsensitiveContains(searchText)
    }

    private func rebuildVisible() {
        visible = recorder.events.filter(matches)
        tableView.reloadData()
        updateStatus()
        if followTail { scrollToTail() }
    }

    private func handle(_ change: InspectorRecorder.Change) {
        switch change {
        case .cleared:
            visible.removeAll()
            tableView.reloadData()
            detailView.string = ""
            updateStatus()
        case .appended(let recorded):
            guard matches(recorded) else { updateStatus(); return }
            visible.append(recorded)
            scheduleReload()
        }
    }

    /// Coalesces a burst of events into one table reload per run-loop turn.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            let selected = self.tableView.selectedRow
            self.tableView.reloadData()
            if selected >= 0 && selected < self.visible.count {
                self.tableView.selectRowIndexes([selected], byExtendingSelection: false)
            }
            self.updateStatus()
            if self.followTail { self.scrollToTail() }
        }
    }

    private func scrollToTail() {
        guard !visible.isEmpty else { return }
        tableView.scrollRowToVisible(visible.count - 1)
    }

    private func updateStatus() {
        var byKind: [InspectorEvent.Kind: Int] = [:]
        var total = 0
        for event in recorder.events where event.tab == tab {
            total += 1
            byKind[event.event.kind, default: 0] += 1
        }
        let parts = InspectorEvent.Kind.allCases.compactMap { kind in
            byKind[kind].map { "\($0) \(kind.rawValue)" }
        }
        statusLabel.stringValue = "\(total) recorded · " + parts.joined(separator: " · ")
    }

    @objc private func scrolled(_ notification: Notification) {
        let clip = tableScroll.contentView
        let bottom = clip.bounds.maxY
        let height = tableView.bounds.height
        followTail = height - bottom < tableView.rowHeight * 2
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < visible.count else { return nil }
        let recorded = visible[row]
        let identifier = column.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.cell?.truncatesLastVisibleLine = true
            return field
        }()

        var color = NSColor.labelColor
        switch identifier.rawValue {
        case "time":
            cell.stringValue = InspectorEventFormatter.timestamp(recorded.recordedAt)
            color = .secondaryLabelColor
        case "source":
            let source = InspectorEventFormatter.source(of: recorded.event) ?? Self.impliedSource(recorded.event)
            cell.stringValue = InspectorEventFormatter.shortSourceLabel(source)
            color = source.isTamperable ? .systemOrange : .secondaryLabelColor
        case "kind":
            cell.stringValue = Self.kindLabel(recorded.event)
            color = .secondaryLabelColor
        default:
            cell.stringValue = InspectorEventFormatter.summary(recorded.event)
            color = Self.rowColor(recorded.event)
        }
        cell.textColor = color
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < visible.count else { return }
        detailView.string = InspectorEventFormatter.detail(visible[row])
        detailView.scroll(.zero)
    }

    private static func impliedSource(_ event: InspectorEvent) -> EventSource {
        switch event {
        case .console(let e):    return e.isUncaught ? .agent : .pageWorld
        case .network(let e):    return e.source
        case .dom, .performance: return .agent
        case .navigation(let e): return e.phase == .agentReady ? .agent : .navigationDelegate
        }
    }

    private static func kindLabel(_ event: InspectorEvent) -> String {
        switch event {
        case .console(let e):     return e.level.rawValue
        case .network(let e):     return e.initiator ?? "network"
        case .dom:                return "dom"
        case .performance(let e): return e.entryType
        case .navigation:         return "navigation"
        }
    }

    private static func rowColor(_ event: InspectorEvent) -> NSColor {
        switch event {
        case .console(let e):
            switch e.level {
            case .error: return .systemRed
            case .warn:  return .systemOrange
            case .debug: return .secondaryLabelColor
            default:     return .labelColor
            }
        case .network(let e):
            return e.isFailure ? .systemRed : .labelColor
        case .navigation(let e):
            return e.phase == .failed ? .systemRed : .labelColor
        case .performance(let e):
            return e.entryType == "longtask" || e.entryType == "layout-shift" ? .systemOrange : .labelColor
        case .dom:
            return .secondaryLabelColor
        }
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        filterKind = Self.filters[sender.selectedSegment].kind
        followTail = true
        rebuildVisible()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        searchText = searchField.stringValue
        followTail = true
        rebuildVisible()
    }

    @objc private func clearRecording(_ sender: Any?) {
        recorder.clear()
    }

    @objc private func openWebInspector(_ sender: Any?) {
        guard let webView else { return }
        if !WebInspectorSPI.show(webView) {
            NSSound.beep()
        }
    }

    @objc private func copySelectedRow(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < visible.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(InspectorEventFormatter.detail(visible[row]), forType: .string)
    }

    @objc private func exportRecording(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let host = webView?.url?.host() ?? "recording"
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(host)-\(stamp).json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.recorder.exportJSON().write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func evaluateConsoleInput(_ sender: Any?) {
        let source = consoleInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        consoleInput.stringValue = ""
        history.append(source)
        historyIndex = history.count

        recorder.record(.console(ConsoleEntry(level: .info, message: "› " + source)), tab: tab)
        guard let webView else {
            recorder.record(.console(ConsoleEntry(level: .error, message: "No page to evaluate in.")), tab: tab)
            return
        }
        // Evaluate in the page world so `console.log` inside the expression is
        // captured by the page hooks, and page globals are in scope.
        webView.evaluateJavaScript(Self.wrapForEvaluation(source), in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.recorder.record(.console(ConsoleEntry(level: .info, message: "‹ " + Self.describe(value))), tab: self.tab)
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    ?? error.localizedDescription
                self.recorder.record(.console(ConsoleEntry(level: .error, message: "‹ " + message)), tab: self.tab)
            }
        }
    }

    /// Returns a string for anything, so DOM nodes and functions come back
    /// rather than failing serialization on the bridge.
    private static func wrapForEvaluation(_ source: String) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: [source]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var __r;
          try { __r = (0, eval)(\(literal)); } catch (e) { throw e; }
          if (__r === undefined) return "undefined";
          if (__r === null) return "null";
          if (typeof __r === "string") return JSON.stringify(__r);
          if (typeof __r === "function") return String(__r);
          if (typeof __r === "symbol" || typeof __r === "bigint") return String(__r);
          if (typeof Node !== "undefined" && __r instanceof Node) return __r.outerHTML || __r.nodeName;
          if (__r instanceof Error) return __r.stack || String(__r);
          if (__r instanceof Promise) return "Promise";
          try {
            var seen = new WeakSet();
            return JSON.stringify(__r, function (k, v) {
              if (typeof v === "object" && v !== null) { if (seen.has(v)) return "[Circular]"; seen.add(v); }
              if (typeof v === "function") return "ƒ " + (v.name || "anonymous") + "()";
              if (typeof v === "undefined") return "undefined";
              return v;
            }, 2);
          } catch (_) { return String(__r); }
        })()
        """
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil:                return "undefined"
        case let s as String:    return s
        case let n as NSNumber:  return n.stringValue
        default:                 return String(describing: value!)
        }
    }

    // History navigation in the console input.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === consoleInput, !history.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            historyIndex = max(0, historyIndex - 1)
            consoleInput.stringValue = history[historyIndex]
            textView.selectedRange = NSRange(location: consoleInput.stringValue.utf16.count, length: 0)
            return true
        case #selector(NSResponder.moveDown(_:)):
            historyIndex = min(history.count, historyIndex + 1)
            consoleInput.stringValue = historyIndex == history.count ? "" : history[historyIndex]
            textView.selectedRange = NSRange(location: consoleInput.stringValue.utf16.count, length: 0)
            return true
        default:
            return false
        }
    }
}
