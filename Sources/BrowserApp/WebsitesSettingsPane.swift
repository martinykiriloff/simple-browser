import AppKit
import BrowserKit

/// Settings → Websites: every site that was allowed or refused something,
/// what, and a way to change one's mind.
@MainActor
final class WebsitesSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// The profile whose choices are shown: the one in front.
    var currentProfile: (() -> (id: String, name: String))?

    struct Row: Equatable {
        var site: String
        var permission: SitePermission
        var choice: PermissionChoice
    }

    let titleLabel = NSTextField(labelWithString: "")
    let tableView = NSTableView()
    let emptyLabel = NSTextField(wrappingLabelWithString:
        "No site has been allowed or refused anything. When a site asks for the camera, the microphone or your location, your answer appears here.")
    let removeButton = NSButton(title: "Ask Again", target: nil, action: nil)
    let removeAllButton = NSButton(title: "Forget All…", target: nil, action: nil)
    private(set) var rows: [Row] = []
    private var observer: NSObjectProtocol?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Websites"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for (identifier, title, width) in [("site", "Website", 250.0), ("permission", "May Use", 170.0), ("choice", "", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 26
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.setAccessibilityLabel("Sites with permissions")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        removeButton.toolTip = "Forget the choice: the site is asked about again"
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [removeButton, spacer, removeAllButton])

        let stack = NSStackView(views: [titleLabel, emptyLabel, scroll, buttons])
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
            root.widthAnchor.constraint(equalToConstant: 620),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 280),
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(forName: PermissionsController.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private var stored: SitePermissions {
        get { currentProfile.map { BrowserSettings.sitePermissions(profile: $0().id) } ?? SitePermissions() }
        set {
            guard let profile = currentProfile?() else { return }
            BrowserSettings.setSitePermissions(newValue, profile: profile.id)
            NotificationCenter.default.post(name: PermissionsController.didChange, object: nil)
        }
    }

    func refresh() {
        guard isViewLoaded else { return }
        let selected = tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        rows = stored.sites.flatMap { entry in entry.choices.map { Row(site: entry.site, permission: $0.permission, choice: $0.choice) } }
        titleLabel.stringValue = "What sites may do" + (currentProfile.map { " (\($0().name))" } ?? "")
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(rows.indices.filter { index in selected.contains { $0.site == rows[index].site && $0.permission == rows[index].permission } }),
                                   byExtendingSelection: false)
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
        removeAllButton.isEnabled = !rows.isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let entry = rows[row]
        switch identifier {
        case "site":
            let label = NSTextField(labelWithString: SitePermissions.displayName(of: entry.site) + (entry.site.hasPrefix("http://") ? "  (not encrypted)" : ""))
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = entry.site
            return label
        case "permission":
            let icon = NSImageView(image: NSImage(systemSymbolName: entry.permission.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let stack = NSStackView(views: [icon, NSTextField(labelWithString: entry.permission.name)])
            stack.spacing = 6
            return stack
        default:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popUp.addItems(withTitles: PermissionChoice.allCases.map(\.name))
            popUp.selectItem(at: PermissionChoice.allCases.firstIndex(of: entry.choice) ?? 0)
            popUp.tag = row
            popUp.target = self
            popUp.action = #selector(choiceChanged(_:))
            popUp.setAccessibilityLabel("\(entry.permission.name) for \(SitePermissions.displayName(of: entry.site))")
            return popUp
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    // MARK: - Actions

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag), PermissionChoice.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        set(PermissionChoice.allCases[sender.indexOfSelectedItem], forRow: sender.tag)
    }

    func set(_ choice: PermissionChoice?, forRow row: Int) {
        guard rows.indices.contains(row) else { return }
        var all = stored
        all.set(choice, for: rows[row].permission, site: rows[row].site)
        stored = all
    }

    @objc private func remove(_ sender: Any?) {
        var all = stored
        for index in tableView.selectedRowIndexes where rows.indices.contains(index) { all.set(nil, for: rows[index].permission, site: rows[index].site) }
        stored = all
    }

    @objc private func removeAll(_ sender: Any?) {
        guard let window = view.window, !rows.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Forget what every site was allowed and refused?"
        alert.informativeText = "Sites will ask again the next time they want to use the camera, the microphone or your location, and their pop-up windows and automatic downloads will be held back again."
        alert.addButton(withTitle: "Forget All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.stored = SitePermissions() }
        }
    }
}
