import AppKit
import AgentKit
import UniformTypeIdentifiers

/// A session's log, live or from its file, and the ways out of the app:
/// JSON, a replay, Markdown for an AI.
@MainActor
enum AgentLogs {
    /// The `.jsonl` file of a session, if it was written.
    static func file(sessionID: String, trust: AgentTrust) -> URL? {
        if let record = trust.history.first(where: { $0.id == sessionID }) {
            let url = trust.logsDirectory.appendingPathComponent(record.logFile)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: trust.logsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasSuffix("-\(sessionID).jsonl") }
    }

    /// Entries of a session: the live log while it runs, else its file.
    static func entries(sessionID: String, trust: AgentTrust) -> [AuditEntry] {
        if let live = trust.live(sessionID) { return live.log.entries }
        guard let url = file(sessionID: sessionID, trust: trust), let data = try? Data(contentsOf: url) else { return [] }
        return AuditLog.parseLines(data)
    }

    /// The replay `keel replay` sends again (AR-10).
    static func replay(_ entries: [AuditEntry]) -> JSONValue {
        AuditLog(entries: entries).replay(readOnlyTools: BrowserTools.readOnlyNames)
    }

    /// Asks where, then writes.
    static func save(_ data: Data, name: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if let window {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { if response == .OK, let url = panel.url { write(data, to: url) } }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(data, to: url)
        }
    }

    private static func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// "ref=e7 text=alex@example.com", short, for one line.
    static func shortArguments(_ arguments: JSONValue, limit: Int = 96) -> String {
        func clip(_ text: String, _ count: Int) -> String { text.count > count ? String(text.prefix(count - 1)) + "…" : text }
        guard let object = arguments.object else {
            return clip(String(decoding: arguments.encoded(), as: UTF8.self), limit)
        }
        let parts = object.keys.sorted().filter { $0 != "tabId" }.map { key -> String in
            let value = object[key]!
            let text = value.string ?? String(decoding: value.encoded(), as: UTF8.self)
            return "\(key)=\(clip(text, 48))"
        }
        return clip(parts.joined(separator: " "), limit)
    }

