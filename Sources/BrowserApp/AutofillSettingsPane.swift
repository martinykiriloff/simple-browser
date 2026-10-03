import AppKit
import AuthenticationServices
import Contacts
import PasswordKit

/// Passkeys in pages: WebKit runs WebAuthn itself, through iCloud Keychain
/// and any passkey provider, once macOS has let this browser do so. That
/// needs Apple's browser passkey entitlement in the signed app, and then the
/// person's yes, which is asked for here.
@MainActor
enum PasskeyAccess {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// Whether this build was signed with the entitlement.
    static var hasEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool) == true
    }

    static var state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials
    }

    static func requestAuthorization() async -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        await withCheckedContinuation { continuation in
            ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { continuation.resume(returning: $0) }
        }
    }

    /// What the Settings pane says.
    static var status: String {
        guard hasEntitlement else {
            return "Passkeys need Apple’s browser passkey entitlement in the signed app, which this build does not have. Sites fall back to their other ways of signing in."
        }
        switch state {
        case .authorized: return "Sites can use your passkeys, from iCloud Keychain or another passkey app, with Touch ID."
        case .denied: return "Passkeys are turned off for Keel in System Settings → Privacy & Security → Passkeys Access for Web Browsers."
        default: return "Keel has not been allowed to use passkeys yet."
        }
    }
}

