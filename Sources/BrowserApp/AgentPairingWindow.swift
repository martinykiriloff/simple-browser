import AppKit
import AgentKit

/// Pairing (G2-01) and the client's grants (G2-02): a client that asked over
/// `/pair`, a client the person sets up by hand, and the grants of a client
/// that is already paired (Settings → Agents opens those).
@MainActor
final class AgentPairingController {
    static let shared = AgentPairingController()

    /// Open dialogs: "manual", "request-<id>", "grants-<client id>".
    private var dialogs: [String: AgentDialog] = [:]

    fileprivate static let pairWidth: CGFloat = 520
    fileprivate static let grantsWidth: CGFloat = 600

    // MARK: - Entry points

    /// Agent → Pair a New Agent…: the person sets up a client by hand.
    func showManualPairing(trust: AgentTrust, server: AgentServer) {
        let dialog = dialog(for: "manual", title: "Pair an Agent", width: Self.pairWidth)
        ManualPairingFlow(dialog: dialog, trust: trust, server: server).start()
    }

    /// A client asked to pair over `/pair`.
    func showRequest(_ pending: AgentTrust.PendingPairing, trust: AgentTrust, server: AgentServer) {
        let dialog = dialog(for: "request-" + pending.request.id, title: "Pair an Agent", width: Self.pairWidth)
        dialog.window.level = .floating
        RequestPairingFlow(dialog: dialog, pending: pending, trust: trust, server: server).start()
    }

    /// The grants of a paired client (G2-02), to change them or revoke it.
    func showGrants(clientID: String, trust: AgentTrust) {
        guard let client = trust.clients.first(where: { $0.id == clientID }), client.isActive else { return }
        let dialog = dialog(for: "grants-" + clientID, title: "Agent Grants", width: Self.grantsWidth)
        Self.showGrants(of: client, in: dialog, trust: trust)
    }

    // MARK: - Dialogs

    private func dialog(for key: String, title: String, width: CGFloat) -> AgentDialog {
        if let open = dialogs[key] { open.close() }
        let dialog = AgentDialog(title: title, width: width)
        dialog.onClose = { [weak self] in self?.dialogs[key] = nil }
        dialogs[key] = dialog
        NSApp.activate()
        return dialog
    }

    /// The grants step for a client that is paired already.
    fileprivate static func showGrants(of client: PairedClient, in dialog: AgentDialog, trust: AgentTrust) {
        let name = AgentServer.friendlyName(client.name)
        var detail = "token \(ClientRegistry.tokenPrefix)…\(client.tokenHint) · paired \(Keel.clock(client.pairedAt))"
        if let used = client.lastUsed { detail += " · last used \(Keel.clock(used))" }
        let form = AgentGrantsForm(grants: AgentGrants(client: client), width: grantsWidth)
        form.onResize = { [weak dialog] in dialog?.refit() }
        let revoke = KeelButton("Revoke", kind: .danger, target: nil, action: nil)
        revoke.setAccessibilityLabel("Revoke \(name)")
        revoke.onPress = { [weak dialog] in
            guard let dialog else { return }
            let alert = NSAlert()
            alert.messageText = "Revoke \(name)?"
            alert.informativeText = "Its token is deleted from the Keychain and its sessions end. It cannot reconnect without pairing again."
            alert.addButton(withTitle: "Revoke")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            alert.beginSheetModal(for: dialog.window) { response in
                guard response == .alertFirstButtonReturn else { return }
                MainActor.assumeIsolated {
                    trust.revoke(client.id)
                    dialog.close()
                }
            }
        }
        let save = KeelButton("Save", kind: .primary, target: nil, action: nil)
        save.keyEquivalent = "\r"
        save.onPress = { [weak dialog, weak form] in
            guard let form else { return }
            let grants = form.grants
            trust.updateClient(client.id) { grants.apply(to: &$0) }
            dialog?.close()
        }
        form.defaultButton = save
        let body = form.build(header: AgentDialog.doneHeader("\(name) is paired", detail: detail),
                              footer: AgentDialog.footer(leading: [revoke], trailing: [save], width: grantsWidth - 48))
        dialog.onTrustChange = { [weak dialog] in
            // Revoked elsewhere (Stop & revoke, Settings): nothing left to edit.
            if trust.clients.first(where: { $0.id == client.id })?.isActive != true { dialog?.close() }
        }
        dialog.show(body, width: grantsWidth)
    }
}

