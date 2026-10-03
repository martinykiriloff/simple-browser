import AppKit
import AgentKit

/// Settings → Developer & MCP (G4-05): the agent server. On or off, its
/// port and endpoint, what it accepts, the tools and prompts it offers, the
/// build's backend, and what agents have been doing.
///
/// Tokens are per agent now (`AgentTrust.clients`), paired and revoked under
/// Agents & permissions; the shared token and its "Require a token" switch
/// are gone. The server always wants a paired client's token.
@MainActor
final class DeveloperSettingsPane: NSViewController, NSTextFieldDelegate {
    var server: () -> AgentServer?
    /// Runs on every refresh, which the server's changes drive, so the
    /// Agents pane can follow the server too.
    var onRefresh: (() -> Void)?

    let enabledSwitch = KeelSwitch(label: "MCP server", target: nil, action: nil)
    let statusChip = KeelChip()
    let statusLabel = KeelSettings.note("", width: 400)
    let endpointLabel = Keel.monoLabel("", color: Keel.text)
    let portField = NSTextField()
    let pairedLabel = Keel.monoLabel("", color: Keel.muted)
    let copyEndpointButton = KeelButton("Copy", kind: .neutral, target: nil, action: nil)
    let agentsButton = KeelButton("Agents & permissions…", kind: .neutral, target: nil, action: nil)
    let copyCommandButton = KeelButton("Copy Claude Code command (stdio)", kind: .neutral, target: nil, action: nil)
    let schemaButton = KeelButton("Open tool schema", kind: .neutral, target: nil, action: nil)
    private let activityScroll = NSTextView.scrollableTextView()
    var activityView: NSTextView { activityScroll.documentView as! NSTextView }

    /// The catalog by what the tools are for; a tool not listed goes last.
    static let toolGroups: [(name: String, tools: [String])] = [
        ("Tabs & navigation", ["list_tabs", "new_tab", "select_tab", "close_tab", "navigate", "wait_for"]),
        ("Reading", ["snapshot", "get_page_content", "screenshot", "inspect_element", "application_data", "devtools_selection"]),
        ("Acting", ["click", "hover", "fill", "fill_form", "type_text", "press_key", "select_option", "scroll", "drag",
                    "upload_files", "handle_dialog", "evaluate", "storage", "emulate"]),
        ("Debugging", ["console_messages", "network_requests", "network_request", "performance_metrics", "diagnose", "run_audit",
                       "mock_network", "heap_snapshot", "devtools"]),
        ("Session", ["session_info", "session_events", "request_human", "page_tools", "call_page_tool"]),
    ]

    static func groupedTools() -> [(name: String, tools: [MCPTool])] {
        var groups = toolGroups.map { group in (name: group.name, tools: group.tools.compactMap(BrowserTools.tool(named:))) }
        let placed = Set(toolGroups.flatMap(\.tools))
        let rest = BrowserTools.all.filter { !placed.contains($0.name) }
        if !rest.isEmpty { groups.append((name: "Other", tools: rest)) }
        return groups.filter { !$0.tools.isEmpty }
    }

    /// A Mac App Store build runs in the App Sandbox; a Developer ID build does not.
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    init(server: @escaping () -> AgentServer? = { nil }) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
        title = "Developer"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    override func loadView() {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged(_:))
        statusChip.heightAnchor.constraint(equalToConstant: 22).isActive = true
        statusChip.setAccessibilityRole(.staticText)
        endpointLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        endpointLabel.isSelectable = true
        endpointLabel.setAccessibilityLabel("Endpoint")
        portField.placeholderString = String(AgentServer.defaultPort)
        portField.delegate = self
        portField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        portField.alignment = .right
        portField.setAccessibilityLabel("Port")
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        copyEndpointButton.target = self
        copyEndpointButton.action = #selector(copyEndpoint(_:))
        copyEndpointButton.setAccessibilityLabel("Copy endpoint")
        agentsButton.target = self
        agentsButton.action = #selector(showAgents(_:))
        copyCommandButton.target = self
        copyCommandButton.action = #selector(copyCommand(_:))
        schemaButton.target = self
        schemaButton.action = #selector(openSchema(_:))