    /// "+02:14" from the start of the session.
    static func offset(_ time: Date, from start: Date) -> String {
        let seconds = max(0, Int(time.timeIntervalSince(start)))
        if seconds >= 3600 { return String(format: "+%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "+%02d:%02d", seconds / 60, seconds % 60)
    }

    static func duration(_ milliseconds: Int) -> String {
        milliseconds >= 1000 ? String(format: "%.1f s", Double(milliseconds) / 1000) : "\(milliseconds) ms"
    }

    static func color(_ outcome: AuditEntry.Outcome) -> NSColor {
        switch outcome {
        case .ok, .approved: return Keel.green
        case .waiting: return Keel.amber
        case .denied, .blocked, .error: return Keel.dangerText
        }
    }

    static func outcomeText(_ outcome: AuditEntry.Outcome) -> String {
        switch outcome {
        case .ok: return "Done"
        case .approved: return "Approved by you"
        case .waiting: return "Waiting"
        case .denied: return "Denied"
        case .blocked: return "Blocked"
        case .error: return "Failed"
        }
    }

    /// The timeline as Markdown, to paste into a chat with an AI.
    static func markdown(_ session: AgentLogSession, entries: [AuditEntry]) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [
            "# Keel agent session \(session.id)",
            "",
            "- Client: \(session.client)",
            "- Mode: \(session.mode)",
            "- Started: \(stamp.string(from: session.started))",
            "- Ended: \(session.ended.map { stamp.string(from: $0) } ?? "still running")",
            "- Outcome: \(session.outcome)",
            "- Steps: \(entries.count)",
            "",
            "## Timeline",
            "",
            "| # | Time | Tool | What happened | Outcome | Arguments | URL |",
            "|---|---|---|---|---|---|---|",
        ]
        for entry in entries {
            let outcome = entry.outcome.rawValue + (entry.errorCode.map { " (\($0))" } ?? "")
            lines.append("| \(entry.id) | \(offset(entry.time, from: session.started)) | `\(entry.tool)` | \(cell(entry.summary)) | \(outcome) | "
                         + "\(cell(shortArguments(entry.arguments, limit: 160))) | \(cell(entry.url ?? "")) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A row of the session list: an ended session from the history, or a live one.
struct AgentLogSession {
    enum Status { case live, waiting, paused, done, failed, stopped, idle }

    var id: String
    var client: String
    var mode: String
    var started: Date
    var ended: Date?
    var actions: Int
    var summary: String
    var outcome: String
    var status: Status
}

/// Agent → Agent Activity Log (⌥⌘A).
@MainActor
final class AgentActivityLogController {
    static let shared = AgentActivityLogController()
    private var controller: AgentLogWindowController?

    func show(trust: AgentTrust) { show(trust: trust, sessionID: nil) }

    /// Opens the log with a session selected (the stop summary's View log).
    func show(trust: AgentTrust, sessionID: String?) {
        let controller = self.controller ?? AgentLogWindowController(trust: trust)
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if let sessionID { controller.select(sessionID: sessionID) }
    }
}

// MARK: - Window

@MainActor
final class AgentLogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum ListRow {
        case group(String)
        case session(AgentLogSession)
    }

    private let trust: AgentTrust
    private var rows: [ListRow] = []
    private var selectedID: String?
    private var entries: [AuditEntry] = []
    private var shown: [AuditEntry] = []
    /// Ended sessions' files, parsed once.
    private var fileCache: [String: [AuditEntry]] = [:]
    private var observer: NSObjectProtocol?
    private var reloadPending = false

    private let sessionsTable = NSTableView()
    private let timelineTable = NSTableView()
    private let filter = NSSearchField()
    private let sessionCount = Keel.label("", size: 12, color: Keel.dim)
    private let titleLabel = Keel.label("", size: 13, weight: .semibold)
    private let subtitleLabel = Keel.label("", size: 12, color: Keel.muted)
    private let stepsLabel = Keel.label("", size: 12, color: Keel.dim)
    private let emptyLabel = Keel.label("No agent sessions yet. Pair an agent and its every step shows up here.", size: 13, color: Keel.dim)
    private var pauseButton: NSButton!
    private var stopButton: NSButton!
    private var exportButtons: [NSButton] = []
    private let detail = NSStackView()

    init(trust: AgentTrust) {
        self.trust = trust
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent Activity Log"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Keel.chrome
        window.minSize = NSSize(width: 900, height: 460)
        window.isReleasedWhenClosed = false
        QuietMode.apply(to: window)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        if !window.setFrameUsingName("AgentActivityLog") { window.center() }
        window.setFrameAutosaveName("AgentActivityLog")
        observer = NotificationCenter.default.addObserver(forName: .agentTrustDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func windowWillClose(_ notification: Notification) {
        fileCache.removeAll()
    }

    func select(sessionID: String) {
        reload()
        guard let index = rows.firstIndex(where: { if case .session(let s) = $0 { return s.id == sessionID }; return false }) else { return }
        sessionsTable.selectRowIndexes([index], byExtendingSelection: false)
        sessionsTable.scrollRowToVisible(index)
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Keel.chrome.cgColor

        // Left: the sessions.
        let left = NSView()
        left.wantsLayer = true
        left.layer?.backgroundColor = Keel.surface.cgColor
        let leftHeader = NSStackView(views: [Keel.sectionLabel("Sessions"), NSView(), sessionCount])
        leftHeader.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        let sessionsScroll = configure(sessionsTable, id: "session", label: "Agent sessions")
        let leftStack = NSStackView(views: [leftHeader, Keel.separator(), sessionsScroll])
        leftStack.orientation = .vertical
        leftStack.distribution = .fill
        leftStack.spacing = 0
        AgentDialog.embed(leftStack, in: left, insets: NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 0))
        leftHeader.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // Middle: the session's bar, the timeline's bar, the timeline.
        pauseButton = Keel.miniButton("Pause") { [weak self] in self?.togglePause() }
        stopButton = Keel.miniButton("Stop & revoke", kind: .danger) { [weak self] in self?.stopSelected() }
        stopButton.setAccessibilityLabel("Stop and revoke this agent")
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sessionBar = NSStackView(views: [titleLabel, subtitleLabel, NSView(), pauseButton, stopButton])
        sessionBar.spacing = 8
        sessionBar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)

        filter.placeholderString = "Filter steps"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityLabel("Filter steps")
        filter.controlSize = .small
        filter.widthAnchor.constraint(equalToConstant: 200).isActive = true
        exportButtons = [
            Keel.miniButton("Export JSON") { [weak self] in self?.exportJSON() },
            Keel.miniButton("Export replay") { [weak self] in self?.exportReplay() },
            Keel.miniButton("Copy for AI") { [weak self] in self?.copyForAI() },
        ]
        exportButtons[0].setAccessibilityLabel("Export this session's log as JSON")
        exportButtons[1].setAccessibilityLabel("Export a replay of this session")
        exportButtons[2].setAccessibilityLabel("Copy the timeline as Markdown for an AI")
        let timelineBar = NSStackView(views: [Keel.sectionLabel("Timeline"), stepsLabel, NSView(), filter] + exportButtons)
        timelineBar.spacing = 8
        timelineBar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        let timelineScroll = configure(timelineTable, id: "step", label: "Timeline")
        let middle = NSStackView(views: [sessionBar, Keel.separator(), timelineBar, Keel.separator(), timelineScroll])
        middle.orientation = .vertical
        middle.distribution = .fill
        middle.spacing = 0
        middle.setContentHuggingPriority(.init(1), for: .horizontal)
        sessionBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        timelineBar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        timelineScroll.addSubview(emptyLabel)
        emptyLabel.centerXAnchor.constraint(equalTo: timelineScroll.centerXAnchor).isActive = true
        emptyLabel.centerYAnchor.constraint(equalTo: timelineScroll.centerYAnchor).isActive = true

        // Right: the selected step.
        let right = NSView()
        right.wantsLayer = true
        right.layer?.backgroundColor = Keel.surface.cgColor
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.alignment = .leading
        detail.spacing = 10
        AgentDialog.embed(detail, in: right, insets: NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16))

        func divider() -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = Keel.hairline.cgColor
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            return line
        }
        let columns = NSStackView(views: [left, divider(), middle, divider(), right])
        columns.spacing = 0
        columns.distribution = .fill
        columns.alignment = .height
        AgentDialog.embed(columns, in: root, insets: NSEdgeInsets(top: 0.5, left: 0, bottom: 0, right: 0))
        for view in [leftStack, middle] {
            for child in view.arrangedSubviews { child.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
        }
        NSLayoutConstraint.activate([
            left.widthAnchor.constraint(equalToConstant: 300),
            right.widthAnchor.constraint(equalToConstant: 330),
        ])
        return root
    }

    private func configure(_ table: NSTableView, id: String, label: String) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(label)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    // MARK: Data

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                if self?.window?.isVisible == true { self?.reload() }
            }
        }
    }