// MARK: - Grants

/// What a client may do, as the grants step edits it.
struct AgentGrants {
    var mode: SessionMode.Kind
    var origins: [String]
    var policy: ApprovalPolicy
    var budgets: Budgets
    var scope: ToolScope

    init(client: PairedClient) {
        mode = client.defaultMode
        origins = client.allowedOrigins
        policy = client.approvalPolicy
        budgets = client.budgets
        scope = client.scope
    }

    @MainActor
    init(settings: AgentTrust.Settings, scope: ToolScope = .all) {
        mode = settings.defaultMode
        origins = []
        policy = settings.policy
        budgets = settings.budgets
        self.scope = scope
    }

    func apply(to client: inout PairedClient) {
        client.defaultMode = mode
        client.allowedOrigins = origins
        client.approvalPolicy = policy
        client.budgets = budgets
        client.scope = scope
    }
}

/// The body of G2-02: session type, tools, allowed origins, the approval
/// policy and the budgets. The caller adds the header and the buttons.
@MainActor
final class AgentGrantsForm: NSObject, NSTextFieldDelegate {
    private(set) var grants: AgentGrants
    private let width: CGFloat
    private var inner: CGFloat { width - 48 }
    /// The window should take the form's new height.
    var onResize: (() -> Void)?
    /// Return adds an origin while one is being typed, and saves otherwise.
    weak var defaultButton: NSButton?

    private var modeRows: [SessionMode.Kind: KeelOptionRow] = [:]
    private var policyRows: [ApprovalPolicy: KeelOptionRow] = [:]
    private let originsBox = NSStackView()
    private var originInput: (box: NSView, field: NSTextField)?
    private var steppers: [String: KeelStepper] = [:]
    private let originsNote = Keel.label("", size: 12, color: Keel.dim)

    init(grants: AgentGrants, width: CGFloat) {
        self.grants = grants
        self.width = width
        super.init()
    }

    func build(header: NSView, footer: NSView) -> NSView {
        // Session type: two cards side by side.
        let half = (inner - 8) / 2
        let sandbox = KeelOptionRow(title: "Sandbox", subtitle: "Empty, ephemeral profile. No cookies or logins of yours. Destroyed on stop.",
                                    indicator: .radio, accent: .sandbox)
        let borrowed = KeelOptionRow(title: "Borrowed", subtitle: "Uses your signed-in sessions on named origins, for a limited time.",
                                     indicator: .radio, accent: .borrowed)
        modeRows = [.sandbox: sandbox, .borrowed: borrowed]
        for (kind, row) in modeRows {
            row.setTextWidth(half - 64)
            row.onToggle = { [weak self] in self?.grants.mode = kind; self?.sync() }
        }
        let modes = NSStackView(views: [sandbox, borrowed])
        modes.distribution = .fillEqually
        modes.alignment = .top
        modes.spacing = 8

        let scope = KeelSegmented(["All tools", "Read-only tools"], selected: grants.scope == .all ? 0 : 1,
                                  fill: Keel.inputBorder, selectedText: Keel.text, label: "Tools")
        scope.onChange = { [weak self] index in self?.grants.scope = index == 0 ? .all : .readOnly }

        // Allowed origins: removable chips, and a field to add one.
        originsBox.orientation = .vertical
        originsBox.alignment = .leading
        originsBox.spacing = 8
        rebuildOrigins()

        let policies: [(ApprovalPolicy, String)] = [
            (.askEveryTime, "Payments, sends, deletes and file uploads show an approval card."),
            (.askOncePerOrigin, "Approve a kind of action once, then it runs on that origin until the session ends."),
            (.allowWithinSandbox, "No prompts. Only safe because nothing here is yours. Borrowed sessions still ask."),
        ]
        var policyViews: [NSView] = []
        for (policy, subtitle) in policies {
            let row = KeelOptionRow(title: policy.label, subtitle: subtitle, indicator: .radio, accent: .plain)
            row.setTextWidth(inner - 64)
            row.onToggle = { [weak self] in self?.grants.policy = policy; self?.sync() }
            policyRows[policy] = row
            policyViews.append(row)
        }

        let budgets = NSStackView(views: [
            budget("Max actions", key: "actions"), budget("Snapshot tokens", key: "tokens"), budget("Expires in", key: "time"),
        ])
        budgets.distribution = .fillEqually
        budgets.spacing = 10

        let separator = Keel.separator()
        let body = AgentDialog.column([
            header,
            AgentDialog.section("Session type", [modes], width: inner),
            AgentDialog.section("Tools", [scope], width: inner),
            AgentDialog.section("Allowed origins", [originsBox, originsNote], width: inner),
            AgentDialog.section("Consequential actions", policyViews, width: inner),
            AgentDialog.section("Budgets", [budgets], width: inner),
            separator,
            footer,
        ], width: width)
        body.setCustomSpacing(2, after: separator)
        sync()
        return body
    }

