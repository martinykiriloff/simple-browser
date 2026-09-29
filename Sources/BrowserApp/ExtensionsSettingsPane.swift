import AppKit
import WebKit
import BrowserKit

/// Settings → Extensions: what is installed, on or off in the profile of the
/// window in front, where each may read and change pages, and Add / Remove.
@MainActor
final class ExtensionsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var store: () -> ExtensionStore?
    var profile: () -> Profile?
    var running: (Profile) -> ProfileExtensions?
    /// Picks the folder, .zip or .crx to add: an open panel, or a stand-in in tests.
    var chooseSource: @MainActor () -> URL? = { ExtensionsSettingsPane.openPanel() }

    let table = NSTableView()
    let addButton = NSButton(title: "Add Extension…", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let enabledCheckbox = NSButton(checkboxWithTitle: "On in this profile", target: nil, action: nil)
    let accessPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let sitesField = NSTextField()
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let optionsButton = NSButton(title: "Options", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?

    init(store: @escaping () -> ExtensionStore? = { nil }, profile: @escaping () -> Profile? = { nil },
         running: @escaping (Profile) -> ProfileExtensions? = { _ in nil }) {
        self.store = store
        self.profile = profile
        self.running = running
        super.init(nibName: nil, bundle: nil)
        title = "Extensions"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var items: [InstalledExtension] { store()?.installed ?? [] }
    var selected: InstalledExtension? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("extension"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Extensions")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        addButton.target = self
        addButton.action = #selector(add(_:))
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        accessPopUp.addItems(withTitles: [ExtensionSiteAccess.allRequested.title, ExtensionSiteAccess.onClick.title, ExtensionSiteAccess.sites([]).title])
        accessPopUp.target = self
        accessPopUp.action = #selector(accessChanged(_:))
        accessPopUp.setAccessibilityLabel("Where it can read and change pages")
        sitesField.placeholderString = "example.com, mail.example.org"
        sitesField.target = self
        sitesField.action = #selector(accessChanged(_:))
        sitesField.setAccessibilityLabel("Sites it can read and change")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        optionsButton.target = self
        optionsButton.action = #selector(openOptions(_:))
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        let accessTitle = NSTextField(labelWithString: "Site access:")
        let grid = NSGridView(views: [
            [NSGridCell.emptyContentView, enabledCheckbox],
            [accessTitle, accessPopUp],
            [NSGridCell.emptyContentView, sitesField],
            [NSGridCell.emptyContentView, detailLabel],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.cell(for: accessPopUp)?.xPlacement = .leading
        grid.row(at: 1).yPlacement = .center
        accessTitle.setContentCompressionResistancePriority(.required, for: .horizontal)
        let buttons = NSStackView(views: [addButton, removeButton, optionsButton, NSView()])
        let stack = NSStackView(views: [scroll, grid, buttons, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 560),
            scroll.widthAnchor.constraint(equalToConstant: 520),
            scroll.heightAnchor.constraint(equalToConstant: 170),
            sitesField.widthAnchor.constraint(equalToConstant: 380),
            detailLabel.widthAnchor.constraint(equalToConstant: 380),
            buttons.widthAnchor.constraint(equalToConstant: 520),
            statusLabel.widthAnchor.constraint(equalToConstant: 520),
        ])
        view = stack
        observer = NotificationCenter.default.addObserver(forName: ExtensionStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        let keep = selected?.id
        table.reloadData()
        let index = items.firstIndex { $0.id == keep } ?? (items.isEmpty ? -1 : 0)
        if index >= 0 { table.selectRowIndexes([index], byExtendingSelection: false) }
        syncDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let on = profile().map(item.isEnabled(in:)) ?? false
        let running = profile().flatMap(self.running)?.contexts[item.id]
        let icon = NSImageView(image: running?.webExtension.icon(for: NSSize(width: 28, height: 28))
                               ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil) ?? NSImage())
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let state = NSTextField(labelWithString: "\(item.version.isEmpty ? "" : "Version \(item.version) · ")\(on ? "On" : "Off")")
        state.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSStackView(views: [name, state])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        row.setAccessibilityLabel("\(item.name), \(on ? "on" : "off")")
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) { syncDetail() }

    private func syncDetail() {
        let item = selected
        for control in [removeButton, enabledCheckbox, accessPopUp, sitesField] as [NSControl] { control.isEnabled = item != nil }
        guard let item, let profile = profile() else {
            detailLabel.stringValue = items.isEmpty ? "Add an extension from its folder, a .zip, or a .crx file from the Chrome Web Store." : ""
            optionsButton.isHidden = true
            sitesField.isHidden = true
            return
        }
        let settings = store()?.settings(item.id, in: profile)
        enabledCheckbox.state = item.isEnabled(in: profile) ? .on : .off
        let access = settings?.access ?? .allRequested
        switch access {
        case .allRequested: accessPopUp.selectItem(at: 0)
        case .onClick: accessPopUp.selectItem(at: 1)
        case .sites(let hosts):
            accessPopUp.selectItem(at: 2)
            if sitesField.currentEditor() == nil { sitesField.stringValue = hosts.joined(separator: ", ") }
        }
        sitesField.isHidden = accessPopUp.indexOfSelectedItem != 2
        let running = self.running(profile)
        let context = running?.contexts[item.id]
        optionsButton.isHidden = context?.optionsPageURL == nil
        var lines = ExtensionPermissionWording.describe(permissions: Set(settings?.permissions ?? []),
                                                        matchPatterns: Set(context?.webExtension.allRequestedMatchPatterns.map(\.string) ?? []))
        if let error = running?.loadErrors[item.id] { lines.insert("It could not start: \(error)", at: 0) }
        detailLabel.stringValue = lines.isEmpty ? "" : "It can:\n" + lines.map { "•  " + $0 }.joined(separator: "\n")
    }

    // MARK: - Actions

    @objc func add(_ sender: Any?) {
        guard let source = chooseSource(), let store = store(), let profile = profile() else { return }
        statusLabel.stringValue = "Adding…"
        Task { @MainActor in
            do {
                let item = try await store.install(from: source, for: profile)
                statusLabel.stringValue = "“\(item.name)” was added to this profile."
            } catch ExtensionStore.InstallError.declined {
                statusLabel.stringValue = ""
            } catch {
                statusLabel.stringValue = error.localizedDescription
            }
            reload()
        }
    }

    @objc func remove(_ sender: Any?) {
        guard let item = selected else { return }
        store()?.remove(item.id)
        statusLabel.stringValue = "“\(item.name)” was removed from every profile."
    }

    @objc private func enabledChanged(_ sender: Any?) {
        guard let item = selected, let profile = profile() else { return }
        store()?.setEnabled(item.id, enabledCheckbox.state == .on, in: profile)
    }

    @objc private func accessChanged(_ sender: Any?) {
        guard let item = selected, let profile = profile() else { return }
        let access: ExtensionSiteAccess
        switch accessPopUp.indexOfSelectedItem {
        case 1: access = .onClick
        case 2: access = .sites(sitesField.stringValue.split { $0 == "," || $0.isWhitespace }.map(String.init).filter { !$0.isEmpty })
        default: access = .allRequested
        }
        store()?.setAccess(item.id, access, in: profile)
    }

    @objc private func openOptions(_ sender: Any?) {
        guard let item = selected, let profile = profile(), let running = running(profile), let context = running.contexts[item.id] else { return }
        running.webExtensionController(running.controller, openOptionsPageFor: context) { _ in }
    }

    static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .init(filenameExtension: "crx") ?? .data, .folder]
        panel.message = "Choose an extension’s folder (with its manifest.json), a .zip, or a .crx."
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
