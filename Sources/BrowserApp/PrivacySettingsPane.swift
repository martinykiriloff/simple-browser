import AppKit
import BlockKit

/// Settings → Privacy: content blocking on or off, which filter lists are
/// used, when they were last updated, and the sites it is switched off for.
@MainActor
final class PrivacySettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let blocker: ContentBlocker
    /// The profile whose "off for this site" choices are shown: the one in front.
    var currentProfile: (() -> (id: String, name: String))?

    let blockingCheckbox = NSButton(checkboxWithTitle: "Block ads and trackers", target: nil, action: nil)
    private(set) var listCheckboxes: [NSButton] = []
    let statusLabel = NSTextField(labelWithString: "")
    let updateButton = NSButton(title: "Update Now", target: nil, action: nil)
    let sitesTitle = NSTextField(labelWithString: "")
    let sitesTable = NSTableView()
    let removeButton = NSButton(title: "Turn Blocking Back On", target: nil, action: nil)
    private let listsStack = NSStackView()
    private var sites: [String] = []
    private var observer: NSObjectProtocol?

    init(blocker: ContentBlocker) {
        self.blocker = blocker
        super.init(nibName: nil, bundle: nil)
        title = "Privacy"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        blockingCheckbox.target = self
        blockingCheckbox.action = #selector(toggleBlocking(_:))
        let about = NSTextField(wrappingLabelWithString:
            "Requests the filter lists name are never made, so pages load faster and the companies behind them learn nothing. "
            + "The shield beside the address bar shows what was blocked on a page, and switches blocking off for a site that needs it.")
        about.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        about.textColor = .secondaryLabelColor

        let listsTitle = NSTextField(labelWithString: "Filter lists")
        listsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        listsStack.orientation = .vertical
        listsStack.alignment = .leading
        listsStack.spacing = 6

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateButton.target = self
        updateButton.action = #selector(updateNow(_:))
        updateButton.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, spacer, updateButton])

        sitesTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        sitesTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("site")))
        sitesTable.headerView = nil
        sitesTable.dataSource = self
        sitesTable.delegate = self
        sitesTable.allowsMultipleSelection = true
        sitesTable.setAccessibilityLabel("Sites where blocking is off")
        let scroll = NSScrollView()
        scroll.documentView = sitesTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        removeButton.target = self
        removeButton.action = #selector(removeSites(_:))

        let stack = NSStackView(views: [blockingCheckbox, about, listsTitle, listsStack, statusRow, sitesTitle, scroll, removeButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: blockingCheckbox)
        stack.setCustomSpacing(18, after: about)
        stack.setCustomSpacing(12, after: listsStack)
        stack.setCustomSpacing(18, after: statusRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            root.widthAnchor.constraint(equalToConstant: 600),
            about.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            about.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 110),
        ])
        view = root

        observer = NotificationCenter.default.addObserver(forName: ContentBlocker.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        blockingCheckbox.state = blocker.isOn ? .on : .off

        if listCheckboxes.count != blocker.sources.count {
            listCheckboxes.forEach { $0.removeFromSuperview() }
            listCheckboxes = blocker.sources.enumerated().map { index, list in
                let box = NSButton(checkboxWithTitle: "\(list.name): \(list.about.prefix(1).lowercased() + list.about.dropFirst())", target: self, action: #selector(toggleList(_:)))
                box.tag = index
                listsStack.addArrangedSubview(box)
                return box
            }
        }
        let enabled = Set(blocker.enabledSources.map(\.id))
        for (box, list) in zip(listCheckboxes, blocker.sources) {
            box.state = enabled.contains(list.id) ? .on : .off
            box.isEnabled = blocker.isOn
        }

        statusLabel.stringValue = blocker.statusLine
        if case .failed = blocker.activity { statusLabel.textColor = .systemOrange } else { statusLabel.textColor = .secondaryLabelColor }
        var detail: [String] = []
        if blocker.state.skipped > 0 { detail.append("\(blocker.state.skipped) filters use features WebKit's blocker does not have and are left out") }
        if blocker.state.rejected > 0 { detail.append("\(blocker.state.rejected) rules were refused by WebKit") }
        statusLabel.toolTip = detail.isEmpty ? nil : detail.joined(separator: "; ") + "."
        updateButton.isEnabled = blocker.isOn && !blocker.isBusy && !blocker.enabledSources.isEmpty

        let profile = currentProfile?()
        sitesTitle.stringValue = "Blocking is off for these sites" + (profile.map { " (\($0.name))" } ?? "")
        let selected = Set(sitesTable.selectedRowIndexes.compactMap { sites.indices.contains($0) ? sites[$0] : nil })
        sites = profile.map { BrowserSettings.blockingOffSites(profile: $0.id) } ?? []
        sitesTable.reloadData()
        sitesTable.selectRowIndexes(IndexSet(sites.indices.filter { selected.contains(sites[$0]) }), byExtendingSelection: false)
        removeButton.isEnabled = !sitesTable.selectedRowIndexes.isEmpty
    }

    // MARK: - Actions

    @objc private func toggleBlocking(_ sender: Any?) {
        BrowserSettings.contentBlocking = blockingCheckbox.state == .on
        blocker.settingsChanged()
    }

    @objc private func toggleList(_ sender: NSButton) {
        guard blocker.sources.indices.contains(sender.tag) else { return }
        var enabled = Set(blocker.enabledSources.map(\.id))
        let id = blocker.sources[sender.tag].id
        if sender.state == .on { enabled.insert(id) } else { enabled.remove(id) }
        // In the lists' own order, so the same choice is always the same set.
        BrowserSettings.enabledFilterLists = blocker.sources.map(\.id).filter(enabled.contains)
        blocker.settingsChanged()
    }

    @objc private func updateNow(_ sender: Any?) {
        Task { @MainActor in _ = await blocker.update(force: true) }
    }

    @objc private func removeSites(_ sender: Any?) {
        guard let profile = currentProfile?() else { return }
        let removed = Set(sitesTable.selectedRowIndexes.compactMap { sites.indices.contains($0) ? sites[$0] : nil })
        BrowserSettings.setBlockingOffSites(sites.filter { !removed.contains($0) }, profile: profile.id)
        NotificationCenter.default.post(name: ContentBlocker.didChange, object: blocker)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { sites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sites.indices.contains(row) else { return nil }
        let label = NSTextField(labelWithString: sites[row])
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !sitesTable.selectedRowIndexes.isEmpty
    }

    /// For the self-test.
    var shownSites: [String] { sites }
}