    // MARK: Origins

    private func rebuildOrigins() {
        originsBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var chips: [NSView] = grants.origins.map { origin in
            KeelTokenChip(origin) { [weak self] in
                guard let self else { return }
                self.grants.origins.removeAll { $0 == origin }
                self.rebuildOrigins()
            }
        }
        let add = NSButton(title: "+ Add origin", target: nil, action: nil)
        add.isBordered = false
        add.attributedTitle = NSAttributedString(string: "+ Add origin", attributes: [.font: Keel.font(12, .medium), .foregroundColor: Keel.muted])
        add.setAccessibilityLabel("Add an allowed origin")
        KeelButtonActions.attach(add) { [weak self] in self?.showOriginInput() }
        chips.append(add)
        originsBox.addArrangedSubview(Keel.wrapping(chips, width: inner))
        if let input = originInput { originsBox.addArrangedSubview(input.box) }
        originsNote.stringValue = grants.origins.isEmpty
            ? "No allowlist: the agent may open any site. Add origins to keep it to them."
            : "Navigation outside these origins is blocked and logged."
        onResize?()
    }

    private func showOriginInput() {
        if originInput == nil {
            let input = Keel.inputField(placeholder: "shop.example.com or *.example.com", mono: true)
            input.field.delegate = self
            input.field.target = self
            input.field.action = #selector(addOrigin(_:))
            input.box.widthAnchor.constraint(equalToConstant: inner).isActive = true
            originInput = input
            rebuildOrigins()
        }
        originInput?.field.window?.makeFirstResponder(originInput?.field)
    }

    @objc private func addOrigin(_ sender: NSTextField) {
        let origin = Origin.normalize(sender.stringValue)
        guard !origin.isEmpty else { return }
        if !grants.origins.contains(origin) { grants.origins.append(origin) }
        sender.stringValue = ""
        rebuildOrigins()
        sender.window?.makeFirstResponder(sender)
    }

    func controlTextDidChange(_ notification: Notification) {
        let typing = !(originInput?.field.stringValue.isEmpty ?? true)
        defaultButton?.keyEquivalent = typing ? "" : "\r"
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        defaultButton?.keyEquivalent = "\r"
    }

    // MARK: Budgets

