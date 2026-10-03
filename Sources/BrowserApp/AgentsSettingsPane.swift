import AppKit
import AgentKit

/// Settings → Agents & permissions (G4-02): whether agents may connect at
/// all, what a new session starts as, when the person is asked, who is
/// paired, per-origin rules, budgets, and WebMCP and the log.
///
/// Everything here is the trust layer's (`AgentTrust.settings`, `.rules`,
/// `.clients`); the pane only shows it and writes it back. It follows
/// `.agentTrustDidChange`, so a pairing or a revoke elsewhere shows at once.
@MainActor
final class AgentsSettingsPane: NSViewController, NSTextFieldDelegate {
    var server: () -> AgentServer?
    /// For self-tests: a trust layer of their own, in a scratch folder.
    var trustOverride: AgentTrust?
    var trust: AgentTrust? { trustOverride ?? server()?.trust }

    let connectionsSwitch = KeelSwitch(label: "Allow agent connections", target: nil, action: nil)
    let statusLabel = Keel.monoLabel("", color: Keel.muted)
    private let statusDot = KeelSettings.dot(Keel.idle)
    let sandboxCard = SessionTypeCard(kind: .sandbox)
    let borrowedCard = SessionTypeCard(kind: .borrowed)
    let policyPopUp = KeelSettings.popUp(ApprovalPolicy.allCases.map(\.label), label: "Approval policy", target: nil, action: nil)
    let timeoutPopUp = KeelSettings.popUp([], label: "If I don’t answer within", target: nil, action: nil)
    let pageInstructionsSwitch = KeelSwitch(label: "Always ask for actions that came from page content", target: nil, action: nil)
    let clientsCard = KeelCard()
    let rulesCard = KeelCard()
    let pairButton = KeelButton("Pair a new agent…", kind: .primary, target: nil, action: nil)
    let addRuleButton = KeelButton("Add rule…", kind: .neutral, target: nil, action: nil)
    let actionsField = AgentsSettingsPane.budgetField("Actions per session")
    let navigationsField = AgentsSettingsPane.budgetField("Navigations per minute")
    let snapshotField = AgentsSettingsPane.budgetField("Snapshot size, in tokens")
    let timeLimitField = AgentsSettingsPane.budgetField("Time limit, in minutes")
    let webMCPSwitch = KeelSwitch(label: "WebMCP", target: nil, action: nil)
    let retentionPopUp = KeelSettings.popUp(["7 days", "30 days", "90 days"], label: "Activity log retention", target: nil, action: nil)

    static let timeouts = [30, 60, 120, 300]
    static let retentions = [7, 30, 90]
    private var observer: NSObjectProtocol?

