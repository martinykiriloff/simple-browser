import AppKit
import WebKit
import BrowserKit

/// What the lock in the address bar opens: how the connection is secured and
/// by whose certificate, what the site may do, what it has stored on this
/// Mac, and what was blocked on the page.
@MainActor
final class PageInfoController: NSViewController {
    struct Content {
        var site: String?                    // the origin, for permissions
        var name: String                     // as the address bar shows it
        var security: PageSecurity
        var summary: String
        var certificate: CertificateStore.Details?
        var blocked: Int
        var blockingOn: Bool
    }

    private let content: Content
    private let permissions: () -> SitePermissions
    private let setPermission: (SitePermission, PermissionChoice?) -> Void
    private let dataStore: WKWebsiteDataStore
    private let host: String?
    private let onCleared: () -> Void

    let titleLabel = NSTextField(labelWithString: "")
    let explanationLabel = NSTextField(wrappingLabelWithString: "")
    let certificateLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var permissionPopUps: [SitePermission: NSPopUpButton] = [:]
    let dataLabel = NSTextField(labelWithString: "Looking…")
    let clearButton = NSButton(title: "Clear…", target: nil, action: nil)
    let blockedLabel = NSTextField(labelWithString: "")
    private var records: [WKWebsiteDataRecord] = []
    private(set) var cookieCount = 0

    init(content: Content, permissions: @escaping () -> SitePermissions, setPermission: @escaping (SitePermission, PermissionChoice?) -> Void,
         dataStore: WKWebsiteDataStore, host: String?, onCleared: @escaping () -> Void) {
        self.content = content
        self.permissions = permissions
        self.setPermission = setPermission
        self.dataStore = dataStore
        self.host = host
        self.onCleared = onCleared
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Design D's site info (G1-04): the site, the connection in green (or
    /// red), mono details, small uppercase headings.
    private let keel = Keel.chromeEnabled

    override func loadView() {
        titleLabel.stringValue = content.summary
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = content.security.label == nil ? .labelColor : .systemOrange
        explanationLabel.stringValue = content.security.explanation(site: content.name)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        var rows: [NSView] = [titleLabel, explanationLabel]
        if keel {
            let trouble = content.security.label != nil
            titleLabel.font = Keel.font(13, .medium)
            titleLabel.textColor = trouble ? Keel.dangerText : Keel.greenText
            explanationLabel.textColor = Keel.muted
            let site = Keel.label(content.name.isEmpty ? "This page" : content.name, size: 15, weight: .semibold, color: Keel.text)
            site.lineBreakMode = .byTruncatingMiddle
            let header = NSStackView(views: [Keel.square(trouble ? Keel.dangerText : Keel.green, size: 16, radius: 4), site])
            header.spacing = 10
            rows.insert(header, at: 0)
        }

        if let certificate = content.certificate, !certificate.fingerprint.isEmpty {
            var lines = ["Certificate issued to \(certificate.subject.isEmpty ? "an unnamed subject" : certificate.subject)"]
            if !certificate.issuer.isEmpty { lines.append("by \(certificate.issuer)") }
            if let expires = certificate.expires {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                lines.append((expires < Date() ? "expired " : "valid until ") + formatter.string(from: expires))
            }
            certificateLabel.stringValue = lines.joined(separator: ", ") + "."
            certificateLabel.font = keel ? Keel.mono : .systemFont(ofSize: NSFont.smallSystemFontSize)
            certificateLabel.textColor = keel ? Keel.dim : .secondaryLabelColor
            rows.append(certificateLabel)
        }

        if content.site != nil {
            rows.append(separator())
            rows.append(heading("This site may use"))
            let grid = NSGridView()
            grid.rowSpacing = 5
            grid.columnSpacing = 10
            for permission in SitePermission.offered {
                let icon = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil) ?? NSImage())
                icon.contentTintColor = .secondaryLabelColor
                let name = NSTextField(labelWithString: permission.name)
                let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
                popUp.controlSize = .small
                popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                popUp.addItems(withTitles: [permission.asksByDefault ? "Ask" : "Block, and Say So", "Allow", "Don’t Allow"])
                popUp.target = self
                popUp.action = #selector(permissionChanged(_:))
                popUp.tag = SitePermission.offered.firstIndex(of: permission) ?? 0
                popUp.setAccessibilityLabel(permission.name)
                permissionPopUps[permission] = popUp
                grid.addRow(with: [icon, name, popUp])
            }
            grid.column(at: 2).xPlacement = .trailing
            rows.append(grid)
        }

