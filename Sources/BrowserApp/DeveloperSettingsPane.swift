import AppKit

/// Settings → Developer: the agent server. On or off, its port and token,
/// the lines to paste into an MCP client, and what agents have been doing.
@MainActor
final class DeveloperSettingsPane: NSViewController, NSTextFieldDelegate {
    var server: () -> AgentServer?

    let enabledCheckbox = NSButton(checkboxWithTitle: "Let AI agents control this browser over MCP", target: nil, action: nil)
    let portField = NSTextField()
    let tokenCheckbox = NSButton(checkboxWithTitle: "Require a token", target: nil, action: nil)
    let tokenField = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let copyCommandButton = NSButton(title: "Copy Claude Code Command", target: nil, action: nil)
    let copyConfigButton = NSButton(title: "Copy JSON Config", target: nil, action: nil)
    let copyTokenButton = NSButton(title: "Copy", target: nil, action: nil)
    let regenerateButton = NSButton(title: "New Token", target: nil, action: nil)
    private let activityScroll = NSTextView.scrollableTextView()
    var activityView: NSTextView { activityScroll.documentView as! NSTextView }

    init(server: @escaping () -> AgentServer? = { nil }) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
        title = "Developer"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        portField.placeholderString = String(AgentServer.defaultPort)
        portField.delegate = self
        portField.setAccessibilityLabel("Port")
        tokenCheckbox.target = self
        tokenCheckbox.action = #selector(tokenChanged(_:))
        tokenField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        tokenField.isSelectable = true
        tokenField.lineBreakMode = .byTruncatingMiddle
        tokenField.setAccessibilityLabel("Token")
        copyTokenButton.target = self
        copyTokenButton.action = #selector(copyToken(_:))
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerate(_:))
        copyCommandButton.target = self
        copyCommandButton.action = #selector(copyCommand(_:))
        copyConfigButton.target = self
        copyConfigButton.action = #selector(copyConfig(_:))
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true

        let explanation = NSTextField(wrappingLabelWithString: """
        Agents such as Claude Code, Cursor and Codex can open tabs, read pages as an accessibility tree, click and type, \
        and see what DevTools sees: console, network with bodies, styles, performance. They act in your profile, signed in \
        as you. The server listens on this Mac only.
        """)
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor

        let portTitle = NSTextField(labelWithString: "Port:")
        let tokenTitle = NSTextField(labelWithString: "Token:")
        let tokenRow = NSStackView(views: [tokenField, copyTokenButton, regenerateButton])
        tokenRow.spacing = 6
        let grid = NSGridView(views: [
            [portTitle, portField],
            [NSGridCell.emptyContentView, tokenCheckbox],
            [tokenTitle, tokenRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.rowAlignment = .firstBaseline

        let setupTitle = NSTextField(labelWithString: "Add it to a client:")
        let setupButtons = NSStackView(views: [copyCommandButton, copyConfigButton])
        setupButtons.spacing = 8

        activityView.isEditable = false
        activityView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        activityView.textContainerInset = NSSize(width: 4, height: 4)
        activityView.setAccessibilityLabel("Agent activity")
        activityScroll.borderType = .bezelBorder
        let activityTitle = NSTextField(labelWithString: "Activity:")

        let stack = NSStackView(views: [enabledCheckbox, explanation, grid, statusLabel, setupTitle, setupButtons, activityTitle, activityScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: statusLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 560),
            explanation.widthAnchor.constraint(equalToConstant: 520),
            portField.widthAnchor.constraint(equalToConstant: 80),
            tokenField.widthAnchor.constraint(equalToConstant: 300),
            statusLabel.widthAnchor.constraint(equalToConstant: 520),
            activityScroll.widthAnchor.constraint(equalToConstant: 520),
            activityScroll.heightAnchor.constraint(equalToConstant: 72),
        ])
        view = stack
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        enabledCheckbox.state = AgentServer.isEnabled ? .on : .off
        if portField.currentEditor() == nil { portField.stringValue = String(AgentServer.port) }
        tokenCheckbox.state = AgentServer.requiresToken ? .on : .off
        tokenField.stringValue = AgentServer.requiresToken ? AgentServer.token : "Not required — any program on this Mac can connect"
        copyTokenButton.isEnabled = AgentServer.requiresToken
        regenerateButton.isEnabled = AgentServer.requiresToken
        let server = server()
        switch server?.state ?? .off {
        case .off: statusLabel.stringValue = "Off."
        case .starting: statusLabel.stringValue = "Starting…"
        case .listening: statusLabel.stringValue = "Listening at \(server?.endpointURL ?? "") (MCP, Streamable HTTP)."
        case .failed(let reason): statusLabel.stringValue = "Not running: \(reason)"
        }
        copyCommandButton.isEnabled = server != nil
        copyConfigButton.isEnabled = server != nil
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
        AgentServer.isEnabled = enabledCheckbox.state == .on
        server()?.sync()
        refresh()
    }

    @objc private func tokenChanged(_ sender: Any?) {
        AgentServer.requiresToken = tokenCheckbox.state == .on
        server()?.sync()
        refresh()
    }

    @objc private func regenerate(_ sender: Any?) {
        AgentServer.regenerateToken()
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

    @objc private func copyToken(_ sender: Any?) { copy(AgentServer.token) }
    @objc private func copyCommand(_ sender: Any?) { if let server = server() { copy(server.claudeCodeCommand) } }
    @objc private func copyConfig(_ sender: Any?) { if let server = server() { copy(server.clientConfigJSON) } }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
