import AppKit
import BrowserKit

/// The Settings window (⌘,). Two panes: General, with the homepage and what
/// new windows start with, and Passwords.
///
/// Changes apply as you type, as macOS settings do; there is no Save button.
/// The line under the field always says where Home will actually go, so a
/// typo or an empty field is never a silent surprise.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {

    /// Supplies the frontmost page's URL for "Set to Current Page".
    var currentPageURL: (() -> URL?)?
    /// Runs before the window shows and whenever it becomes key, so the
    /// Passwords pane can follow the profile of the browser window in front.
    var willShow: (() -> Void)?

    private let homepageField = NSTextField()
    private let resolvedLabel = NSTextField(labelWithString: "")
    private let useCurrentButton = NSButton(title: "Set to Current Page", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Default", target: nil, action: nil)
    private let newWindowPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let startupPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let enginePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let customEngineField = NSTextField()
    let suggestionsCheckbox = NSButton(checkboxWithTitle: "Show search suggestions as you type", target: nil, action: nil)
    let downloadFolderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let askWhereCheckbox = NSButton(checkboxWithTitle: "Ask where to save each file", target: nil, action: nil)
    /// Replaces the folder panel, for the self-test.
    var chooseDownloadFolder: (() -> URL?)?
    let memorySaverCheckbox = NSButton(checkboxWithTitle: "Put inactive tabs to sleep to save memory", target: nil, action: nil)
    let keepActiveField = NSTextField()

    enum Pane: Int { case general, passwords, privacy, websites }

    private let tabs = SettingsTabViewController()
    let passwordsPane: PasswordsSettingsPane
    let privacyPane: PrivacySettingsPane
    let websitesPane = WebsitesSettingsPane()

    init(passwords: PasswordService, blocker: ContentBlocker) {
        passwordsPane = PasswordsSettingsPane(service: passwords)
        privacyPane = PrivacySettingsPane(blocker: blocker)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 215),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        QuietMode.apply(to: window)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let general = NSViewController()
        general.view = buildContent()
        general.title = "General"
        tabs.tabStyle = .segmentedControlOnTop
        tabs.addChild(general)
        tabs.addChild(passwordsPane)
        tabs.addChild(privacyPane)
        tabs.addChild(websitesPane)
        window.contentViewController = tabs
        window.title = "Settings"
        if !window.setFrameUsingName("SettingsWindow") { window.center() }
        window.setFrameAutosaveName("SettingsWindow")
        // The saved frame's size belongs to whichever pane was showing.
        tabs.fitWindowToSelectedPane(animated: false)
        refresh()
    }

    func show(_ pane: Pane, sender: Any? = nil) {
        tabs.selectedTabViewItemIndex = pane.rawValue
        showWindow(sender)
    }

    var selectedPane: Pane { Pane(rawValue: tabs.selectedTabViewItemIndex) ?? .general }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func showWindow(_ sender: Any?) {
        willShow?()
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let title = NSTextField(labelWithString: "Homepage:")
        title.alignment = .right
        title.font = .systemFont(ofSize: NSFont.systemFontSize)

        homepageField.placeholderString = HomePage.defaultAddress
        homepageField.delegate = self
        homepageField.usesSingleLineMode = true
        homepageField.lineBreakMode = .byTruncatingTail
        homepageField.setAccessibilityLabel("Homepage")

        resolvedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resolvedLabel.textColor = .secondaryLabelColor
        resolvedLabel.lineBreakMode = .byTruncatingMiddle

        useCurrentButton.target = self
        useCurrentButton.action = #selector(useCurrentPage(_:))
        resetButton.target = self
        resetButton.action = #selector(resetToDefault(_:))
        let buttons = NSStackView(views: [useCurrentButton, resetButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let help = NSTextField(wrappingLabelWithString:
            "The Home button in the toolbar (and History → Home, ⇧⌘H) opens this page. "
            + "Leave it empty to use the default.")
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor

        let newWindowTitle = NSTextField(labelWithString: "New windows open with:")
        newWindowTitle.alignment = .right
        newWindowPopUp.addItems(withTitles: BrowserSettings.NewWindowContent.allCases.map(\.title))
        newWindowPopUp.target = self
        newWindowPopUp.action = #selector(newWindowContentChanged(_:))
        newWindowPopUp.setAccessibilityLabel("New windows open with")

        let startupTitle = NSTextField(labelWithString: "SimpleBrowser opens with:")
        startupTitle.alignment = .right
        startupPopUp.addItems(withTitles: ["All windows from last time", "A new window"])
        startupPopUp.target = self
        startupPopUp.action = #selector(startupChanged(_:))
        startupPopUp.setAccessibilityLabel("SimpleBrowser opens with")

        let engineTitle = NSTextField(labelWithString: "Search engine:")
        engineTitle.alignment = .right
        enginePopUp.addItems(withTitles: SearchEngine.all.map(\.name) + ["Custom…"])
        enginePopUp.target = self
        enginePopUp.action = #selector(engineChanged(_:))
        enginePopUp.setAccessibilityLabel("Search engine")
        customEngineField.placeholderString = "https://search.example/?q=%s"
        customEngineField.delegate = self
        customEngineField.setAccessibilityLabel("Custom search address, with %s for the words")
        suggestionsCheckbox.target = self
        suggestionsCheckbox.action = #selector(suggestionsChanged(_:))

        let memoryTitle = NSTextField(labelWithString: "Memory Saver:")
        memoryTitle.alignment = .right
        memorySaverCheckbox.target = self
        memorySaverCheckbox.action = #selector(memorySaverChanged(_:))
        keepActiveField.placeholderString = "Always keep these sites active, e.g. music.example.com, mail.example.com"
        keepActiveField.delegate = self
        keepActiveField.setAccessibilityLabel("Always keep these sites active")
        let memoryHelp = NSTextField(wrappingLabelWithString:
            "Tabs you have not used for a while, or more than a dozen in the background, sleep and wake as they were when you open them. "
            + "Tabs playing sound, using the camera or holding a half-filled form never sleep.")
        memoryHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        memoryHelp.textColor = .secondaryLabelColor

        let downloadsTitle = NSTextField(labelWithString: "Save downloads to:")
        downloadsTitle.alignment = .right
        downloadFolderPopUp.target = self
        downloadFolderPopUp.action = #selector(downloadFolderChanged(_:))
        downloadFolderPopUp.setAccessibilityLabel("Save downloads to")
        askWhereCheckbox.target = self
        askWhereCheckbox.action = #selector(askWhereChanged(_:))

        let grid = NSGridView(views: [
            [startupTitle, startupPopUp],
            [title, homepageField],
            [NSGridCell.emptyContentView, resolvedLabel],
            [NSGridCell.emptyContentView, buttons],
            [NSGridCell.emptyContentView, help],
            [newWindowTitle, newWindowPopUp],
            [engineTitle, enginePopUp],
            [NSGridCell.emptyContentView, customEngineField],
            [NSGridCell.emptyContentView, suggestionsCheckbox],
            [downloadsTitle, downloadFolderPopUp],
            [NSGridCell.emptyContentView, askWhereCheckbox],
            [memoryTitle, memorySaverCheckbox],
            [NSGridCell.emptyContentView, keepActiveField],
            [NSGridCell.emptyContentView, memoryHelp],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        // The longest title is shown whole; the fields take what is left.
        for row in 0..<grid.numberOfRows {
            grid.cell(atColumnIndex: 0, rowIndex: row).contentView?.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        grid.cell(for: startupPopUp)?.xPlacement = .leading
        grid.row(at: 1).topPadding = 12
        grid.row(at: 1).yPlacement = .center
        grid.row(at: 3).topPadding = 2
        grid.cell(for: buttons)?.xPlacement = .leading
        grid.row(at: 5).topPadding = 10
        grid.row(at: 5).yPlacement = .center
        grid.cell(for: newWindowPopUp)?.xPlacement = .leading
        grid.cell(for: enginePopUp)?.xPlacement = .leading
        grid.row(at: 6).topPadding = 12
        grid.row(at: 6).yPlacement = .center
        grid.cell(for: suggestionsCheckbox)?.xPlacement = .leading
        grid.row(at: 9).topPadding = 12
        grid.row(at: 9).yPlacement = .center
        grid.cell(for: downloadFolderPopUp)?.xPlacement = .leading
        grid.cell(for: askWhereCheckbox)?.xPlacement = .leading
        grid.row(at: 11).topPadding = 12
        grid.cell(for: memorySaverCheckbox)?.xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            homepageField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            root.widthAnchor.constraint(equalToConstant: 560),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])
        return root
    }

    // MARK: - State

    @objc private func engineChanged(_ sender: Any?) {
        let index = enginePopUp.indexOfSelectedItem
        if SearchEngine.all.indices.contains(index) {
            BrowserSettings.searchEngine = SearchEngine.all[index]
        } else {
            BrowserSettings.searchEngine = SearchEngine(id: "custom", name: "Custom", searchTemplate: "", suggestTemplate: nil)
            window?.makeFirstResponder(customEngineField)
        }
        showCustomEngine(BrowserSettings.searchEngine.id == "custom" || index >= SearchEngine.all.count)
    }

    /// The field has a row of its own, which closes up when there is nothing in it to show.
    private func showCustomEngine(_ shown: Bool) {
        customEngineField.isHidden = !shown
        guard let row = (customEngineField.superview as? NSGridView)?.cell(for: customEngineField)?.row, row.isHidden == shown else { return }
        row.isHidden = !shown
        tabs.fitWindowToSelectedPane(animated: true)
    }

    /// The folder chosen, then "Choose…": as the Finder's own folder menus are.
    private func fillDownloadFolders() {
        let folder = BrowserSettings.downloadFolder
        downloadFolderPopUp.removeAllItems()
        downloadFolderPopUp.addItem(withTitle: FileManager.default.displayName(atPath: folder.path))
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        downloadFolderPopUp.lastItem?.image = icon
        downloadFolderPopUp.lastItem?.toolTip = folder.path
        downloadFolderPopUp.menu?.addItem(.separator())
        downloadFolderPopUp.addItem(withTitle: "Choose…")
        downloadFolderPopUp.selectItem(at: 0)
        downloadFolderPopUp.isEnabled = !BrowserSettings.askWhereToSave
    }

    @objc private func downloadFolderChanged(_ sender: Any?) {
        defer { fillDownloadFolders() }
        guard downloadFolderPopUp.titleOfSelectedItem == "Choose…" else { return }
        if let chooseDownloadFolder {
            if let folder = chooseDownloadFolder() { BrowserSettings.downloadFolder = folder }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = BrowserSettings.downloadFolder
        if panel.runModal() == .OK, let folder = panel.url { BrowserSettings.downloadFolder = folder }
    }

    @objc private func askWhereChanged(_ sender: Any?) {
        BrowserSettings.askWhereToSave = askWhereCheckbox.state == .on
        fillDownloadFolders()
    }

    @objc private func suggestionsChanged(_ sender: Any?) {
        BrowserSettings.searchSuggestions = suggestionsCheckbox.state == .on
    }

    @objc private func startupChanged(_ sender: Any?) {
        BrowserSettings.startup = startupPopUp.indexOfSelectedItem == 1 ? .newWindow : .lastSession
    }

    @objc private func memorySaverChanged(_ sender: Any?) {
        BrowserSettings.memorySaver = memorySaverCheckbox.state == .on
        keepActiveField.isEnabled = BrowserSettings.memorySaver
    }

    private func refresh() {
        startupPopUp.selectItem(at: BrowserSettings.startup == .newWindow ? 1 : 0)
        let stored = BrowserSettings.store.string(forKey: "settings.search.engine") ?? SearchEngine.default.id
        enginePopUp.selectItem(at: stored == "custom" ? SearchEngine.all.count : SearchEngine.all.firstIndex { $0.id == stored } ?? 0)
        customEngineField.stringValue = BrowserSettings.customSearchTemplate
        showCustomEngine(stored == "custom")
        suggestionsCheckbox.state = BrowserSettings.searchSuggestions ? .on : .off
        askWhereCheckbox.state = BrowserSettings.askWhereToSave ? .on : .off
        fillDownloadFolders()
        memorySaverCheckbox.state = BrowserSettings.memorySaver ? .on : .off
        keepActiveField.stringValue = BrowserSettings.keepActiveSites.joined(separator: ", ")
        keepActiveField.isEnabled = BrowserSettings.memorySaver
        homepageField.stringValue = BrowserSettings.homepage
        let contents = BrowserSettings.NewWindowContent.allCases
        newWindowPopUp.selectItem(at: contents.firstIndex(of: BrowserSettings.newWindowContent) ?? 0)
        updateResolved()
    }

    private func updateResolved() {
        let typed = homepageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            resolvedLabel.stringValue = "Home opens the default: \(HomePage.defaultAddress)"
            resolvedLabel.textColor = .secondaryLabelColor
        } else if let url = HomePage.custom(typed) {
            resolvedLabel.stringValue = "Home opens \(url.absoluteString)"
            resolvedLabel.textColor = .secondaryLabelColor
        } else {
            resolvedLabel.stringValue = "That is not a web address, so Home will open the default: \(HomePage.defaultAddress)"
            resolvedLabel.textColor = .systemOrange
        }
        resetButton.isEnabled = !typed.isEmpty
        useCurrentButton.isEnabled = currentPageURL?() != nil
    }

    // MARK: - Actions

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === customEngineField {
            BrowserSettings.customSearchTemplate = customEngineField.stringValue
            return
        }
        if (notification.object as? NSTextField) === keepActiveField {
            // Hosts, however they were typed: "https://Music.example.com/x" is music.example.com.
            BrowserSettings.keepActiveSites = keepActiveField.stringValue
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                .compactMap { entry in
                    let text = String(entry)
                    return (URL(string: text.contains("://") ? text : "https://" + text)?.host()).flatMap { $0.isEmpty ? nil : $0 }
                }
            return
        }
        BrowserSettings.homepage = homepageField.stringValue
        updateResolved()
    }

    @objc private func useCurrentPage(_ sender: Any?) {
        guard let url = currentPageURL?() else { return }
        homepageField.stringValue = url.absoluteString
        BrowserSettings.homepage = url.absoluteString
        updateResolved()
    }

    @objc private func newWindowContentChanged(_ sender: Any?) {
        let contents = BrowserSettings.NewWindowContent.allCases
        guard contents.indices.contains(newWindowPopUp.indexOfSelectedItem) else { return }
        BrowserSettings.newWindowContent = contents[newWindowPopUp.indexOfSelectedItem]
    }

    @objc private func resetToDefault(_ sender: Any?) {
        homepageField.stringValue = ""
        BrowserSettings.homepage = ""
        updateResolved()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        willShow?()
        updateResolved()   // the frontmost page may have changed
    }
}

/// Each pane has its own natural size; the window follows the selected one,
/// growing downwards from a fixed title bar as System Settings' panes do.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindowToSelectedPane(animated: true)
    }

    func fitWindowToSelectedPane(animated: Bool) {
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
        window.title = "Settings"
    }
}