        if host != nil {
            rows.append(separator())
            rows.append(heading("Stored on this Mac by this site"))
            dataLabel.font = keel ? Keel.mono : .systemFont(ofSize: NSFont.smallSystemFontSize)
            dataLabel.textColor = keel ? Keel.muted : .secondaryLabelColor
            clearButton.controlSize = .small
            clearButton.target = self
            clearButton.action = #selector(clear(_:))
            clearButton.isEnabled = false
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            rows.append(NSStackView(views: [dataLabel, spacer, clearButton]))
        }

        if content.site != nil {
            rows.append(separator())
            blockedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            blockedLabel.textColor = keel ? (content.blockingOn ? Keel.greenText : Keel.muted) : .secondaryLabelColor
            blockedLabel.stringValue = !content.blockingOn ? "Ads and trackers are not being blocked on this page."
                : content.blocked == 0 ? "No ads or trackers were blocked on this page."
                : content.blocked == 1 ? "1 ad or tracker was blocked on this page." : "\(content.blocked) ads and trackers were blocked on this page."
            rows.append(blockedLabel)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: titleLabel)
        if keel, let header = rows.first, header !== titleLabel { stack.setCustomSpacing(6, after: header) }
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root: NSView = keel ? KeelFill(fill: Keel.raised) : NSView()
        if keel {
            root.appearance = Keel.darkAppearance
            root.translatesAutoresizingMaskIntoConstraints = true
        }
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 360),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32) })
        view = root
        refreshPermissions()
        Task { @MainActor in await refreshData() }
    }

    private func heading(_ text: String) -> NSTextField {
        if keel { return Keel.sectionLabel(text) }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return label
    }

    private func separator() -> NSView {
        if keel {
            let line = KeelFill(fill: Keel.hairline)
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line
        }
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Permissions

    func refreshPermissions() {
        guard let site = content.site else { return }
        let stored = permissions()
        for (permission, popUp) in permissionPopUps {
            switch stored.choice(for: permission, site: site) {
            case nil: popUp.selectItem(at: 0)
            case .allow: popUp.selectItem(at: 1)
            case .deny: popUp.selectItem(at: 2)
            }
        }
    }

    @objc private func permissionChanged(_ sender: NSPopUpButton) {
        guard SitePermission.offered.indices.contains(sender.tag) else { return }
        let choice: PermissionChoice? = sender.indexOfSelectedItem == 1 ? .allow : sender.indexOfSelectedItem == 2 ? .deny : nil
        setPermission(SitePermission.offered[sender.tag], choice)
    }

    // MARK: - What the site stored

    /// WebKit keeps a site's data under its registrable domain; the page's
    /// host, or a parent of it, is the record's name.
    private func belongs(_ record: WKWebsiteDataRecord) -> Bool {
        guard let host else { return false }
        let name = record.displayName.lowercased()
        return host == name || host.hasSuffix("." + name)
    }

    func refreshData() async {
        guard let host else { return }
        let all = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        records = all.filter(belongs)
        let cookies = await dataStore.httpCookieStore.allCookies()
        cookieCount = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }.count
        let kinds = Set(records.flatMap(\.dataTypes)).subtracting([WKWebsiteDataTypeCookies])
        var parts: [String] = []
        if cookieCount > 0 { parts.append(cookieCount == 1 ? "1 cookie" : "\(cookieCount) cookies") }
        if kinds.contains(WKWebsiteDataTypeLocalStorage) || kinds.contains(WKWebsiteDataTypeIndexedDBDatabases) || kinds.contains(WKWebsiteDataTypeSessionStorage) { parts.append("stored data") }
        if kinds.contains(WKWebsiteDataTypeDiskCache) || kinds.contains(WKWebsiteDataTypeMemoryCache) || kinds.contains(WKWebsiteDataTypeFetchCache) { parts.append("cached files") }
        if kinds.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("a service worker") }
        dataLabel.stringValue = parts.isEmpty ? "Nothing" : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
        clearButton.isEnabled = !parts.isEmpty
    }

    /// Signs the person out of the site and forgets what it kept here.
    @objc private func clear(_ sender: Any?) { Task { @MainActor in await clearData() } }

    func clearData() async {
        guard let host else { return }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        for cookie in await dataStore.httpCookieStore.allCookies() {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if host == domain || host.hasSuffix("." + domain) { await dataStore.httpCookieStore.deleteCookie(cookie) }
        }
        await refreshData()
        onCleared()
    }
}