    private var sessions: [AgentLogSession] {
        var list: [AgentLogSession] = trust.history.map { record in
            let live = trust.live(record.id)
            return AgentLogSession(id: record.id, client: record.client, mode: live?.session.mode.kind.rawValue ?? record.mode,
                                   started: record.started, ended: record.ended, actions: live?.session.actions ?? record.actions,
                                   summary: record.lastSummary, outcome: record.outcome, status: status(record.outcome, live: live))
        }
        for live in trust.sessions.values where !list.contains(where: { $0.id == live.session.id }) {
            list.append(AgentLogSession(id: live.session.id, client: live.session.clientName, mode: live.session.mode.kind.rawValue,
                                        started: live.session.started, ended: nil, actions: live.session.actions,
                                        summary: live.log.entries.last?.summary ?? "Connected", outcome: "running", status: status("running", live: live)))
        }
        return list.sorted { $0.started > $1.started }
    }

    private func status(_ outcome: String, live: AgentTrust.Live?) -> AgentLogSession.Status {
        if let live, live.session.state != .stopped {
            if trust.approvals.contains(where: { $0.sessionID == live.session.id }) { return .waiting }
            if case .needsHuman = live.session.state { return .waiting }
            return live.session.state == .paused ? .paused : .live
        }
        switch outcome {
        case "done": return .done
        case "failed": return .failed
        case "stopped": return .stopped
        default: return .idle   // "running" with no live session: the app quit mid-run
        }
    }