    init(server: @escaping () -> AgentServer? = { nil }) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
        title = "Agents"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    override func loadView() {
        connectionsSwitch.target = self
        connectionsSwitch.action = #selector(connectionsChanged(_:))
        for card in [sandboxCard, borrowedCard] {
            card.target = self
            card.action = #selector(sessionTypeChosen(_:))
        }
        policyPopUp.target = self
        policyPopUp.action = #selector(policyChanged(_:))
        timeoutPopUp.target = self
        timeoutPopUp.action = #selector(timeoutChanged(_:))
        pageInstructionsSwitch.target = self
        pageInstructionsSwitch.action = #selector(pageInstructionsChanged(_:))
        pairButton.target = self
        pairButton.action = #selector(pairNewAgent(_:))
        addRuleButton.target = self
        addRuleButton.action = #selector(addRule(_:))
        webMCPSwitch.target = self
        webMCPSwitch.action = #selector(webMCPChanged(_:))
        retentionPopUp.target = self
        retentionPopUp.action = #selector(retentionChanged(_:))
        for field in [actionsField, navigationsField, snapshotField, timeLimitField] { field.delegate = self }

        let connections = KeelCard(rows: [
            KeelSettings.row("Allow agent connections",
                             detail: "MCP clients on this Mac may open and drive tabs. Turning this off disconnects every paired agent immediately.",
                             detailWidth: 480, accessories: [connectionsSwitch]),
            KeelSettings.row(labels: [statusLabel], leading: [statusDot], accessories: []),
        ])

        let sessionTypes = NSStackView(views: [sandboxCard, borrowedCard])
        sessionTypes.distribution = .fillEqually
        sessionTypes.spacing = 12
        sessionTypes.alignment = .top
        sandboxCard.heightAnchor.constraint(equalTo: borrowedCard.heightAnchor).isActive = true

        let consequential = KeelCard(rows: [
            KeelSettings.row("Approval policy", detail: "Purchases, payment forms, deletes, sending messages, sign-ins and file uploads.",
                             accessories: [policyPopUp]),
            KeelSettings.row("If I don’t answer within", detail: "The agent receives “denied” and the tab stays paused.",
                             accessories: [timeoutPopUp]),
            KeelSettings.row("Actions that came from page content", detail: "Treat instructions found on a page as untrusted and always ask.",
                             accessories: [pageInstructionsSwitch]),
        ])

        let pairRow = NSStackView(views: [pairButton])
        let rulesFooter = NSStackView(views: [
            KeelSettings.note("Rules match the exact origin. “Ask” is the default for any origin not listed.", width: 460),
            NSView(), addRuleButton,
        ])
        rulesFooter.alignment = .centerY

        let budgets = NSStackView()
        budgets.orientation = .horizontal
        budgets.spacing = 0
        budgets.alignment = .top
        let cells = [budgetCell("Actions", actionsField, "max"), budgetCell("Navigations", navigationsField, "per minute"),
                     budgetCell("Snapshot size", snapshotField, "tokens"), budgetCell("Time limit", timeLimitField, "minutes")]
        for (index, cell) in cells.enumerated() {
            if index > 0 {
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = Keel.hairline.cgColor
                line.translatesAutoresizingMaskIntoConstraints = false
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                budgets.addArrangedSubview(line)
                line.heightAnchor.constraint(equalTo: budgets.heightAnchor).isActive = true
            }
            budgets.addArrangedSubview(cell)
            if index > 0 { cell.widthAnchor.constraint(equalTo: cells[0].widthAnchor).isActive = true }
        }
        let budgetsCard = KeelCard(rows: [budgets])

        let experimental = KeelSettings.tag("Experimental", fill: Keel.amberChip, color: Keel.amberSoft)
        let webMCPTitle = NSStackView(views: [Keel.label("WebMCP"), experimental])
        webMCPTitle.spacing = 8
        let logging = KeelCard(rows: [
            KeelSettings.row(labels: [webMCPTitle, KeelSettings.note(
                "Let pages expose their own tools to connected agents via navigator.modelContext. Each tool call asks first.", width: 480)],
                accessories: [webMCPSwitch]),
            KeelSettings.row("Activity log retention", detail: "Timeline, approvals and “Copy for AI” snapshots are stored locally.",
                             accessories: [retentionPopUp]),
        ])

        view = KeelSettings.page(title: "Agents & permissions", subtitle: "Who can drive the browser, and what they may do without asking", sections: [
            connections,
            KeelSettings.section("Default session type"), sessionTypes,
            KeelSettings.section("Consequential actions"), consequential,
            KeelSettings.section("Paired agents"), clientsCard, pairRow,
            KeelSettings.section("Per-origin rules"), rulesCard, rulesFooter,
            KeelSettings.section("Budgets (defaults per session)"), budgetsCard,
            KeelSettings.note("New agents start with these. Each agent’s own limits are under Edit.", size: 11.5, color: Keel.dim),
            KeelSettings.section("Experimental & logging"), logging,
        ])
        observer = NotificationCenter.default.addObserver(forName: .agentTrustDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private static func budgetField(_ label: String) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .default
        field.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        field.textColor = Keel.text
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 1
        formatter.maximum = 1_000_000
        field.formatter = formatter
        field.setAccessibilityLabel(label)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.identifier = NSUserInterfaceItemIdentifier("budget")
        let width = field.widthAnchor.constraint(equalToConstant: 72)
        width.identifier = "budget.width"
        width.isActive = true
        return field
    }

    /// The number sits beside its unit, as text does, however many digits it has.
    private static func fitWidth(_ field: NSTextField) {
        let text = field.currentEditor()?.string ?? field.stringValue
        let size = (text.isEmpty ? "0" : text).size(withAttributes: [.font: field.font ?? Keel.mono])
        field.constraints.first { $0.identifier == "budget.width" }?.constant = max(28, ceil(size.width) + 10)
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field.identifier?.rawValue == "budget" { Self.fitWidth(field) }
    }

    private func budgetCell(_ title: String, _ field: NSTextField, _ unit: String) -> NSView {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
            .font: Keel.font(11, .semibold), .foregroundColor: Keel.dim, .kern: 0.44,
        ]))
        let value = NSStackView(views: [field, Keel.label(unit, size: 12, color: Keel.muted)])
        value.spacing = 4
        value.alignment = .firstBaseline
        let cell = NSStackView(views: [label, value])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 4
        cell.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return cell
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: - State

    /// The server's state changed (the switch, the port, a connection).
    func refreshServerState() {
        guard isViewLoaded else { return }
        connectionsSwitch.isOn = AgentServer.isEnabled
        let server = server()
        let connected = trust?.runningCount ?? 0
        let waiting = trust?.approvals.count ?? 0
        let counts = "\(connected) \(connected == 1 ? "agent" : "agents") connected · \(waiting) waiting"
        let color: NSColor
        switch server?.state ?? .off {
        case .off:
            statusLabel.stringValue = "Off · no agent can connect"
            color = Keel.idle
        case .starting:
            statusLabel.stringValue = "Starting…"
            color = Keel.amber
        case .listening(let port):
            statusLabel.stringValue = "Listening on 127.0.0.1:\(port) · " + counts
            color = Keel.green
        case .failed(let reason):
            statusLabel.stringValue = "Not running: \(reason)"
            color = Keel.dangerText
        }
        statusDot.layer?.backgroundColor = color.cgColor
        statusLabel.setAccessibilityLabel("Server status: \(statusLabel.stringValue)")
    }

    func refresh() {
        guard isViewLoaded else { return }
        refreshServerState()
        let settings = trust?.settings ?? AgentTrust.Settings()
        sandboxCard.isSelected = settings.defaultMode == .sandbox
        borrowedCard.isSelected = settings.defaultMode == .borrowed
        policyPopUp.selectItem(at: ApprovalPolicy.allCases.firstIndex(of: settings.policy) ?? 0)
        fillTimeouts(selected: settings.approvalTimeoutSeconds)
        pageInstructionsSwitch.isOn = settings.pageInstructionsAlwaysAsk
        webMCPSwitch.isOn = settings.webMCP
        if let index = Self.retentions.firstIndex(of: settings.logRetentionDays) {
            retentionPopUp.selectItem(at: index)
        } else {
            retentionPopUp.selectItem(withTitle: "30 days")
        }
        for (field, value) in [(actionsField, settings.budgets.maxActions), (navigationsField, settings.budgets.navigationsPerMinute),
                               (snapshotField, settings.budgets.snapshotTokens), (timeLimitField, settings.budgets.timeLimitMinutes)]
        where field.currentEditor() == nil {
            field.integerValue = value
            Self.fitWidth(field)
        }
        for control in [policyPopUp, timeoutPopUp, retentionPopUp, actionsField, navigationsField, snapshotField, timeLimitField] as [NSControl] {
            control.isEnabled = trust != nil
        }
        refreshClients()
        refreshRules()
    }

    private static func describe(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds % 60 == 0 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return "\(seconds) seconds"
    }

    /// The four choices, and the saved value too if it is none of them.
    private func fillTimeouts(selected: Int) {
        var values = Self.timeouts
        if !values.contains(selected) { values = (values + [selected]).sorted() }
        let titles = values.map(Self.describe(seconds:))
        if timeoutPopUp.itemTitles != titles {
            timeoutPopUp.removeAllItems()
            timeoutPopUp.addItems(withTitles: titles)
            for (item, value) in zip(timeoutPopUp.itemArray, values) { item.tag = value }
        }
        timeoutPopUp.selectItem(withTag: selected)
    }

    // MARK: Paired agents

    private func refreshClients() {
        let clients = (trust?.clients ?? []).sorted { ($0.isActive ? 0 : 1, $1.pairedAt) < ($1.isActive ? 0 : 1, $0.pairedAt) }
        guard !clients.isEmpty else {
            clientsCard.setRows([KeelSettings.row(labels: [KeelSettings.note(
                "No agent is paired yet. Run keel pair in a terminal, or pair one here.", width: 520)], accessories: [])])
            return
        }
        let live = Set(trust?.sessions.values.filter { $0.session.state != .stopped }.map(\.session.clientID) ?? [])
        clientsCard.setRows(clients.map { clientRow($0, connected: live.contains($0.id)) })
    }

    private func clientRow(_ client: PairedClient, connected: Bool) -> NSView {
        let name = AgentServer.friendlyName(client.name)
        let avatar = NSView()
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 7
        avatar.layer?.backgroundColor = (connected && client.isActive ? Keel.amber : Keel.idle).cgColor
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 28), avatar.heightAnchor.constraint(equalToConstant: 28)])

        let title = Keel.label(name, weight: .semibold)
        let paired = client.pairedAt.formatted(.dateTime.day().month(.abbreviated))
        let detail = Keel.monoLabel("pairing \(client.id) · paired \(paired) · \(client.scope.label)", color: Keel.muted)

        let status: String
        let statusColor: NSColor
        let dotColor: NSColor
        if let revoked = client.revokedAt {
            status = "Revoked \(revoked.formatted(.dateTime.day().month(.abbreviated)))"
            (statusColor, dotColor) = (Keel.dim, Keel.idle)
        } else if client.paused {
            status = "Paused"
            (statusColor, dotColor) = (Keel.amberSoft, Keel.amber)
        } else if let used = client.lastUsed {
            status = "Last used " + Self.relative.localizedString(for: used, relativeTo: Date())
            (statusColor, dotColor) = connected ? (Keel.greenText, Keel.green) : (Keel.muted, Keel.idle)
        } else {
            status = "Never used"
            (statusColor, dotColor) = (Keel.muted, Keel.idle)
        }
        let statusRow = NSStackView(views: [KeelSettings.dot(dotColor), Keel.label(status, size: 12, color: statusColor)])
        statusRow.spacing = 6
        statusRow.setAccessibilityElement(true)
        statusRow.setAccessibilityRole(.staticText)
        statusRow.setAccessibilityLabel(status)

        let edit = KeelButton("Edit", kind: .neutral, target: self, action: #selector(editClient(_:)))
        let pause = KeelButton(client.paused ? "Resume" : "Pause", kind: .neutral, target: self, action: #selector(togglePause(_:)))
        let revoke = KeelButton("Revoke", kind: .danger, target: self, action: #selector(revokeClient(_:)))
        for (button, verb) in [(edit, "Edit grants of"), (pause, client.paused ? "Resume" : "Pause"), (revoke, "Revoke")] {
            button.cell?.representedObject = client.id
            button.setAccessibilityLabel("\(verb) \(name)")
            button.isEnabled = client.isActive
            button.alphaValue = client.isActive ? 1 : 0.4
        }
        let buttons = NSStackView(views: [edit, pause, revoke])
        buttons.spacing = 8
        return KeelSettings.row(labels: [title, detail], leading: [avatar], accessories: [statusRow, buttons])
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func clientID(_ sender: Any?) -> String? { (sender as? NSButton)?.cell?.representedObject as? String }

    @objc private func togglePause(_ sender: Any?) {
        guard let id = clientID(sender), let trust else { return }
        trust.updateClient(id) { $0.paused.toggle() }
    }

    @objc private func revokeClient(_ sender: Any?) {
        guard let id = clientID(sender), let trust, let client = trust.clients.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Revoke \(AgentServer.friendlyName(client.name))?"
        alert.informativeText = "Its token stops working at once and its sessions end; sandbox data is wiped. To use it again, pair it again."
        alert.addButton(withTitle: "Revoke")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let answer: (NSApplication.ModalResponse) -> Void = { [weak trust] response in
            if response == .alertFirstButtonReturn { trust?.revoke(id) }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }

    /// The grants sheet (G2-02) belongs to the pairing windows. It is asked
    /// for through the responder chain, as `showAgentGrants:` with the client
    /// id in a menu item's `representedObject`, so this pane does not depend
    /// on it. Until something answers, the tool scope is offered here.
    @objc private func editClient(_ sender: Any?) {
        guard let id = clientID(sender), let trust, let client = trust.clients.first(where: { $0.id == id }) else { return }
        let carrier = NSMenuItem()
        carrier.representedObject = id
        if NSApp.sendAction(Selector(("showAgentGrants:")), to: nil, from: carrier) { return }
        let menu = NSMenu()
        for scope in ToolScope.allCases {
            let item = NSMenuItem(title: scope == .all ? "All tools" : "Read-only tools", action: #selector(scopeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [id, scope.rawValue]
            item.state = client.scope == scope ? .on : .off
            menu.addItem(item)
        }
        if let button = sender as? NSView {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func scopeChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, let scope = ToolScope(rawValue: pair[1]) else { return }
        trust?.updateClient(pair[0]) { $0.scope = scope }
    }

    @objc private func pairNewAgent(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.pairNewAgent(_:)), to: nil, from: sender)
    }

    // MARK: Per-origin rules

    private func refreshRules() {
        let entries = (trust?.rules.entries ?? []).sorted { $0.origin < $1.origin }
        let header = NSStackView(views: [
            Self.column("Origin"), Self.column("Rule", width: 110), Self.column("Expires", width: 130), Self.column("", width: 40),
        ])
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true
        guard !entries.isEmpty else {
            rulesCard.setRows([header, KeelSettings.row(labels: [KeelSettings.note("No rules yet. Agents are asked on every origin.", width: 520)],
                                                        accessories: [])])
            return
        }
        rulesCard.setRows([header] + entries.map(ruleRow))
    }

    private static func column(_ title: String, width: CGFloat? = nil) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
            .font: Keel.font(11, .semibold), .foregroundColor: Keel.dim, .kern: 0.44,
        ]))
        if let width { label.widthAnchor.constraint(equalToConstant: width).isActive = true } else {
            label.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        return label
    }

    private func ruleRow(_ entry: OriginRules.Entry) -> NSView {
        let origin = Keel.monoLabel(entry.origin, color: Keel.text)
        origin.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        origin.setContentHuggingPriority(.init(1), for: .horizontal)
        origin.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let rule = NSPopUpButton(frame: .zero, pullsDown: false)
        rule.addItems(withTitles: OriginRules.Rule.allCases.map(\.label))
        rule.selectItem(at: OriginRules.Rule.allCases.firstIndex(of: entry.rule) ?? 0)
        rule.target = self
        rule.action = #selector(ruleChanged(_:))
        rule.cell?.representedObject = entry.origin
        rule.controlSize = .small
        rule.setAccessibilityLabel("Rule for \(entry.origin)")
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let expires = Keel.label(Self.describe(expiry: entry.expires), size: 12, color: Keel.muted)
        expires.translatesAutoresizingMaskIntoConstraints = false
        expires.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove rule for \(entry.origin)") ?? NSImage(),
                              target: self, action: #selector(removeRule(_:)))
        remove.isBordered = false
        remove.contentTintColor = Keel.dim
        remove.cell?.representedObject = entry.origin
        remove.setAccessibilityLabel("Remove rule for \(entry.origin)")
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = NSStackView(views: [origin, rule, expires, remove])
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return row
    }

    /// "Never", "in 6 days (9 Oct)", "Expired".
    private static func describe(expiry: Date?) -> String {
        guard let expiry else { return "Never" }
        if expiry <= Date() { return "Expired" }
        return "\(relative.localizedString(for: expiry, relativeTo: Date())) (\(expiry.formatted(.dateTime.day().month(.abbreviated))))"
    }

    @objc private func ruleChanged(_ sender: NSPopUpButton) {
        guard let origin = sender.cell?.representedObject as? String, let trust,
              OriginRules.Rule.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let expires = trust.rules.entries.first { $0.origin == origin }?.expires
        trust.rules.set(origin, OriginRules.Rule.allCases[sender.indexOfSelectedItem], expires: expires)
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard let origin = sender.cell?.representedObject as? String else { return }
        trust?.rules.remove(origin)
    }

    @objc private func addRule(_ sender: Any?) {
        guard let trust else { return }
        let field = NSTextField()
        field.placeholderString = "shop.example.com"
        field.setAccessibilityLabel("Origin")
        let rule = NSPopUpButton(frame: .zero, pullsDown: false)
        rule.addItems(withTitles: OriginRules.Rule.allCases.map(\.label))
        rule.selectItem(withTitle: OriginRules.Rule.never.label)
        rule.setAccessibilityLabel("Rule")
        let accessory = NSStackView(views: [field, rule])
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        field.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let alert = NSAlert()
        alert.messageText = "Add a rule for an origin"
        alert.informativeText = "“Allow” lets agents act there without asking, except for payments and passwords. “Never” refuses every consequential action there."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let answer: (NSApplication.ModalResponse) -> Void = { [weak trust] response in
            guard response == .alertFirstButtonReturn, let trust else { return }
            let origin = Origin.normalize(field.stringValue)
            guard !origin.isEmpty, !origin.contains(" ") else { NSSound.beep(); return }
            let chosen = OriginRules.Rule.allCases[max(0, rule.indexOfSelectedItem)]
            trust.rules.set(origin, chosen)
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }

    // MARK: - Actions

    @objc private func connectionsChanged(_ sender: Any?) {
        AgentServer.isEnabled = connectionsSwitch.isOn
        server()?.sync()
        refreshServerState()
    }

    @objc private func sessionTypeChosen(_ sender: SessionTypeCard) {
        trust?.settings.defaultMode = sender.kind
    }

    @objc private func policyChanged(_ sender: Any?) {
        let policies = ApprovalPolicy.allCases
        guard policies.indices.contains(policyPopUp.indexOfSelectedItem) else { return }
        trust?.settings.policy = policies[policyPopUp.indexOfSelectedItem]
    }

    @objc private func timeoutChanged(_ sender: Any?) {
        guard let seconds = timeoutPopUp.selectedItem?.tag, seconds > 0 else { return }
        trust?.settings.approvalTimeoutSeconds = seconds
    }

    @objc private func pageInstructionsChanged(_ sender: Any?) {
        trust?.settings.pageInstructionsAlwaysAsk = pageInstructionsSwitch.isOn
    }

    @objc private func webMCPChanged(_ sender: Any?) {
        trust?.settings.webMCP = webMCPSwitch.isOn
    }

    @objc private func retentionChanged(_ sender: Any?) {
        guard Self.retentions.indices.contains(retentionPopUp.indexOfSelectedItem) else { return }
        trust?.settings.logRetentionDays = Self.retentions[retentionPopUp.indexOfSelectedItem]
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let trust else { return }
        let value = field.integerValue
        guard value > 0 else { NSSound.beep(); refresh(); return }
        var budgets = trust.settings.budgets
        switch field {
        case actionsField: budgets.maxActions = value
        case navigationsField: budgets.navigationsPerMinute = value
        case snapshotField: budgets.snapshotTokens = value
        case timeLimitField: budgets.timeLimitMinutes = value
        default: return
        }
        if budgets != trust.settings.budgets { trust.settings.budgets = budgets }
    }
}

/// One of the two "Default session type" cards: a radio choice drawn as a
/// card, green when Sandbox is chosen, coral-bordered when Borrowed is.
@MainActor
final class SessionTypeCard: NSControl {
    let kind: SessionMode.Kind
    var isSelected = false { didSet { update() } }
    private let titleLabel: NSTextField
    private let body: NSTextField
    private let badge = KeelChip()
    private let selectedLabel = Keel.label("Selected", size: 11.5, weight: .semibold, color: Keel.greenText)
    private let check = Keel.label("✓", size: 11, weight: .bold, color: Keel.chrome)
    private let checkCircle = NSView()

    init(kind: SessionMode.Kind) {
        self.kind = kind
        titleLabel = Keel.label(kind == .sandbox ? "Sandbox" : "Borrowed", size: 14, weight: .semibold)
        body = KeelSettings.note(kind == .sandbox
            ? "Fresh ephemeral profile. None of your cookies or logins. Destroyed when the agent stops."
            : "Agent uses cookies from your profile for one origin, for a limited time you choose. Asked each time.",
            width: (KeelSettings.contentWidth - 12) / 2 - 28, size: 13)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false

        checkCircle.wantsLayer = true
        checkCircle.layer?.cornerRadius = 8
        checkCircle.layer?.backgroundColor = Keel.green.cgColor
        check.alignment = .center
        check.translatesAutoresizingMaskIntoConstraints = false
        checkCircle.addSubview(check)
        checkCircle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            checkCircle.widthAnchor.constraint(equalToConstant: 16), checkCircle.heightAnchor.constraint(equalToConstant: 16),
            check.centerXAnchor.constraint(equalTo: checkCircle.centerXAnchor), check.centerYAnchor.constraint(equalTo: checkCircle.centerYAnchor),
        ])
        badge.set("Higher risk", fill: Keel.coralChip, color: Keel.coralText, dot: Keel.coral)
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true
        badge.setAccessibilityElement(false)

        let trailing = NSStackView(views: kind == .sandbox ? [selectedLabel, checkCircle] : [badge])
        trailing.spacing = 6
        let top = NSStackView(views: [titleLabel, NSView(), trailing])
        top.alignment = .centerY
        let stack = NSStackView(views: [top, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
            top.heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(titleLabel.stringValue + (kind == .borrowed ? ", higher risk" : "") + ". " + body.stringValue)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }

    private func update() {
        let sandbox = kind == .sandbox
        layer?.backgroundColor = (isSelected && sandbox ? Keel.greenChip : Keel.raised).cgColor
        layer?.borderColor = (isSelected ? (sandbox ? Keel.green : Keel.coral) : Keel.inputBorder).cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
        body.textColor = isSelected && sandbox ? Keel.hex(0x9FC9B4) : Keel.muted
        selectedLabel.isHidden = !isSelected
        checkCircle.isHidden = !isSelected
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    private func choose() {
        guard !isSelected else { return }
        isSelected = true
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func mouseDown(with event: NSEvent) { choose() }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { choose() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { choose(); return true }
}