        let endpointBox = KeelPanel(fill: Keel.chrome, border: Keel.inputBorder, radius: 9)
        endpointLabel.translatesAutoresizingMaskIntoConstraints = false
        endpointBox.addSubview(endpointLabel)
        NSLayoutConstraint.activate([
            endpointBox.heightAnchor.constraint(equalToConstant: 32),
            endpointBox.widthAnchor.constraint(equalToConstant: 250),
            endpointLabel.leadingAnchor.constraint(equalTo: endpointBox.leadingAnchor, constant: 12),
            endpointLabel.trailingAnchor.constraint(equalTo: endpointBox.trailingAnchor, constant: -12),
            endpointLabel.centerYAnchor.constraint(equalTo: endpointBox.centerYAnchor),
        ])

        let serverCard = KeelCard(rows: [
            KeelSettings.row(labels: [Keel.label("MCP server", weight: .semibold), statusLabel], accessories: [statusChip, enabledSwitch]),
            KeelSettings.row("Endpoint", detail: "Streamable HTTP, this Mac only.", detailWidth: 210,
                             accessories: [endpointBox, copyEndpointButton]),
            KeelSettings.row("Port", detail: "Takes effect when you press Return. 1024 to 65535.", accessories: [portField]),
            KeelSettings.row("Tokens", detail: "Tokens are per agent: see Agents & permissions. Each one is revocable on its own.",
                             detailWidth: 300, accessories: [pairedLabel, agentsButton]),
        ])

        let setup = NSStackView(views: [copyCommandButton, schemaButton, NSView()])
        setup.spacing = 8
        let commandNote = KeelSettings.note("\(AgentServer.claudeCodeStdioCommand) adds Keel to Claude Code; the launcher asks you to pair on first use.",
                                            size: 11.5, color: Keel.dim)

        activityView.isEditable = false
        activityView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        activityView.textColor = Keel.muted
        activityView.backgroundColor = Keel.chrome
        activityView.textContainerInset = NSSize(width: 8, height: 8)
        activityView.setAccessibilityLabel("Agent activity")
        activityScroll.borderType = .noBorder
        activityScroll.drawsBackground = false
        let activityCard = KeelPanel(fill: Keel.chrome, border: Keel.hairline, radius: 12)
        activityCard.layer?.masksToBounds = true
        activityScroll.translatesAutoresizingMaskIntoConstraints = false
        activityCard.addSubview(activityScroll)
        NSLayoutConstraint.activate([
            activityScroll.leadingAnchor.constraint(equalTo: activityCard.leadingAnchor, constant: 1),
            activityScroll.trailingAnchor.constraint(equalTo: activityCard.trailingAnchor, constant: -1),
            activityScroll.topAnchor.constraint(equalTo: activityCard.topAnchor, constant: 1),
            activityScroll.bottomAnchor.constraint(equalTo: activityCard.bottomAnchor, constant: -1),
            activityCard.heightAnchor.constraint(equalToConstant: 120),
        ])

        let groups = Self.groupedTools()
        let count = groups.reduce(0) { $0 + $1.tools.count }
        let prompts = BrowserTools.prompts

