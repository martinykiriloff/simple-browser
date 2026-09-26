import AppKit
import UniformTypeIdentifiers
import PasswordKit

/// Settings → Passwords: every saved sign-in, searchable, with the two
/// switches that govern saving and filling.
///
/// Looking at the list is free. Anything that reveals a password -- show,
/// copy, edit, export -- first confirms it is the Mac's owner asking.
@MainActor
final class PasswordsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    /// The vault of the profile whose window is in front. Swapped rather than
    /// fixed: Settings is one window for the app, and showing one profile's
    /// passwords while another's window is in front would be a leak.
    var service: PasswordService {
        didSet {
            guard service !== oldValue else { return }
            revealed = [:]
            if isViewLoaded { reload() }
        }
    }
    /// Says whose passwords these are. Empty with a single profile.
    let profileLabel = NSTextField(labelWithString: "")
    let offerCheckbox = NSButton(checkboxWithTitle: "Offer to save passwords", target: nil, action: nil)
    let autofillCheckbox = NSButton(checkboxWithTitle: "Fill sign-in forms automatically", target: nil, action: nil)
    let searchField = NSSearchField()
    let tableView = NSTableView()
    let countLabel = NSTextField(labelWithString: "")
    let addButton = NSButton(title: "Add…", target: nil, action: nil)
    let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let showButton = NSButton(title: "Show", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy Password", target: nil, action: nil)
    let checkupButton = NSButton(title: "Checkup…", target: nil, action: nil)
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)

    private var all: [Credential] = []
    private(set) var visible: [Credential] = []
    /// Passwords currently shown in the clear, by entry. Emptied when the
    /// window closes or the list is searched.
    private(set) var revealed: [UUID: String] = [:]
    private(set) var lastError: String?
    private var observer: NSObjectProtocol?
    private var clipboardChangeCount: Int?

    init(service: PasswordService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
        title = "Passwords"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    override func loadView() {
        for (checkbox, action) in [(offerCheckbox, #selector(toggleOffer(_:))), (autofillCheckbox, #selector(toggleAutofill(_:)))] {
            checkbox.target = self
            checkbox.action = action
        }
        let autofillHelp = NSTextField(wrappingLabelWithString:
            "When off, saved sign-ins are still one click away: in the list under the field, and from the key button in the toolbar.")
        autofillHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autofillHelp.textColor = .secondaryLabelColor

        searchField.placeholderString = "Search passwords"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search passwords")

        for (identifier, title, width) in [("site", "Website", 210.0), ("username", "Username", 190.0), ("password", "Password", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 90
            if identifier != "password" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.target = self
        tableView.doubleAction = #selector(edit(_:))
        tableView.setAccessibilityLabel("Saved passwords")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [(addButton, #selector(add(_:))), (editButton, #selector(edit(_:))), (deleteButton, #selector(delete(_:))),
                                 (showButton, #selector(toggleShow(_:))), (copyButton, #selector(copyPassword(_:))),
                                 (checkupButton, #selector(checkPasswords(_:)))] {
            button.target = self
            button.action = action
        }
        moreButton.addItem(withTitle: "")
        moreButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        for (title, action) in [("Import Passwords…", #selector(importPasswords(_:))), ("Export Passwords…", #selector(exportPasswords(_:))),
                                ("Import from Apple Passwords…", #selector(importFromApple(_:))),
                                ("Export to Apple Passwords…", #selector(exportToApple(_:))),
                                ("Sites Never Saved…", #selector(showNeverSaved(_:))), ("Delete All Passwords…", #selector(deleteAll(_:)))] {
            moreButton.addItem(withTitle: title)
            moreButton.lastItem?.target = self
            moreButton.lastItem?.action = action
            if title.hasPrefix("Sites") || title.hasPrefix("Import from Apple") {
                moreButton.menu?.insertItem(.separator(), at: moreButton.numberOfItems - 1)
            }
        }
        (moreButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        moreButton.setAccessibilityLabel("More")

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkupButton.toolTip = "Find leaked, reused and weak passwords"
        // The spacer gives way first; no button's title may be cut short.
        for button in [addButton, editButton, deleteButton, checkupButton, showButton, copyButton] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [addButton, editButton, deleteButton, spacer, checkupButton, showButton, copyButton, moreButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let header = NSStackView(views: [searchField, countLabel])
        header.orientation = .horizontal
        header.spacing = 10

        profileLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        profileLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [profileLabel, offerCheckbox, autofillCheckbox, autofillHelp, header, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: autofillCheckbox)
        stack.setCustomSpacing(16, after: autofillHelp)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 470))
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            autofillHelp.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            autofillHelp.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 640),
        ])
        view = root

        observer = NotificationCenter.default.addObserver(forName: PasswordService.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.reload() }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        offerCheckbox.state = BrowserSettings.offerToSavePasswords ? .on : .off
        autofillCheckbox.state = BrowserSettings.autofillPasswords ? .on : .off
        reload()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        hideAll()
    }

    // MARK: - Data

    /// Returns once the list shows the vault's current contents.
    @discardableResult
    func reload() -> Task<Void, Never> {
        Task { @MainActor in
            do {
                all = try await service.store.all()
                lastError = nil
            } catch {
                all = []
                lastError = PasswordCoordinator.describe(error)
            }
            revealed = revealed.filter { id, _ in all.contains { $0.id == id } }
            applyFilter()
        }
    }

    private func applyFilter() {
        let selected = Set(tableView.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visible = all.filter { query.isEmpty || $0.site.lowercased().contains(query) || $0.username.lowercased().contains(query) }
        let descriptor = tableView.sortDescriptors.first
        let ascending = descriptor?.ascending ?? true
        visible.sort { a, b in
            let (x, y) = descriptor?.key == "username" ? ((a.username, a.site), (b.username, b.site)) : ((a.site, a.username), (b.site, b.username))
            return ascending ? x < y : x > y
        }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(visible.indices.filter { selected.contains(visible[$0].id) }), byExtendingSelection: false)

        if let lastError {
            countLabel.stringValue = lastError
            countLabel.textColor = .systemRed
        } else {
            countLabel.textColor = .secondaryLabelColor
            countLabel.stringValue = query.isEmpty
                ? (all.count == 1 ? "1 password" : "\(all.count) passwords")
                : "\(visible.count) of \(all.count)"
        }
        updateButtons()
    }

    private var selection: [Credential] {
        tableView.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
    }

    private func updateButtons() {
        let chosen = selection
        editButton.isEnabled = chosen.count == 1
        copyButton.isEnabled = chosen.count == 1
        deleteButton.isEnabled = !chosen.isEmpty
        showButton.isEnabled = !chosen.isEmpty
        showButton.title = !chosen.isEmpty && chosen.allSatisfy({ revealed[$0.id] != nil }) ? "Hide" : "Show"
    }

    private func hideAll() {
        guard !revealed.isEmpty else { return }
        revealed = [:]
        tableView.reloadData()
        updateButtons()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, visible.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let credential = visible[row]
        let label = cell.textField
        label?.font = .systemFont(ofSize: NSFont.systemFontSize)
        label?.textColor = .labelColor
        switch identifier.rawValue {
        case "site":
            label?.stringValue = credential.site
            label?.toolTip = credential.origin
            if CredentialOrigin.isInsecure(credential.origin) { label?.stringValue += "  (not encrypted)" }
        case "username":
            label?.stringValue = credential.username.isEmpty ? "No username" : credential.username
            label?.textColor = credential.username.isEmpty ? .secondaryLabelColor : .labelColor
        default:
            if let password = revealed[credential.id] {
                label?.stringValue = password
                label?.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                label?.stringValue = "••••••••"   // a fixed length: the real one is nobody's business
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { applyFilter() }

    func controlTextDidChange(_ notification: Notification) {
        revealed = [:]
        applyFilter()
    }

    // MARK: - Settings

    @objc private func toggleOffer(_ sender: Any?) { BrowserSettings.offerToSavePasswords = offerCheckbox.state == .on }
    @objc private func toggleAutofill(_ sender: Any?) { BrowserSettings.autofillPasswords = autofillCheckbox.state == .on }

    // MARK: - Reveal and copy

    @objc private func toggleShow(_ sender: Any?) { Task { await toggleShowSelection() } }

    func toggleShowSelection() async {
        let chosen = selection
        guard !chosen.isEmpty else { return }
        if chosen.allSatisfy({ revealed[$0.id] != nil }) {
            chosen.forEach { revealed[$0.id] = nil }
        } else {
            guard await service.authenticator.authenticate(reason: "show saved passwords") else { return }
            for credential in chosen {
                revealed[credential.id] = try? await service.store.password(for: credential.id)
            }
        }
        tableView.reloadData(forRowIndexes: tableView.selectedRowIndexes, columnIndexes: IndexSet(integer: 2))
        updateButtons()
    }

    @objc private func copyPassword(_ sender: Any?) { Task { await copySelectedPassword() } }

    func copySelectedPassword() async {
        guard let credential = selection.first, selection.count == 1,
              await service.authenticator.authenticate(reason: "copy a saved password"),
              let password = try? await service.store.password(for: credential.id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(password, forType: .string)
        // The convention clipboard managers honour: do not record this.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        clipboardChangeCount = count
        // And do not leave it lying around: gone in 90 seconds, unless
        // something else has been copied since.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard self?.clipboardChangeCount == count, NSPasteboard.general.changeCount == count else { return }
            NSPasteboard.general.clearContents()
        }
    }

    // MARK: - Add, edit, delete

    @objc private func add(_ sender: Any?) { presentEditor(for: nil, password: "") }

    @objc private func edit(_ sender: Any?) {
        guard selection.count == 1, let credential = selection.first else { return }
        Task { @MainActor in
            guard await service.authenticator.authenticate(reason: "edit a saved password"),
                  let password = try? await service.store.password(for: credential.id) else { return }
            presentEditor(for: credential, password: password)
        }
    }

    private(set) var editor: PasswordEditorViewController?

    private func presentEditor(for credential: Credential?, password: String) {
        let editor = PasswordEditorViewController(credential: credential, password: password) { [weak self] result in
            guard let self else { return }
            self.editor = nil
            guard let result else { return }
            Task { @MainActor in
                do {
                    if let credential {
                        try await self.service.store.update(credential.id, username: result.username, password: result.password)
                    } else {
                        try await self.service.store.save(origin: result.origin, username: result.username, password: result.password)
                    }
                    self.service.changed()
                } catch {
                    self.present(error, title: "The password could not be saved")
                }
            }
        }
        self.editor = editor
        presentAsSheet(editor)
    }

    @objc private func delete(_ sender: Any?) {
        let chosen = selection
        guard !chosen.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = chosen.count == 1
            ? "Delete the password for \(chosen[0].username.isEmpty ? chosen[0].site : "“\(chosen[0].username)” on \(chosen[0].site)")?"
            : "Delete \(chosen.count) passwords?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await self?.deleteCredentials(chosen) }
        }
    }

    func deleteCredentials(_ credentials: [Credential]) async {
        do {
            for credential in credentials { try await service.store.delete(credential.id) }
        } catch {
            present(error, title: "The password could not be deleted")
        }
        service.changed()
    }

    @objc private func deleteAll(_ sender: Any?) {
        guard let window = view.window, !all.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete all \(all.count) saved passwords?"
        alert.informativeText = "This cannot be undone. Export them first if you may want them back."
        alert.addButton(withTitle: "Delete All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                guard await self.service.authenticator.authenticate(reason: "delete all saved passwords") else { return }
                do { try await self.service.store.deleteAll() } catch { self.present(error, title: "The passwords could not be deleted") }
                self.service.changed()
            }
        }
    }

    // MARK: - Import, export, never saved

    @objc private func importPasswords(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a passwords CSV exported from Chrome, Safari, Firefox, Edge or a password manager."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.importCSV(from: url) }
        }
    }

    func importCSV(from url: URL) async {
        guard let window = view.window else { return }
        let alert = NSAlert()
        do {
            let summary = try await service.importCSV(from: url)
            alert.messageText = summary.added + summary.updated == 0 ? "Nothing new to import" : "Passwords imported"
            var lines = ["\(summary.added) added, \(summary.updated) updated, \(summary.unchanged) already saved."]
            if summary.skipped > 0 { lines.append("\(summary.skipped) skipped: no web address, or no password.") }
            lines.append("The CSV file still holds every password in the clear. Delete it when you are done.")
            alert.informativeText = lines.joined(separator: "\n\n")
        } catch PasswordCSV.ImportError.unrecognisedHeader {
            alert.messageText = "That file is not a passwords CSV"
            alert.informativeText = "Its first line needs to name a URL column and a password column."
        } catch {
            alert.messageText = "The passwords could not be imported"
            alert.informativeText = PasswordCoordinator.describe(error)
        }
        lastImportMessage = alert.messageText + "\n" + alert.informativeText
        // The completion-handler form: in an async function the bare call
        // would mean "wait here until the sheet is dismissed".
        alert.beginSheetModal(for: window) { _ in }
    }

    /// What the last import told the user. Read by the self-test.
    private(set) var lastImportMessage = ""

    @objc private func exportPasswords(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SimpleBrowser Passwords.csv"
        panel.message = "The exported file is not encrypted: anyone who can read it can read your passwords."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do { _ = try await self.service.exportCSV(to: url) } catch { self.present(error, title: "The passwords could not be exported") }
            }
        }
    }

    // MARK: - Checkup

    private(set) var checkup: PasswordCheckupViewController?

    @objc private func checkPasswords(_ sender: Any?) {
        let sheet = PasswordCheckupViewController(service: service)
        sheet.onShowInList = { [weak self] credential in self?.select(credential) }
        checkup = sheet
        presentAsSheet(sheet)
    }

    /// Clears the search so the entry is in the list, then selects it.
    func select(_ credential: Credential) {
        searchField.stringValue = ""
        applyFilter()
        guard let row = visible.firstIndex(where: { $0.id == credential.id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Apple Passwords

    // Apple gives other browsers no way to read or write iCloud Keychain, so
    // the two meet through the CSV files the Passwords app itself imports
    // and exports. Each step is explained where it happens, because half of
    // it takes place in another app.

    @objc private func importFromApple(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Import from Apple Passwords"
        alert.informativeText = """
        1. In the Passwords app, choose File → Export All Passwords to File…, and save the file.
        2. Come back here, click Choose File…, and pick it.

        The exported file is not encrypted. Delete it once the import is done.
        """
        alert.addButton(withTitle: "Choose File…")
        alert.addButton(withTitle: "Open Passwords")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.importPasswords(sender)
            case .alertSecondButtonReturn: Self.openApplePasswords()
            default: break
            }
        }
    }

    @objc private func exportToApple(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SimpleBrowser Passwords for Apple.csv"
        panel.message = "Written in the format the Passwords app imports. The file is not encrypted: delete it after importing."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in await self.exportForApple(to: url) }
        }
    }

    func exportForApple(to url: URL) async {
        do {
            guard let count = try await service.exportCSV(to: url, format: .apple), let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = count == 1 ? "1 password exported" : "\(count) passwords exported"
            alert.informativeText = """
            In the Passwords app, choose File → Import Passwords from File…, and pick “\(url.lastPathComponent)”.

            Then delete the file: it holds every password in the clear.
            """
            alert.addButton(withTitle: "Open Passwords")
            alert.addButton(withTitle: "Show File")
            alert.addButton(withTitle: "Done")
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn: Self.openApplePasswords()
                case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
                default: break
                }
            }
        } catch {
            present(error, title: "The passwords could not be exported")
        }
    }

    /// The Passwords app on macOS 15, or the Passwords pane of System
    /// Settings where the app does not exist.
    static func openApplePasswords() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else if let settings = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
            NSWorkspace.shared.open(settings)
        }
    }

    @objc private func showNeverSaved(_ sender: Any?) {
        presentAsSheet(NeverSavedViewController(service: service))
    }

    private func present(_ error: any Error, title: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = PasswordCoordinator.describe(error)
        alert.beginSheetModal(for: window)
    }
}