    private func budget(_ title: String, key: String) -> NSView {
        let stepper = KeelStepper(label: title)
        stepper.onStep = { [weak self] direction in self?.step(key, direction) }
        steppers[key] = stepper
        let stack = NSStackView(views: [Keel.sectionLabel(title), stepper])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stepper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func step(_ key: String, _ direction: Int) {
        var budgets = grants.budgets
        switch key {
        case "actions":
            let step = budgets.maxActions + (direction < 0 ? -1 : 0) < 100 ? 10 : 50
            budgets.maxActions = min(5_000, max(10, budgets.maxActions + direction * step))
        case "tokens":
            budgets.snapshotTokens = min(64_000, max(2_000, budgets.snapshotTokens + direction * 2_000))
        default:
            let minutes = budgets.timeLimitMinutes
            let step = minutes + (direction < 0 ? -1 : 0) < 60 ? 15 : 60
            budgets.timeLimitMinutes = min(24 * 60, max(15, minutes + direction * step))
        }
        grants.budgets = budgets
        sync()
    }

    // MARK: State

    private func sync() {
        for (kind, row) in modeRows { row.isOn = grants.mode == kind }
        for (policy, row) in policyRows { row.isOn = grants.policy == policy }
        let budgets = grants.budgets
        steppers["actions"]?.set("\(budgets.maxActions)", unit: "actions")
        steppers["tokens"]?.set(budgets.snapshotTokens % 1000 == 0 ? "\(budgets.snapshotTokens / 1000)k" : "\(budgets.snapshotTokens)", unit: "tokens")
        let minutes = budgets.timeLimitMinutes
        if minutes < 60 {
            steppers["time"]?.set("\(minutes)", unit: "min")
        } else if minutes % 60 == 0 {
            steppers["time"]?.set("\(minutes / 60)", unit: minutes == 60 ? "hour" : "hours")
        } else {
            steppers["time"]?.set(String(format: "%.1f", Double(minutes) / 60), unit: "hours")
        }
    }
}

// MARK: - A client asked to pair (G2-01)

/// Code, countdown and endpoint; then the grants; then the answer.
@MainActor
private final class RequestPairingFlow {
    private let dialog: AgentDialog
    private let pending: AgentTrust.PendingPairing
    private let trust: AgentTrust
    private let server: AgentServer
    private var answered = false
    private let countdowns: [NSTextField] = [Keel.monoLabel(""), Keel.monoLabel("")]
    private var inner: CGFloat { dialog.width - 48 }

    init(dialog: AgentDialog, pending: AgentTrust.PendingPairing, trust: AgentTrust, server: AgentServer) {
        self.dialog = dialog
        self.pending = pending
        self.trust = trust
        self.server = server
    }

    private var name: String { AgentServer.friendlyName(pending.request.clientName) }

    func start() {
        // The flow lives as long as its window.
        dialog.onTick = { [self] in tick() }
        dialog.onTrustChange = { [self] in
            // Answered elsewhere (Stop & revoke, the request timed out).
            if !answered, !trust.pairings.contains(where: { $0 === pending }) { dialog.close() }
        }
        let previous = dialog.onClose
        dialog.onClose = { [self] in
            previous?()
            if !answered { answered = true; trust.answer(pending, approve: false) }
        }
        tick()
        showCode()
    }

    private func tick() {
        let left = max(0, Int(pending.request.expires.timeIntervalSinceNow.rounded(.up)))
        for label in countdowns { label.stringValue = String(format: "expires in %02d:%02d", left / 60, left % 60) }
        if left == 0, !answered { dialog.close() }
    }

    private func showCode() {
        let request = pending.request
        let width = inner

        let icon = Keel.mark(Keel.amber, size: 16, radius: 4)
        let clientName = Keel.label("\(name) · on this Mac", size: 13)
        clientName.lineBreakMode = .byTruncatingTail
        clientName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detected = KeelChip()
        detected.set("Detected", fill: Keel.greenChip, color: Keel.greenText, dot: Keel.green)
        let client = row([icon, clientName, NSView(), detected], height: 40)
        var facts = [request.clientName + (request.clientVersion.map { " " + $0 } ?? "")]
        if let pid = request.processID { facts.append("pid \(pid)") }
        facts.append("connected from \(pending.remote)")
        let factsLabel = Keel.monoLabel(facts.joined(separator: " · "))

        let codeTitle = Keel.sectionLabel("Pairing code")
        let code = Keel.label(request.displayCode, size: 44, weight: .semibold)
        code.font = NSFont.monospacedSystemFont(ofSize: 44, weight: .semibold)
        code.attributedStringValue = NSAttributedString(string: request.displayCode, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 44, weight: .semibold), .foregroundColor: Keel.text, .kern: 3.5,
        ])
        code.setAccessibilityLabel("Pairing code \(request.code.map(String.init).joined(separator: " "))")
        let codeStack = NSStackView(views: [codeTitle, code, countdowns[0]])
        codeStack.orientation = .vertical
        codeStack.alignment = .centerX
        codeStack.spacing = 8
        let codeBox = KeelPanel(fill: Keel.chrome, border: Keel.hairline, radius: 12)
        AgentDialog.embed(codeStack, in: codeBox, insets: NSEdgeInsets(top: 18, left: 0, bottom: 18, right: 0))