        view = KeelSettings.page(title: "Developer & MCP", subtitle: "Local MCP server, tokens and the tools agents can call", sections: [
            serverCard,
            KeelSettings.section("Set up a client"), setup, commandNote,
            KeelSettings.section("Allowed origins and hosts"), Self.hostsCard(),
            KeelSettings.section("Tools · \(count) available"), Self.toolsGrid(groups),
            KeelSettings.note("Tools shown in green only read. An agent paired with read-only tools sees only those; WebMCP page tools appear when WebMCP is on.",
                              size: 11.5, color: Keel.dim),
            KeelSettings.section("Prompt templates · \(prompts.count)"), Self.promptsCard(prompts),
            KeelSettings.section("Build flavour"), Self.flavours(),
            KeelSettings.note("Tool availability differs between builds. Tools needing the protocol backend report “unsupported” on the Instrumented backend.",
                              size: 11.5, color: Keel.dim),
            KeelSettings.section("Activity"), activityCard,
        ])
        refresh()
    }

    /// What the server accepts (G4-05). Fixed by the server, not settable.
    private static func hostsCard() -> NSView {
        let items: [(on: Bool, title: String, mono: Bool, detail: String)] = [
            (true, "127.0.0.1", true, "loopback IPv4"),
            (true, "localhost", true, "resolves to loopback only"),
            (true, "[::1]", true, "loopback IPv6"),
            (true, "Verify Host header", false, "blocks DNS rebinding"),
            (true, "Reject cross-origin browser requests", false, "Origin must be empty or loopback"),
            (false, "0.0.0.0 and LAN addresses", false, "off · never recommended"),
        ]
        let rows: [NSView] = items.map { item in
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 4
            box.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 16), box.heightAnchor.constraint(equalToConstant: 16)])
            if item.on {
                box.layer?.backgroundColor = Keel.green.cgColor
                let tick = Keel.label("✓", size: 11, weight: .bold, color: Keel.chrome)
                tick.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(tick)
                NSLayoutConstraint.activate([tick.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                                             tick.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
            } else {
                box.layer?.borderColor = Keel.hex(0x3A414D).cgColor
                box.layer?.borderWidth = 1
            }
            let title = item.mono ? Keel.monoLabel(item.title, color: Keel.text) : Keel.label(item.title)
            if item.mono { title.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
            let detail = Keel.label(item.detail, size: 12, color: Keel.dim)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [box, title, detail, spacer])
            row.spacing = 10
            row.alignment = .centerY
            row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
            row.heightAnchor.constraint(equalToConstant: 36).isActive = true
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.staticText)
            row.setAccessibilityLabel("\(item.title), \(item.on ? "allowed" : "not allowed"): \(item.detail)")
            return row
        }
        return KeelCard(rows: rows)
    }

    /// Two columns of cards, one per group, the names in mono chips.
    private static func toolsGrid(_ groups: [(name: String, tools: [MCPTool])]) -> NSView {
        let cardWidth = (KeelSettings.contentWidth - 12) / 2   // at least; wider windows widen the cards
        let cards: [NSView] = groups.map { group in
            let name = Keel.label(group.name, weight: .semibold)
            let count = Keel.monoLabel("\(group.tools.count) tools")
            let header = NSStackView(views: [name, count])
            header.spacing = 8
            let chips = group.tools.map { tool -> NSView in
                let chip = KeelSettings.codeChip(tool.name, color: tool.readOnly ? Keel.greenText : Keel.text,
                                                 border: tool.readOnly ? Keel.greenChip : Keel.inputBorder)
                chip.toolTip = tool.title + (tool.readOnly ? " · read-only" : "")
                return chip
            }
            let stack = NSStackView(views: [header, KeelSettings.flow(chips, width: cardWidth - 28)])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            let card = KeelPanel(fill: Keel.raised, border: Keel.hairline)
            card.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
            ])
            card.setAccessibilityElement(true)
            card.setAccessibilityRole(.group)
            card.setAccessibilityLabel("\(group.name), \(group.tools.count) tools: "
                + group.tools.map { $0.name + ($0.readOnly ? " (read-only)" : "") }.joined(separator: ", "))
            return card
        }
        var rows: [NSView] = []
        for index in stride(from: 0, to: cards.count, by: 2) {
            let pair = Array(cards[index..<min(index + 2, cards.count)])
            let row = NSStackView(views: pair.count == 2 ? pair : pair + [NSView()])
            row.spacing = 12
            row.alignment = .top
            row.distribution = .fillEqually
            if pair.count == 2 { pair[0].heightAnchor.constraint(equalTo: pair[1].heightAnchor).isActive = true }
            rows.append(row)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .width
        grid.spacing = 12
        return grid
    }

    private static func promptsCard(_ prompts: [MCPPrompt]) -> NSView {
        KeelCard(rows: prompts.map { prompt in
            let name = Keel.monoLabel(prompt.name, color: Keel.text)
            name.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let detail = KeelSettings.note(prompt.title + (prompt.arguments.isEmpty ? "" : " · " + prompt.arguments.map(\.name).joined(separator: ", ")),
                                           width: 380)
            let hint = KeelSettings.codeChip("/mcp__keel__\(prompt.name)", color: Keel.muted, border: Keel.menuBorder)
            hint.setAccessibilityElement(true)
            hint.setAccessibilityLabel("In Claude Code: /mcp__keel__\(prompt.name)")
            return KeelSettings.row(labels: [name, detail], accessories: [hint])
        })
    }

    /// Inspector backend (Developer ID) and Instrumented backend (Mac App
    /// Store), and which one this build is.
    private static func flavours() -> NSView {
        let width = (KeelSettings.contentWidth - 12) / 2
        func card(_ title: String, current: Bool, line: String, body: String) -> NSView {
            let chip: NSView
            if current {
                let here = KeelChip()
                here.set("This build", fill: Keel.greenChip, color: Keel.greenText, dot: Keel.green)
                here.heightAnchor.constraint(equalToConstant: 22).isActive = true
                chip = here
            } else {
                chip = KeelSettings.tag("Not in this build", fill: Keel.raised, color: Keel.dim)
            }
            let top = NSStackView(views: [Keel.label(title, size: 14, weight: .semibold), NSView(), chip])
            top.alignment = .centerY
            let stack = NSStackView(views: [top, Keel.monoLabel(line, color: Keel.muted), KeelSettings.note(body, width: width - 28, size: 12.5)])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let panel = KeelPanel(fill: current ? Keel.raised : Keel.surface, border: current ? Keel.inputBorder : Keel.hairline)
            panel.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
                stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -14),
            ])
            panel.setAccessibilityElement(true)
            panel.setAccessibilityRole(.group)
            panel.setAccessibilityLabel("\(title), \(current ? "this build" : "not in this build"). \(line). \(body)")
            return panel
        }
        let appStore = isSandboxed
        let inspector = card("Inspector backend", current: !appStore, line: "Developer ID · notarised · direct download",
                             body: "Talks to WebKit’s Web Inspector protocol. Full network interception, request blocking and header overrides.")
        let instrumented = card("Instrumented backend", current: appStore, line: "Mac App Store · sandboxed",
                                body: "Injected scripts and public WebKit APIs only. No raw protocol access; network tools are read-only.")
        let row = NSStackView(views: [inspector, instrumented])
        row.spacing = 12
        row.alignment = .top
        row.distribution = .fillEqually
        inspector.heightAnchor.constraint(equalTo: instrumented.heightAnchor).isActive = true
        return row
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: - State

    func refresh() {
        onRefresh?()
        guard isViewLoaded else { return }
        enabledSwitch.isOn = AgentServer.isEnabled
        if portField.currentEditor() == nil { portField.stringValue = String(AgentServer.port) }
        let server = server()
        endpointLabel.stringValue = server?.endpointURL ?? "http://127.0.0.1:\(AgentServer.port)\(AgentServer.endpointPath)"
        var listening = false
        switch server?.state ?? .off {
        case .off:
            statusChip.set("Off", fill: Keel.surface, color: Keel.muted, dot: Keel.idle)
            statusLabel.stringValue = "Exposes browser tools to paired agents over local HTTP. The same switch as “Allow agent connections”."
            statusLabel.textColor = Keel.muted
        case .starting:
            statusChip.set("Starting", fill: Keel.amberChip, color: Keel.amberSoft, dot: Keel.amber)
            statusLabel.stringValue = "Starting…"
            statusLabel.textColor = Keel.muted
        case .listening:
            listening = true
            statusChip.set("Running", fill: Keel.greenChip, color: Keel.greenText, dot: Keel.green)
            statusLabel.stringValue = "Exposes browser tools to paired agents over local HTTP. The same switch as “Allow agent connections”."
            statusLabel.textColor = Keel.muted
        case .failed(let reason):
            statusChip.set("Not running", fill: Keel.dangerFill, color: Keel.dangerText, dot: Keel.dangerText)
            statusLabel.stringValue = reason
            statusLabel.textColor = Keel.dangerText
        }
        let paired = server?.trust.clients.filter(\.isActive).count ?? 0
        pairedLabel.stringValue = "\(paired) paired"
        schemaButton.isEnabled = listening
        schemaButton.alphaValue = listening ? 1 : 0.4
        var lines: [String] = []
        if let clients = server?.clients, !clients.isEmpty { lines.append("Connected: " + clients.suffix(4).joined(separator: ", ")) }
        lines.append(contentsOf: server?.activity.suffix(60) ?? [])
        let text = lines.isEmpty ? "No agent has connected yet." : lines.joined(separator: "\n")
        if activityView.string != text {
            activityView.string = text
            activityView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func enabledChanged(_ sender: Any?) {
        AgentServer.isEnabled = enabledSwitch.isOn
        server()?.sync()
        refresh()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === portField else { return }
        if let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) {
            if port != AgentServer.port {
                AgentServer.port = port
                server()?.sync()
            }
        } else {
            NSSound.beep()
        }
        refresh()
    }

    @objc private func copyEndpoint(_ sender: Any?) { copy(endpointLabel.stringValue) }
    @objc private func copyCommand(_ sender: Any?) { copy(AgentServer.claudeCodeStdioCommand) }

    @objc private func openSchema(_ sender: Any?) {
        let port = server()?.activePort ?? AgentServer.port
        if let url = URL(string: "http://127.0.0.1:\(port)/schema") { NSWorkspace.shared.open(url) }
    }

    @objc private func showAgents(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.showAgentSettings(_:)), to: nil, from: sender)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