/// The add / edit sheet.
@MainActor
final class PasswordEditorViewController: NSViewController, NSTextFieldDelegate {
    struct Result { var origin: String; var username: String; var password: String }

    private let credential: Credential?
    private let onDone: (Result?) -> Void
    let siteField = NSTextField()
    let usernameField = NSTextField()
    let passwordField = RevealablePasswordField()
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let problemLabel = NSTextField(labelWithString: "")

    init(credential: Credential?, password: String, onDone: @escaping (Result?) -> Void) {
        self.credential = credential
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        siteField.stringValue = credential?.origin ?? ""
        usernameField.stringValue = credential?.username ?? ""
        passwordField.stringValue = password
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: credential == nil ? "Add a password" : "Edit password")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        siteField.placeholderString = "example.com"
        siteField.isEditable = credential == nil
        if credential != nil { siteField.isBordered = false; siteField.drawsBackground = false }
        siteField.delegate = self
        siteField.setAccessibilityLabel("Website")
        usernameField.setAccessibilityLabel("Username")
        passwordField.onChange = { [weak self] in self?.validate() }

        let suggest = NSButton(title: "Suggest", target: self, action: #selector(suggest(_:)))
        suggest.controlSize = .small
        suggest.toolTip = "Fill in a strong password"
        let passwordRow = NSStackView(views: [passwordField, suggest])
        passwordRow.spacing = 6

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Website"), siteField],
            [NSTextField(labelWithString: "Username"), usernameField],
            [NSTextField(labelWithString: "Password"), passwordRow],
            [NSGridCell.emptyContentView, problemLabel],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        for row in 0..<3 { grid.row(at: row).yPlacement = .center }
        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.textColor = .systemOrange

        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, saveButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 440),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = root
        validate()
    }

    func controlTextDidChange(_ notification: Notification) { validate() }

    private var origin: String? { credential?.origin ?? CredentialOrigin.normalize(siteField.stringValue) }

    func validate() {
        let typedSite = !siteField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        problemLabel.stringValue = typedSite && origin == nil ? "That is not a web address." : ""
        saveButton.isEnabled = origin != nil && !passwordField.stringValue.isEmpty
    }

    @objc private func suggest(_ sender: Any?) {
        passwordField.stringValue = PasswordGenerator.generate()
        passwordField.setRevealed(true)
        validate()
    }

    @objc private func save(_ sender: Any?) {
        guard let origin, !passwordField.stringValue.isEmpty else { return }
        dismiss(nil)
        onDone(Result(origin: origin, username: usernameField.stringValue, password: passwordField.stringValue))
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(nil)
        onDone(nil)
    }
}

/// Sites answered "Never" at the save prompt, with a way to change one's mind.
@MainActor
final class NeverSavedViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let service: PasswordService
    let tableView = NSTableView()
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var origins: [String] = []

    init(service: PasswordService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Sites never saved")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let help = NSTextField(wrappingLabelWithString: "SimpleBrowser does not offer to save passwords for these sites. Remove one to be asked again.")
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("origin"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [removeButton, spacer, done])

        let stack = NSStackView(views: [title, help, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 420),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 180),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = root
        refresh()
    }

    private func refresh() {
        origins = BrowserSettings.neverSavePasswordOrigins
        tableView.reloadData()
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { origins.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: origins[row])
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    @objc private func remove(_ sender: Any?) {
        for index in tableView.selectedRowIndexes where origins.indices.contains(index) { service.allowSaving(origins[index]) }
        refresh()
    }

    @objc private func done(_ sender: Any?) { dismiss(nil) }
}