    private func reload() {
        let list = sessions
        rows = []
        let calendar = Calendar.current
        var group = ""
        for session in list {
            let name = calendar.isDateInToday(session.started) ? "Today" : calendar.isDateInYesterday(session.started) ? "Yesterday" : "Earlier"
            if name != group { rows.append(.group(name)); group = name }
            rows.append(.session(session))
        }
        sessionCount.stringValue = "\(list.count) · \(trust.settings.logRetentionDays) days kept"
        if selectedID == nil || !list.contains(where: { $0.id == selectedID }) { selectedID = list.first?.id }
        sessionsTable.reloadData()
        if let index = rows.firstIndex(where: { if case .session(let s) = $0 { return s.id == selectedID }; return false }) {
            sessionsTable.selectRowIndexes([index], byExtendingSelection: false)
        }
        loadTimeline()
    }

    private var selected: AgentLogSession? {
        for case .session(let session) in rows where session.id == selectedID { return session }
        return nil
    }

    private func loadTimeline() {
        guard let session = selected else {
            entries = []
            applyFilter()
            syncBars()
            return
        }
        if trust.live(session.id) != nil {
            entries = AgentLogs.entries(sessionID: session.id, trust: trust)
        } else if let cached = fileCache[session.id] {
            entries = cached
        } else {
            entries = AgentLogs.entries(sessionID: session.id, trust: trust)
            fileCache[session.id] = entries
        }
        applyFilter()
        syncBars()
    }

    private func applyFilter() {
        let selectedEntry = timelineTable.selectedRow >= 0 && timelineTable.selectedRow < shown.count ? shown[timelineTable.selectedRow].id : nil
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = query.isEmpty ? entries : entries.filter { entry in
            [entry.summary, entry.tool, entry.url ?? "", entry.outcome.rawValue, entry.errorCode ?? "", AgentLogs.shortArguments(entry.arguments, limit: 400)]
                .contains { $0.lowercased().contains(query) }
        }
        let atEnd = timelineTable.rows(in: timelineTable.visibleRect).upperBound >= timelineTable.numberOfRows - 1
        timelineTable.reloadData()
        if let selectedEntry, let index = shown.firstIndex(where: { $0.id == selectedEntry }) {
            timelineTable.selectRowIndexes([index], byExtendingSelection: false)
        } else if atEnd, !shown.isEmpty {
            timelineTable.scrollRowToVisible(shown.count - 1)
        }
        emptyLabel.isHidden = !rows.isEmpty
        showDetail()
    }

    private func syncBars() {
        guard let session = selected else {
            titleLabel.stringValue = "No session"
            subtitleLabel.stringValue = ""
            stepsLabel.stringValue = ""
            pauseButton.isHidden = true
            stopButton.isHidden = true
            exportButtons.forEach { $0.isEnabled = false }
            return
        }
        titleLabel.stringValue = "Session \(session.id)"
        subtitleLabel.stringValue = "\(session.client) · started \(Keel.clock(session.started)) · \(session.mode)"
            + (session.ended.map { " · ended \(Keel.clock($0))" } ?? "")
        let waiting = entries.count { $0.outcome == .waiting } > 0 && session.status == .waiting
        stepsLabel.stringValue = "\(entries.count) steps" + (waiting ? " · 1 waiting" : "")
        let live = trust.live(session.id)
        pauseButton.isHidden = live == nil
        stopButton.isHidden = live == nil
        (pauseButton as? KeelMiniButton)?.setLabel(live?.session.state == .paused ? "Resume" : "Pause")
        pauseButton.setAccessibilityLabel(live?.session.state == .paused ? "Resume this agent" : "Pause this agent")
        exportButtons.forEach { $0.isEnabled = !entries.isEmpty }
    }

    // MARK: Detail

    private func showDetail() {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width: CGFloat = 330 - 32
        guard timelineTable.selectedRow >= 0, timelineTable.selectedRow < shown.count, let session = selected else {
            detail.addArrangedSubview(AgentDialog.text(rows.isEmpty ? "" : "Select a step to see what was sent and what came of it.",
                                                       width: width, size: 12, color: Keel.dim))
            return
        }
        let entry = shown[timelineTable.selectedRow]
        let chip = KeelChip()
        let color = AgentLogs.color(entry.outcome)
        chip.set(AgentLogs.outcomeText(entry.outcome), fill: entry.outcome == .waiting ? Keel.amberChip : entry.outcome == .ok || entry.outcome == .approved ? Keel.greenChip : Keel.dangerFill,
                 color: color, dot: entry.outcome == .waiting ? Keel.amber : nil)
        let header = NSStackView(views: [Keel.label("Step \(entry.id) · \(entry.tool)", size: 13, weight: .semibold), NSView(), chip])
        header.spacing = 8
        detail.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: width).isActive = true