        let confirm = NSMutableAttributedString(string: "Confirm that the agent shows the same code ",
                                                attributes: [.font: Keel.font(13), .foregroundColor: Keel.approvalBody])
        confirm.append(NSAttributedString(string: request.displayCode, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Keel.amberSoft,
        ]))
        confirm.append(NSAttributedString(string: ". If it shows a different code, cancel: something else is trying to connect.",
                                          attributes: [.font: Keel.font(13), .foregroundColor: Keel.approvalBody]))
        let confirmLabel = NSTextField(wrappingLabelWithString: "")
        confirmLabel.attributedStringValue = confirm
        confirmLabel.preferredMaxLayoutWidth = width - 24
        let confirmBox = KeelPanel(fill: Keel.approvalBackground, border: Keel.approvalBorder, radius: 9)
        AgentDialog.embed(confirmLabel, in: confirmBox, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))

        let endpoint = KeelCopyField("127.0.0.1:\(server.activePort)\(AgentServer.endpointPath)", note: "Local only", label: "Endpoint")

        let cancel = KeelButton("Cancel", kind: .neutral, target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        cancel.onPress = { [weak self] in self?.dialog.close() }
        let pair = KeelButton("Pair", kind: .primary, target: nil, action: nil)
        pair.keyEquivalent = "\r"
        pair.setAccessibilityLabel("Pair \(name)")
        pair.onPress = { [weak self] in self?.showGrants() }

        let body = AgentDialog.column([
            AgentDialog.heading("Pair an agent", "Connect an MCP client to Keel. It gets its own token and starts in an isolated Sandbox session.",
                                width: width),
            AgentDialog.section("Client", [client, factsLabel], width: width),
            codeBox,
            confirmBox,
            AgentDialog.section("Endpoint", [endpoint], width: width),
            AgentDialog.footer(note: "The token is stored in your macOS Keychain, never in a file.", trailing: [cancel, pair], width: width),
        ], width: dialog.width, spacing: 18)
        dialog.show(body)
    }

    /// Step 2: the grants apply before the client ever holds a token.
    private func showGrants() {
        let width = AgentPairingController.grantsWidth
        let grantsDialog = dialog
        let form = AgentGrantsForm(grants: AgentGrants(settings: trust.settings), width: width)
        form.onResize = { [weak grantsDialog] in grantsDialog?.refit() }
        let cancel = KeelButton("Cancel", kind: .neutral, target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        cancel.onPress = { [weak self] in self?.dialog.close() }
        let pair = KeelButton("Pair", kind: .primary, target: nil, action: nil)
        pair.keyEquivalent = "\r"
        pair.setAccessibilityLabel("Pair \(name) with these grants")
        pair.onPress = { [weak self, weak form] in
            guard let self, let form else { return }
            self.approve(with: form.grants)
        }
        form.defaultButton = pair
        let header = NSStackView(views: [
            Keel.label("Choose what \(name) may do", size: 17, weight: .semibold),
            countdownLine(),
        ])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        let body = form.build(header: header, footer: AgentDialog.footer(trailing: [cancel, pair], width: width - 48))
        Keel.setDialogContent(body, of: dialog.window, width: width)
    }

    private func countdownLine() -> NSView {
        let code = Keel.monoLabel("code \(pending.request.displayCode) ·")
        let stack = NSStackView(views: [code, countdowns[1], Keel.monoLabel("· this Mac")])
        stack.spacing = 4
        return stack
    }

    private func approve(with grants: AgentGrants) {
        guard !answered else { return }
        guard !pending.request.isExpired() else { dialog.close(); return }
        answered = true
        let before = Set(trust.clients.map(\.id))
        trust.answer(pending, approve: true, scope: grants.scope)
        guard let client = trust.clients.first(where: { !before.contains($0.id) }) else { dialog.close(); return }
        trust.updateClient(client.id) { grants.apply(to: &$0) }
        dialog.onTick = nil
        showPaired(trust.clients.first { $0.id == client.id } ?? client)
    }

    private func showPaired(_ client: PairedClient) {
        let width = AgentPairingController.grantsWidth
        let done = KeelButton("Done", kind: .primary, target: nil, action: nil)
        done.keyEquivalent = "\r"
        done.onPress = { [weak self] in self?.dialog.close() }
        let body = AgentDialog.column([
            AgentDialog.doneHeader("\(name) is paired",
                                   detail: "token \(ClientRegistry.tokenPrefix)…\(client.tokenHint) · paired \(Keel.clock(client.pairedAt)) · this Mac"),
            AgentDialog.text("\(name) received its token and starts in a \(client.defaultMode == .sandbox ? "Sandbox" : "Borrowed") session. "
                             + "You can change its grants or revoke it in Settings → Agents, and stop every agent with ⇧⌘.", width: width - 48),
            AgentDialog.footer(trailing: [done], width: width - 48),
        ], width: width)
        Keel.setDialogContent(body, of: dialog.window, width: width)
    }

    private func row(_ views: [NSView], height: CGFloat) -> NSView {
        let box = KeelPanel(fill: Keel.raised, border: Keel.inputBorder, radius: 9)
        let stack = NSStackView(views: views)
        stack.spacing = 10
        AgentDialog.embed(stack, in: box, insets: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8))
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        return box
    }
}