/// Settings → AutoFill: addresses and cards for forms, and passkeys.
@MainActor
final class AutofillSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var service: () -> PasswordService? = { nil }
    /// The "Me" card from Contacts: the real one, or a stand-in in tests.
    var meCard: () async throws -> AutofillAddress? = { try await AutofillSettingsPane.contactsMeCard() }

    let enabledCheckbox = NSButton(checkboxWithTitle: "Fill addresses and cards in forms, and offer to save new ones", target: nil, action: nil)
    let addresses = NSTableView()
    let cards = NSTableView()
    let passkeyLabel = NSTextField(wrappingLabelWithString: "")
    let passkeyButton = NSButton(title: "Allow Passkeys…", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var contents = AutofillVault.Contents()
    private(set) var editor: AutofillEditor?
    private var observer: NSObjectProtocol?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "AutoFill"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        let addressBox = list(addresses, title: "Addresses", buttons: [("Add…", #selector(addAddress(_:))), ("Edit…", #selector(editAddress(_:))),
                                                                    ("Remove", #selector(removeAddress(_:))), ("Add My Card from Contacts", #selector(addMeCard(_:)))])
        let cardBox = list(cards, title: "Cards", buttons: [("Add…", #selector(addCard(_:))), ("Edit…", #selector(editCard(_:))), ("Remove", #selector(removeCard(_:)))])
        let cardNote = NSTextField(wrappingLabelWithString: "Cards are filled after Touch ID or your Mac’s password. Their security codes are never kept.")
        cardNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cardNote.textColor = .secondaryLabelColor
        let passkeyTitle = NSTextField(labelWithString: "Passkeys")
        passkeyTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        passkeyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        passkeyLabel.textColor = .secondaryLabelColor
        passkeyButton.target = self
        passkeyButton.action = #selector(allowPasskeys(_:))
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [enabledCheckbox, addressBox, cardBox, cardNote, passkeyTitle, passkeyLabel, passkeyButton, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: cardNote)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [cardNote, passkeyLabel, statusLabel] { view.widthAnchor.constraint(equalToConstant: 520).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true
        view = stack
        observer = NotificationCenter.default.addObserver(forName: PasswordService.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func list(_ table: NSTableView, title: String, buttons: [(String, Selector)]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = table === addresses ? #selector(editAddress(_:)) : #selector(editCard(_:))
        table.setAccessibilityLabel(title)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let row = NSStackView(views: buttons.map { NSButton(title: $0.0, target: self, action: $0.1) })
        let stack = NSStackView(views: [heading, scroll, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        enabledCheckbox.state = BrowserSettings.autofillForms ? .on : .off
        passkeyLabel.stringValue = PasskeyAccess.status
        passkeyButton.isHidden = !PasskeyAccess.hasEntitlement || PasskeyAccess.state != .notDetermined
        Task { @MainActor in
            contents = (try? await service()?.autofill?.contents()) ?? .init()
            addresses.reloadData()
            cards.reloadData()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === addresses ? contents.addresses.count : contents.cards.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === addresses {
            text = contents.addresses[row].summary
        } else {
            let card = contents.cards[row]
            text = [card.masked, card.nameOnCard, card.expiry.isEmpty ? "" : "expires \(card.expiry)"].filter { !$0.isEmpty }.joined(separator: "   ")
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    // MARK: - Actions

    @objc private func enabledChanged(_ sender: Any?) { BrowserSettings.autofillForms = enabledCheckbox.state == .on }

    @objc func addAddress(_ sender: Any?) { presentEditor(.address(AutofillAddress())) }
    @objc func addCard(_ sender: Any?) { presentEditor(.card(AutofillCard())) }

    @objc private func editAddress(_ sender: Any?) {
        guard contents.addresses.indices.contains(addresses.selectedRow) else { return }
        presentEditor(.address(contents.addresses[addresses.selectedRow]))
    }

    /// A card's number is shown only to the person it belongs to.
    @objc private func editCard(_ sender: Any?) {
        guard contents.cards.indices.contains(cards.selectedRow), let service = service() else { return }
        let card = contents.cards[cards.selectedRow]
        Task { @MainActor in
            guard await service.authenticator.authenticate(reason: "see your card details") else { return }
            presentEditor(.card(card))
        }
    }

    @objc private func removeAddress(_ sender: Any?) {
        guard contents.addresses.indices.contains(addresses.selectedRow) else { return }
        let id = contents.addresses[addresses.selectedRow].id
        Task { @MainActor in
            try? await service()?.autofill?.deleteAddress(id)
            reload()
        }
    }

    @objc private func removeCard(_ sender: Any?) {
        guard contents.cards.indices.contains(cards.selectedRow) else { return }
        let id = contents.cards[cards.selectedRow].id
        Task { @MainActor in
            try? await service()?.autofill?.deleteCard(id)
            reload()
        }
    }

    @objc func addMeCard(_ sender: Any?) {
        Task { @MainActor in
            do {
                guard var me = try await meCard() else {
                    statusLabel.stringValue = "Your card in Contacts could not be read. Allow Keel in System Settings → Privacy & Security → Contacts."
                    return
                }
                if me.label.isEmpty { me.label = "Me" }
                let existing = contents.addresses.contains { $0.isSame(as: me) }
                if !existing { try await service()?.autofill?.save(me) }
                statusLabel.stringValue = existing ? "Your card from Contacts is here already." : "Your card from Contacts was added."
                reload()
            } catch {
                statusLabel.stringValue = "Your card in Contacts could not be read: \(error.localizedDescription)"
            }
        }
    }

    @objc private func allowPasskeys(_ sender: Any?) {
        Task { @MainActor in
            _ = await PasskeyAccess.requestAuthorization()
            reload()
        }
    }

    private func presentEditor(_ item: AutofillEditor.Item) {
        let editor = AutofillEditor(item: item) { [weak self] edited in
            guard let self, let autofill = self.service()?.autofill else { return }
            Task { @MainActor in
                switch edited {
                case .address(let address): try? await autofill.save(address)
                case .card(let card): try? await autofill.save(card)
                }
                self.reload()
            }
        }
        self.editor = editor
        presentAsSheet(editor)
    }

    /// The "Me" card, as an address.
    nonisolated static func contactsMeCard() async throws -> AutofillAddress? {
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { return nil }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey,
                    CNContactPhoneNumbersKey, CNContactPostalAddressesKey] as [CNKeyDescriptor]
        let me = try store.unifiedMeContactWithKeys(toFetch: keys)
        let postal = me.postalAddresses.first?.value
        return AutofillAddress(fullName: [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " "),
                               organization: me.organizationName, street: postal?.street ?? "", city: postal?.city ?? "",
                               region: postal?.state ?? "", postalCode: postal?.postalCode ?? "", country: postal?.isoCountryCode.uppercased() ?? "",
                               email: me.emailAddresses.first.map { $0.value as String } ?? "", phone: me.phoneNumbers.first?.value.stringValue ?? "")
    }
}

/// Adds or edits one address or card.
@MainActor
final class AutofillEditor: NSViewController {
    enum Item {
        case address(AutofillAddress)
        case card(AutofillCard)
    }

    private let item: Item
    private let save: (Item) -> Void
    private(set) var fields: [String: NSTextField] = [:]

    init(item: Item, save: @escaping (Item) -> Void) {
        self.item = item
        self.save = save
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private var rows: [(key: String, title: String, value: String)] {
        switch item {
        case .address(let a):
            return [("label", "Label", a.label), ("fullName", "Name", a.fullName), ("organization", "Company", a.organization),
                    ("street", "Street", a.street), ("city", "City", a.city), ("region", "State or region", a.region),
                    ("postalCode", "Postcode", a.postalCode), ("country", "Country", a.country), ("email", "Email", a.email), ("phone", "Phone", a.phone)]
        case .card(let c):
            return [("nameOnCard", "Name on card", c.nameOnCard), ("number", "Card number", c.number),
                    ("expiry", "Expires (MM/YY)", c.expiry)]
        }
    }

    override func loadView() {
        var gridRows: [[NSView]] = []
        for row in rows {
            let title = NSTextField(labelWithString: row.title + ":")
            let field = NSTextField(string: row.value)
            field.setAccessibilityLabel(row.title)
            if row.key == "street" { field.placeholderString = "One line per line of the address" }
            if row.key == "number" { field.contentType = .creditCardNumber }
            fields[row.key] = field
            gridRows.append([title, field])
        }
        let grid = NSGridView(views: gridRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        for row in rows { fields[row.key]?.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Save", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, done])
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view = stack
    }

    func value(_ key: String) -> String { fields[key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    @objc func done(_ sender: Any?) {
        switch item {
        case .address(var a):
            a.label = value("label"); a.fullName = value("fullName"); a.organization = value("organization")
            a.street = value("street").replacingOccurrences(of: ", ", with: "\n"); a.city = value("city"); a.region = value("region")
            a.postalCode = value("postalCode"); a.country = value("country"); a.email = value("email"); a.phone = value("phone")
            save(.address(a))
        case .card(let c):
            let parts = value("expiry").split { !$0.isNumber }.compactMap { Int($0) }
            var card = AutofillCard(nameOnCard: value("nameOnCard"), number: value("number"),
                                    expiryMonth: parts.first ?? 0, expiryYear: parts.count > 1 ? parts[1] : 0)
            card.id = c.id
            guard AutofillCard.isPlausible(card.number) else {
                fields["number"]?.textColor = .systemRed
                return
            }
            save(.card(card))
        }
        dismiss(nil)
    }

    @objc private func cancel(_ sender: Any?) { dismiss(nil) }
}
