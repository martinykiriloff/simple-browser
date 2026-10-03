import AppKit
import BrowserKit

/// Settings → Advanced: every keyboard shortcut beside Safari's and Chrome's,
/// and a way to change one: pick the command, click the box, press the keys.
/// A key the Mac keeps, or another command has, is refused and the reason
/// shown; the standard ones every Mac app has cannot be moved.
@MainActor
final class ShortcutsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Told after a change, so the menu bar can follow.
    var onChange: (() -> Void)?
    let table = NSTableView()
    let recorder = ShortcutRecorder()
    let removeButton = NSButton(title: "Remove Key", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let resetAllButton = NSButton(title: "Reset All", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")

    var commands: [ShortcutCommand] { Shortcuts.commands.filter { !$0.fixed } }
    var selected: ShortcutCommand? { commands.indices.contains(table.selectedRow) ? commands[table.selectedRow] : nil }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Advanced"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        for (id, title, width) in [("command", "Command", 200.0), ("key", "Keel", 110.0), ("safari", "Safari", 110.0), ("chrome", "Chrome", 110.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let help = NSTextField(wrappingLabelWithString: "Choose a command, click the box and press the keys you want for it.")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        recorder.onRecord = { [weak self] shortcut in self?.record(shortcut) }
        recorder.setAccessibilityLabel("New shortcut: press the keys")
        removeButton.target = self
        removeButton.action = #selector(removeKey(_:))
        resetButton.target = self
        resetButton.action = #selector(reset(_:))
        resetAllButton.target = self
        resetAllButton.action = #selector(resetAll(_:))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [recorder, removeButton, resetButton, resetAllButton])
        row.spacing = 8
        let stack = NSStackView(views: [heading, help, scroll, row, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 300),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recorder.widthAnchor.constraint(equalToConstant: 150),
            root.widthAnchor.constraint(equalToConstant: 600),
        ])
        view = root
        syncButtons()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        table.reloadData()
    }

    // MARK: - Changes

    func record(_ shortcut: KeyShortcut) {
        guard let command = selected else { statusLabel.stringValue = "Choose a command first."; return }
        if let reason = Shortcuts.refusal(giving: shortcut, to: command.id, overrides: BrowserSettings.shortcutOverrides) {
            statusLabel.stringValue = reason
            recorder.stringValue = ""
            NSSound.beep()
            return
        }
        var overrides = BrowserSettings.shortcutOverrides
        overrides[command.id] = command.shortcut == shortcut ? nil : .some(shortcut)
        BrowserSettings.shortcutOverrides = overrides
        changed()
        statusLabel.stringValue = "“\(command.title)” is now \(shortcut.display)."
    }

    @objc private func removeKey(_ sender: Any?) {
        guard let command = selected else { return }
        var overrides = BrowserSettings.shortcutOverrides
        overrides[command.id] = .some(nil)
        BrowserSettings.shortcutOverrides = overrides
        changed()
        statusLabel.stringValue = "“\(command.title)” has no key."
    }

    @objc private func reset(_ sender: Any?) {
        guard let command = selected else { return }
        var overrides = BrowserSettings.shortcutOverrides
        overrides[command.id] = nil
        BrowserSettings.shortcutOverrides = overrides
        changed()
        statusLabel.stringValue = "“\(command.title)” is back to \(command.shortcut?.display ?? "no key")."
    }

    @objc private func resetAll(_ sender: Any?) {
        BrowserSettings.shortcutOverrides = [:]
        changed()
        statusLabel.stringValue = "Every shortcut is back to its default."
    }

    private func changed() {
        let row = table.selectedRow
        table.reloadData()
        if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
        syncButtons()
        onChange?()
    }

    private func syncButtons() {
        let command = selected
        let changeable = command.map { Shortcuts.refusal(giving: KeyShortcut("f19", []), to: $0.id, overrides: [:]) == nil } ?? false
        recorder.isEnabled = changeable
        removeButton.isEnabled = changeable
        resetButton.isEnabled = changeable && BrowserSettings.shortcutOverrides[command?.id ?? ""] != nil
        resetAllButton.isEnabled = !BrowserSettings.shortcutOverrides.isEmpty
        if let command, !changeable { statusLabel.stringValue = "“\(command.title)” keeps its key: every Mac app has it." }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = commands[row]
        let effective = Shortcuts.effective(overrides: BrowserSettings.shortcutOverrides)
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "command": text = command.title
        case "key": text = (effective[command.id] ?? nil)?.display ?? "—"
        case "safari": text = command.safari
        default: text = command.chrome
        }
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = .init("cell")
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = text
        let changed = tableColumn?.identifier.rawValue == "key" && BrowserSettings.shortcutOverrides[command.id] != nil
        cell.textField?.font = changed ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        statusLabel.stringValue = ""
        syncButtons()
    }
}

/// A box that shows the keys pressed while it has focus.
@MainActor
final class ShortcutRecorder: NSTextField {
    var onRecord: ((KeyShortcut) -> Void)?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        placeholderString = "Click, then press keys"
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { isEnabled }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool { stringValue = "Press keys…"; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { stringValue = ""; return super.resignFirstResponder() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let shortcut = KeyShortcut(event: event) else { return false }
        take(shortcut)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let shortcut = KeyShortcut(event: event) else { super.keyDown(with: event); return }
        take(shortcut)
    }

    /// As if the keys had been pressed.
    func take(_ shortcut: KeyShortcut) {
        stringValue = shortcut.display
        onRecord?(shortcut)
    }
}

extension KeyShortcut {
    static let namedKeyCodes: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 49: "space", 53: "escape", 36: "return", 48: "tab", 51: "delete",
                                                  122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]

    /// The keys of a key event; nil for a modifier on its own.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if let named = Self.namedKeyCodes[event.keyCode] { self.init(named, modifiers); return }
        guard let key = event.charactersIgnoringModifiers, key.count == 1, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // ⇧ with a letter is the capital; with a symbol it is the symbol itself.
        self.init(key.lowercased(), modifiers)
    }

    /// The menu item's form: the character, and the function keys as their own characters.
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        let special: [String: Int] = ["left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey, "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey,
                                      "escape": 0x1b, "return": 0x0d, "tab": 0x09, "delete": 0x08, "space": 0x20]
        if let code = special[key], let scalar = UnicodeScalar(code) { return (String(Character(scalar)), flags) }
        if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...19).contains(number), let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
            return (String(Character(scalar)), flags)
        }
        return (key, flags)
    }

    /// The menu item's key, read back.
    init?(menuItem: NSMenuItem) {
        guard !menuItem.keyEquivalent.isEmpty else { return nil }
        let flags = menuItem.keyEquivalentModifierMask
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let text = menuItem.keyEquivalent
        if let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 {
            let code = Int(scalar.value)
            let names: [Int: String] = [NSLeftArrowFunctionKey: "left", NSRightArrowFunctionKey: "right", NSUpArrowFunctionKey: "up", NSDownArrowFunctionKey: "down",
                                        0x1b: "escape", 0x0d: "return", 0x09: "tab", 0x08: "delete", 0x20: "space"]
            if let name = names[code] { self.init(name, modifiers); return }
            if (NSF1FunctionKey...NSF19FunctionKey).contains(code) { self.init("f\(code - NSF1FunctionKey + 1)", modifiers); return }
        }
        // An upper-case key equivalent means Shift.
        if text != text.lowercased() { modifiers.insert(.shift) }
        self.init(text.lowercased(), modifiers)
    }
}