// MARK: - Pairing by hand

/// Which client, which tools; then the command or config to paste.
@MainActor
private final class ManualPairingFlow {
    private enum Kind: Int, CaseIterable {
        case claudeCode, cursor, codex, vsCode, other
        var title: String { ["Claude Code", "Cursor", "Codex", "VS Code", "Other"][rawValue] }
    }

    private let dialog: AgentDialog
    private let trust: AgentTrust
    private let server: AgentServer
    private var kind = Kind.claudeCode
    private var scope = ToolScope.all
    private let nameInput = Keel.inputField(placeholder: "Client name, e.g. Windsurf")
    private var scopeRows: [ToolScope: KeelOptionRow] = [:]
    private let serverNote = NSStackView()
    private var lastServerState: AgentServer.State?
    private var inner: CGFloat { AgentPairingController.pairWidth - 48 }

    init(dialog: AgentDialog, trust: AgentTrust, server: AgentServer) {
        self.dialog = dialog
        self.trust = trust
        self.server = server
    }

    func start() {
        dialog.onTick = { [self] in syncServerNote() }
        showChoice()
    }

    private func showChoice() {
        let width = inner
        let kinds = KeelSegmented(Kind.allCases.map(\.title), selected: kind.rawValue, fill: Keel.inputBorder, selectedText: Keel.text,
                                  label: "Client")
        kinds.onChange = { [weak self] index in
            guard let self else { return }
            self.kind = Kind(rawValue: index) ?? .other
            self.nameInput.box.isHidden = self.kind != .other
            self.dialog.refit()
            if self.kind == .other { self.dialog.window.makeFirstResponder(self.nameInput.field) }
        }
        nameInput.box.isHidden = kind != .other

        var rows: [NSView] = []
        for (value, title, subtitle) in [
            (ToolScope.all, "All tools", "Navigate, click, type and read pages. Payments, sends, deletes and uploads still ask you."),
            (ToolScope.readOnly, "Read-only tools", "Snapshots, page content, console and network. Nothing that changes a page."),
        ] {
            let row = KeelOptionRow(title: title, subtitle: subtitle, indicator: .radio, accent: .plain)
            row.setTextWidth(width - 64)
            row.onToggle = { [weak self] in self?.scope = value; self?.syncScope() }
            scopeRows[value] = row
            rows.append(row)
        }
        syncScope()

        serverNote.orientation = .vertical
        serverNote.alignment = .leading
        syncServerNote(force: true)

        let cancel = KeelButton("Cancel", kind: .neutral, target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        cancel.onPress = { [weak self] in self?.dialog.close() }
        let pair = KeelButton("Pair", kind: .primary, target: nil, action: nil)
        pair.keyEquivalent = "\r"
        pair.onPress = { [weak self] in self?.pair() }

        let body = AgentDialog.column([
            AgentDialog.heading("Pair an agent", "Give an MCP client a token of its own. It starts in an isolated Sandbox session, and you can revoke it on its own.",
                                width: width),
            AgentDialog.section("Client", [kinds, nameInput.box], width: width),
            AgentDialog.section("Tools", rows, width: width),
            serverNote,
            AgentDialog.footer(note: "The token is stored in your macOS Keychain, never in a file.", trailing: [cancel, pair], width: width),
        ], width: AgentPairingController.pairWidth, spacing: 18)
        dialog.show(body)
    }

    private func syncScope() {
        for (value, row) in scopeRows { row.isOn = value == scope }
    }

    /// Clients cannot connect while the server is off: say so, with the switch.
    private func syncServerNote(force: Bool = false) {
        guard force || lastServerState != server.state else { return }
        lastServerState = server.state
        serverNote.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let message: String
        switch server.state {
        case .listening:
            serverNote.isHidden = true
            if !force { dialog.refit() }
            return
        case .starting: message = "The agent server is starting…"
        case .off: message = "The agent server is off, so clients cannot connect yet. Turn it on here or in Settings → Developer."
        case .failed(let reason): message = "The agent server could not start: \(reason)"
        }
        serverNote.isHidden = false
        let text = AgentDialog.text(message, width: inner - 160, size: 12, color: Keel.approvalBody)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [text]
        if server.state != .starting {
            let turnOn = Keel.miniButton("Turn on server", kind: .allow) { [weak self] in
                AgentServer.isEnabled = true
                self?.server.sync()
                self?.syncServerNote()
            }
            views += [NSView(), turnOn]
        }
        let stack = NSStackView(views: views)
        stack.spacing = 10
        let box = KeelPanel(fill: Keel.approvalBackground, border: Keel.approvalBorder, radius: 9)
        AgentDialog.embed(stack, in: box, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10))
        serverNote.addArrangedSubview(box)
        box.widthAnchor.constraint(equalToConstant: inner).isActive = true
        if !force { dialog.refit() }
    }