        var facts: [(String, String)] = [
            ("Started", Keel.clock(entry.time, seconds: true) + "  " + AgentLogs.offset(entry.time, from: session.started)),
            ("Duration", AgentLogs.duration(entry.milliseconds)),
        ]
        if let url = entry.url { facts.append(("URL", url)) }
        if let code = entry.errorCode { facts.append(("Error", code)) }
        if entry.resultTokens > 0 { facts.append(("Result", TokenEstimate.format(entry.resultTokens))) }
        facts.append(("Mode", session.mode))
        for (name, value) in facts {
            let key = Keel.label(name, size: 12, color: Keel.dim)
            key.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let text = Keel.monoLabel(value, color: Keel.text)
            text.isSelectable = true
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [key, text])
            row.spacing = 8
            detail.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        detail.addArrangedSubview(AgentDialog.text(entry.summary, width: width, size: 13, color: Keel.text))
        detail.addArrangedSubview(Keel.sectionLabel("Arguments"))
        let json = NSTextView()
        json.isEditable = false
        json.drawsBackground = false
        json.textContainerInset = NSSize(width: 8, height: 8)
        json.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        json.textColor = Keel.text
        json.string = String(decoding: entry.arguments.encoded(pretty: true), as: UTF8.self)
        json.setAccessibilityLabel("Arguments of step \(entry.id)")
        json.isVerticallyResizable = true
        json.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = json
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let box = KeelPanel(fill: Keel.chrome, border: Keel.hairline, radius: 9)
        AgentDialog.embed(scroll, in: box, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        detail.addArrangedSubview(box)
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        box.setContentHuggingPriority(.init(1), for: .vertical)
    }

    // MARK: Actions

    private func togglePause() {
        guard let id = selected?.id, let live = trust.live(id) else { return }
        if live.session.state == .paused { trust.resume(live) } else { trust.pause(live) }
    }

