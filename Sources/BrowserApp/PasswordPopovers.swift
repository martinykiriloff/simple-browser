import AppKit
import PasswordKit

/// A password field with an eye button: dots until asked, as everywhere else.
@MainActor
final class RevealablePasswordField: NSView, NSTextFieldDelegate {
    private let secure = NSSecureTextField()
    private let plain = NSTextField()
    let eye = NSButton()
    var onChange: (() -> Void)?

    var stringValue: String {
        get { isRevealed ? plain.stringValue : secure.stringValue }
        set { secure.stringValue = newValue; plain.stringValue = newValue }
    }

    private(set) var isRevealed = false

    init() {
        super.init(frame: .zero)
        for field in [secure, plain] {
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setAccessibilityLabel("Password")
            addSubview(field)
        }
        plain.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        plain.isHidden = true
        eye.bezelStyle = .accessoryBarAction
        eye.isBordered = false
        eye.target = self
        eye.action = #selector(toggle(_:))
        eye.translatesAutoresizingMaskIntoConstraints = false
        addSubview(eye)
        NSLayoutConstraint.activate([
            eye.trailingAnchor.constraint(equalTo: trailingAnchor),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalTo: secure.heightAnchor),
        ] + [secure, plain].flatMap { [
            $0.leadingAnchor.constraint(equalTo: leadingAnchor),
            $0.trailingAnchor.constraint(equalTo: eye.leadingAnchor, constant: -4),
            $0.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] })
        setRevealed(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setRevealed(_ revealed: Bool) {
        if revealed { plain.stringValue = secure.stringValue } else { secure.stringValue = plain.stringValue }
        isRevealed = revealed
        plain.isHidden = !revealed
        secure.isHidden = revealed
        eye.image = NSImage(systemSymbolName: revealed ? "eye.slash" : "eye",
                            accessibilityDescription: revealed ? "Hide password" : "Show password")
        eye.toolTip = revealed ? "Hide password" : "Show password"
    }

    @objc private func toggle(_ sender: Any?) { setRevealed(!isRevealed) }

    func controlTextDidChange(_ notification: Notification) { onChange?() }
}

/// "Save password?" / "Update password?", shown from the key button after a
/// sign-in that worked.
@MainActor
final class PasswordPromptViewController: NSViewController {
    enum Mode: Equatable {
        case save
        case update(Credential)
    }

    enum Decision: Equatable {
        case save(username: String, password: String)
        case never
        case notNow
    }

    let mode: Mode
    let origin: String
    private let onDecision: (Decision) -> Void
    let usernameField = NSTextField()
    let passwordField = RevealablePasswordField()
    private(set) var buttons: [NSButton] = []

    init(mode: Mode, origin: String, username: String, password: String, onDecision: @escaping (Decision) -> Void) {
        self.mode = mode
        self.origin = origin
        self.onDecision = onDecision
        super.init(nibName: nil, bundle: nil)
        usernameField.stringValue = username
        passwordField.stringValue = password
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var titleText: String { mode == .save ? "Save password?" : "Update password?" }

    override func loadView() {
        let title = NSTextField(labelWithString: titleText)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let site = NSTextField(labelWithString: CredentialOrigin.site(of: origin))
        site.textColor = .secondaryLabelColor
        site.lineBreakMode = .byTruncatingMiddle

        usernameField.placeholderString = "No username"
        usernameField.setAccessibilityLabel("Username")
        // Which account gets the new password is not up for editing.
        if mode != .save { usernameField.isEditable = false; usernameField.isBordered = false; usernameField.drawsBackground = false }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Username"), usernameField],
            [NSTextField(labelWithString: "Password"), passwordField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 1).yPlacement = .center

        var rows: [NSView] = [title, site, grid]
        if CredentialOrigin.isInsecure(origin) {
            let warning = NSTextField(wrappingLabelWithString:
                "This site is not encrypted. The password you typed crossed the network in the clear.")
            warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            warning.textColor = .systemOrange
            rows.append(warning)
        }

        let primary = NSButton(title: mode == .save ? "Save" : "Update", target: self, action: #selector(save(_:)))
        primary.keyEquivalent = "\r"
        let later = NSButton(title: "Not Now", target: self, action: #selector(notNow(_:)))
        later.keyEquivalent = "\u{1b}"
        buttons = [later, primary]
        if mode == .save {
            buttons.insert(NSButton(title: "Never for This Site", target: self, action: #selector(never(_:))), at: 0)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: (mode == .save ? [buttons[0], spacer] : [spacer]) + [later, primary])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        rows.append(buttonRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(12, after: site)
        stack.setCustomSpacing(14, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 360),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        view = root
    }

    @objc private func save(_ sender: Any?) {
        guard !passwordField.stringValue.isEmpty else { NSSound.beep(); return }
        onDecision(.save(username: usernameField.stringValue, password: passwordField.stringValue))
    }
    @objc private func never(_ sender: Any?) { onDecision(.never) }
    @objc private func notNow(_ sender: Any?) { onDecision(.notNow) }
}

/// What the key button shows when nothing is waiting to be saved: this
/// site's accounts, each one click from being filled in.
@MainActor
final class SiteAccountsViewController: NSViewController {
    private let site: String
    private let credentials: [Credential]
    private let canFill: Bool
    private let onFill: (Credential) -> Void
    private let onManage: () -> Void
    private(set) var fillButtons: [NSButton] = []

    init(site: String, credentials: [Credential], canFill: Bool,
         onFill: @escaping (Credential) -> Void, onManage: @escaping () -> Void) {
        self.site = site
        self.credentials = credentials
        self.canFill = canFill
        self.onFill = onFill
        self.onManage = onManage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: credentials.isEmpty
            ? (site.isEmpty ? "No passwords for this page" : "No passwords saved for \(site)")
            : "Passwords for \(site)")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        var rows: [NSView] = [title]

        for (index, credential) in credentials.enumerated() {
            let name = NSTextField(labelWithString: credential.username.isEmpty ? "No username" : credential.username)
            name.lineBreakMode = .byTruncatingMiddle
            name.textColor = credential.username.isEmpty ? .secondaryLabelColor : .labelColor
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let fill = NSButton(title: "Fill", target: self, action: #selector(fill(_:)))
            fill.tag = index
            fill.controlSize = .small
            fill.isEnabled = canFill
            fill.toolTip = canFill ? "Fill this sign-in into the page" : "This page has no sign-in form"
            fillButtons.append(fill)
            let icon = NSImageView(image: NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [icon, name, spacer, fill])
            row.orientation = .horizontal
            row.spacing = 6
            rows.append(row)
        }

        let manage = NSButton(title: "Manage Passwords…", target: self, action: #selector(manage(_:)))
        manage.bezelStyle = .accessoryBarAction
        rows.append(manage)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 320),
        ] + rows.dropFirst().dropLast().map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32) })
        view = root
    }

    @objc private func fill(_ sender: NSButton) {
        guard credentials.indices.contains(sender.tag) else { return }
        onFill(credentials[sender.tag])
    }

    @objc private func manage(_ sender: Any?) { onManage() }
}