    private func pair() {
        var name = kind.title
        if kind == .other {
            name = nameInput.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                NSSound.beep()
                dialog.window.makeFirstResponder(nameInput.field)
                return
            }
        }
        let paired = trust.pair(name: name, scope: scope)
        showSetup(paired.client, token: paired.token)
    }

    /// The command (Claude Code) or the config (everyone else) with the token.
    private func showSetup(_ client: PairedClient, token: String) {
        let width = inner
        let name = AgentServer.friendlyName(client.name)
        let primary: NSView
        let alternative: NSView
        if kind == .claudeCode {
            primary = AgentDialog.section("Run this in your terminal", [
                KeelCopyField(server.claudeCodeCommand(token: token), wraps: true, label: "Claude Code command", width: width),
            ], width: width)
            alternative = AgentDialog.section("Or use the stdio launcher, which pairs by itself", [
                KeelCopyField(AgentServer.claudeCodeStdioCommand, label: "stdio command"),
            ], width: width)
        } else {
            primary = AgentDialog.section("Add this to \(name)’s MCP settings", [
                KeelCopyField(server.clientConfigJSON(token: token), wraps: true, label: "\(name) MCP configuration", width: width),
            ], width: width)
            alternative = AgentDialog.section("Clients that start servers over stdio can run the launcher instead", [
                KeelCopyField("keel mcp", label: "stdio launcher"),
            ], width: width)
        }
        let grants = KeelButton("Edit Grants…", kind: .neutral, target: nil, action: nil)
        grants.onPress = { [weak self] in
            guard let self, let current = self.trust.clients.first(where: { $0.id == client.id }) else { return }
            self.dialog.onTick = nil
            AgentPairingController.showGrants(of: current, in: self.dialog, trust: self.trust)
        }
        let done = KeelButton("Done", kind: .primary, target: nil, action: nil)
        done.keyEquivalent = "\r"
        done.onPress = { [weak self] in self?.dialog.close() }

        let body = AgentDialog.column([
            AgentDialog.doneHeader("\(name) is paired",
                                   detail: "token \(ClientRegistry.tokenPrefix)…\(client.tokenHint) · \(client.scope.label) · paired \(Keel.clock(client.pairedAt))"),
            primary,
            alternative,
            serverNote,
            AgentDialog.footer(note: "The token is stored in your macOS Keychain, never in a file.", leading: [grants], trailing: [done], width: width),
        ], width: AgentPairingController.pairWidth, spacing: 18)
        dialog.show(body)
    }
}