    private func stopSelected() {
        guard let id = selected?.id, let live = trust.live(id), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Stop \(live.session.clientName) and revoke its token?"
        alert.informativeText = "Its session ends, its tabs close, and it cannot reconnect without pairing again."
        alert.addButton(withTitle: "Stop & Revoke")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let client = live.session.clientID
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.trust.stopAndRevoke(clientIDs: [client]) }
        }
    }

    private func exportJSON() {
        guard let id = selected?.id, !entries.isEmpty else { return }
        AgentLogs.save(AuditLog(entries: entries).exportJSON(), name: "keel-session-\(id).json", from: window)
    }

    private func exportReplay() {
        guard let id = selected?.id, !entries.isEmpty else { return }
        AgentLogs.save(AgentLogs.replay(entries).encoded(pretty: true), name: "keel-replay-\(id).json", from: window)
    }

    private func copyForAI() {
        guard let session = selected, !entries.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentLogs.markdown(session, entries: shown), forType: .string)
        (exportButtons[2] as? KeelMiniButton)?.setLabel("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { (self?.exportButtons[2] as? KeelMiniButton)?.setLabel("Copy for AI") }
        }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sessionsTable ? rows.count : shown.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === sessionsTable, case .group = rows[row] { return 30 }
        return tableView === sessionsTable ? 54 : 46
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === sessionsTable, case .group = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentLogRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === sessionsTable {
            let row = sessionsTable.selectedRow
            guard row >= 0, case .session(let session) = rows[row], session.id != selectedID else { return }
            selectedID = session.id
            timelineTable.deselectAll(nil)
            loadTimeline()
            if !shown.isEmpty { timelineTable.scrollRowToVisible(shown.count - 1) }
        } else {
            showDetail()
        }
    }

    func controlTextDidChange(_ notification: Notification) { applyFilter() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        tableView === sessionsTable ? sessionCell(rows[row]) : stepCell(shown[row])
    }

    private func sessionCell(_ row: ListRow) -> NSView {
        let cell = NSView()
        switch row {
        case .group(let title):
            let label = Keel.sectionLabel(title)
            AgentDialog.embed(label, in: cell, insets: NSEdgeInsets(top: 12, left: 14, bottom: 4, right: 14))
        case .session(let session):
            let mark: NSView
            switch session.status {
            case .live: mark = Keel.mark(Keel.amberChip, radius: 4, glyph: "●", glyphColor: Keel.amber)
            case .waiting: mark = Keel.mark(Keel.amberChip, radius: 4, glyph: "●", glyphColor: Keel.amber)
            case .paused: mark = Keel.mark(Keel.inputBorder, radius: 4, glyph: "‖", glyphColor: Keel.muted)
            case .done: mark = Keel.mark(Keel.greenChip, radius: 4, glyph: "✓", glyphColor: Keel.greenText)
            case .failed: mark = Keel.mark(Keel.dangerFill, radius: 4, glyph: "✕", glyphColor: Keel.dangerText)
            case .stopped: mark = Keel.mark(Keel.inputBorder, radius: 4, glyph: "■", glyphColor: Keel.idle)
            case .idle: mark = Keel.mark(Keel.inputBorder, radius: 4, glyph: "●", glyphColor: Keel.idle)
            }
            let client = Keel.label(session.client, size: 13, weight: .semibold)
            client.lineBreakMode = .byTruncatingTail
            client.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var top: [NSView] = [client]
            if session.mode == SessionMode.Kind.borrowed.rawValue {
                let chip = Keel.label("Borrowed", size: 11, weight: .medium, color: Keel.coralText)
                top.append(chip)
            }
            top += [NSView(), Keel.monoLabel(Keel.clock(session.started))]
            let topRow = NSStackView(views: top)
            topRow.spacing = 6
            var line = session.status == .stopped ? "Stopped by you" : session.summary
            line += " · \(session.actions) step\(session.actions == 1 ? "" : "s")"
            if session.status == .live || session.status == .waiting || session.status == .paused {
                line += session.status == .paused ? " · paused" : session.status == .waiting ? " · waiting" : " · live"
            }
            let second = Keel.label(line, size: 12, color: Keel.muted)
            second.lineBreakMode = .byTruncatingTail
            second.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = NSStackView(views: [topRow, second])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 3
            topRow.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
            let stack = NSStackView(views: [mark, text])
            stack.spacing = 10
            stack.alignment = .top
            AgentDialog.embed(stack, in: cell, insets: NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14))
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(.row)
            cell.setAccessibilityLabel("\(session.client), \(session.mode), \(line), started \(Keel.clock(session.started))")
        }
        return cell
    }

    private func stepCell(_ entry: AuditEntry) -> NSView {
        let cell = NSView()
        let start = selected?.started ?? entry.time
        let dot = Keel.mark(AgentLogs.color(entry.outcome), size: 7)
        let summary = Keel.label(entry.summary, size: 13, color: entry.outcome == .waiting ? Keel.amberSoft : Keel.text)
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var detailText = entry.tool
        let arguments = AgentLogs.shortArguments(entry.arguments)
        if !arguments.isEmpty { detailText += " " + arguments }
        if entry.outcome != .ok, entry.outcome != .waiting { detailText += " · " + AgentLogs.outcomeText(entry.outcome).lowercased() }
        if let code = entry.errorCode { detailText += " · " + code }
        let detailLabel = Keel.monoLabel(detailText)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [summary, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let duration = Keel.monoLabel(entry.milliseconds > 0 ? AgentLogs.duration(entry.milliseconds) : "", color: Keel.muted)
        let offset = Keel.monoLabel(AgentLogs.offset(entry.time, from: start))
        offset.alignment = .right
        offset.widthAnchor.constraint(equalToConstant: 62).isActive = true
        for label in [duration, offset] { label.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let stack = NSStackView(views: [dot, text, NSView(), duration, offset])
        stack.spacing = 10
        stack.alignment = .centerY
        AgentDialog.embed(stack, in: cell, insets: NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14))
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.row)
        cell.setAccessibilityLabel("Step \(entry.id), \(entry.summary), \(AgentLogs.outcomeText(entry.outcome)), \(AgentLogs.offset(entry.time, from: start))")
        return cell
    }
}

/// Flat selection, as the design's lists have it.
private final class AgentLogRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Keel.hairline.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 7, yRadius: 7).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
