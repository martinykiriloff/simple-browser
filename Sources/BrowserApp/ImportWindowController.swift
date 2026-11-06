import AppKit
import BrowserKit
import DataKit

/// The first launch, and File → Import From…: pick the browser you came
/// from and what to bring (bookmarks, history, open tabs, passwords). On
/// the first launch it also offers the search engine and making
/// Keel the default browser, and says so in a minute's reading.
@MainActor
final class ImportWindowController: NSWindowController {
    enum Mode { case firstRun, importOnly }

    let importer: BrowserImporter
    /// The profile things are brought into: the window in front's.
    var profile: () -> Profile
    /// Every browser profile on this Mac. Tests point it at fixtures.
    var findSources: () -> [BrowserImport.Source] = { BrowserImport.sources() }
    /// Passwords from a file exported by any browser or password manager.
    var importPasswordFile: (() -> Void)?
    /// Bookmarks from a file exported by any browser: the universal path,
    /// for a browser not on this Mac, or one Keel does not read on disk.
    var importBookmarkFile: (() -> Void)?
    /// Makes this app the default for web links: `NSWorkspace`, or a stand-in in tests.
    var makeDefaultBrowser: @MainActor () async -> Bool = { await ImportWindowController.setAsDefaultBrowser() }
    var isDefaultBrowser: @MainActor () -> Bool = { ImportWindowController.isTheDefaultBrowser() }
    var onFinish: (() -> Void)?

    private(set) var mode: Mode = .importOnly
    private(set) var sources: [BrowserImport.Source] = []
    private(set) var lastResult: BrowserImporter.Result?
    private(set) var isImporting = false

    let headline = NSTextField(labelWithString: "")
    let intro = NSTextField(wrappingLabelWithString: "")
    let sourcePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let bookmarksBox = NSButton(checkboxWithTitle: "Bookmarks and favorites", target: nil, action: nil)
    let historyBox = NSButton(checkboxWithTitle: "History, and so your most visited sites", target: nil, action: nil)
    let tabsBox = NSButton(checkboxWithTitle: "Open tabs", target: nil, action: nil)
    let passwordsBox = NSButton(checkboxWithTitle: "Passwords", target: nil, action: nil)
    let note = NSTextField(wrappingLabelWithString: "")
    let noteButton = NSButton(title: "", target: nil, action: nil)
    let importButton = NSButton(title: "Import", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    let resultLabel = NSTextField(wrappingLabelWithString: "")
    let enginePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let defaultButton = NSButton(title: "Make Keel the Default Browser", target: nil, action: nil)
    let defaultLabel = NSTextField(labelWithString: "")
    let doneButton = NSButton(title: "Start Browsing", target: nil, action: nil)
    let fileLabel = NSTextField(wrappingLabelWithString: "Or bring in a file you exported from another browser — this works for any browser, even one not on this Mac.")
    let bookmarkFileButton = NSButton(title: "Import Bookmarks from a File…", target: nil, action: nil)
    let passwordFileButton = NSButton(title: "Import Passwords from a File…", target: nil, action: nil)
    private var firstRunRows: [NSView] = []
    /// The grid rows the first launch adds (search engine, default browser),
    /// collapsed when importing later so the window is not left with a gap.
    private var firstRunGridRows: [NSGridRow] = []

    init(importer: BrowserImporter, profile: @escaping () -> Profile) {
        self.importer = importer
        self.profile = profile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 512), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        QuietMode.apply(to: window)
        window.isReleasedWhenClosed = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    private func build() {
        headline.font = .systemFont(ofSize: 22, weight: .semibold)
        intro.textColor = .secondaryLabelColor
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged(_:))
        sourcePopUp.setAccessibilityLabel("Import from")
        for box in [bookmarksBox, historyBox, tabsBox, passwordsBox] { box.state = .on; box.target = self; box.action = #selector(partsChanged(_:)) }
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteButton.target = self
        noteButton.action = #selector(noteAction(_:))
        importButton.target = self
        importButton.action = #selector(importClicked(_:))
        importButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        resultLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        enginePopUp.addItems(withTitles: SearchEngine.all.map(\.name))
        // The rows are filled again in `show`, which may add one the person
        // cannot choose; the menu must not enable it again behind our back.
        enginePopUp.menu?.autoenablesItems = false
        enginePopUp.target = self
        enginePopUp.action = #selector(engineChanged(_:))
        enginePopUp.setAccessibilityLabel("Search engine")
        defaultButton.target = self
        defaultButton.action = #selector(makeDefault(_:))
        defaultLabel.textColor = .secondaryLabelColor
        defaultLabel.lineBreakMode = .byTruncatingTail
        defaultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        defaultButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.target = self
        doneButton.action = #selector(finish(_:))
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bookmarkFileButton.target = self
        bookmarkFileButton.action = #selector(importBookmarkFileClicked(_:))
        bookmarkFileButton.bezelStyle = .rounded
        passwordFileButton.target = self
        passwordFileButton.action = #selector(importPasswordFileClicked(_:))
        passwordFileButton.bezelStyle = .rounded

        let fromTitle = NSTextField(labelWithString: "Import from:")
        let bringTitle = NSTextField(labelWithString: "Bring over:")
        let engineTitle = NSTextField(labelWithString: "Search with:")
        let defaultTitle = NSTextField(labelWithString: "Default browser:")
        let importRow = NSStackView(views: [importButton, spinner, resultLabel])
        importRow.spacing = 8
        let defaultRow = NSStackView(views: [defaultButton, defaultLabel])
        defaultRow.spacing = 8
        let grid = NSGridView(views: [
            [fromTitle, sourcePopUp],
            [bringTitle, bookmarksBox],
            [NSGridCell.emptyContentView, historyBox],
            [NSGridCell.emptyContentView, tabsBox],
            [NSGridCell.emptyContentView, passwordsBox],
            [NSGridCell.emptyContentView, note],
            [NSGridCell.emptyContentView, noteButton],
            [NSGridCell.emptyContentView, importRow],
            [engineTitle, enginePopUp],
            [defaultTitle, defaultRow],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for row in 0..<grid.numberOfRows {
            grid.cell(atColumnIndex: 0, rowIndex: row).contentView?.setContentCompressionResistancePriority(.required, for: .horizontal)
            grid.cell(atColumnIndex: 1, rowIndex: row).xPlacement = .leading
        }
        grid.cell(for: note)?.xPlacement = .fill
        grid.cell(for: importRow)?.xPlacement = .fill
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 7).topPadding = 6
        grid.row(at: 8).topPadding = 18
        grid.row(at: 8).yPlacement = .center
        grid.row(at: 9).yPlacement = .center
        firstRunRows = [engineTitle, enginePopUp, defaultTitle, defaultRow]
        firstRunGridRows = [grid.row(at: 8), grid.row(at: 9)]

        let separator = NSBox()
        separator.boxType = .separator
        let fileButtons = NSStackView(views: [bookmarkFileButton, passwordFileButton])
        fileButtons.spacing = 10
        let fileSection = NSStackView(views: [fileLabel, fileButtons])
        fileSection.orientation = .vertical
        fileSection.alignment = .leading
        fileSection.spacing = 8
        let buttons = NSStackView(views: [NSView(), doneButton])
        let stack = NSStackView(views: [headline, intro, grid, separator, fileSection, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        stack.setCustomSpacing(20, after: intro)
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(18, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 580),
            intro.widthAnchor.constraint(equalToConstant: 524),
            note.widthAnchor.constraint(equalToConstant: 400),
            resultLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            buttons.widthAnchor.constraint(equalToConstant: 524),
            separator.widthAnchor.constraint(equalToConstant: 524),
            fileLabel.widthAnchor.constraint(equalToConstant: 524),
        ])
        window?.contentView = root
    }

    // MARK: - Showing

    func show(_ mode: Mode) {
        self.mode = mode
        sources = findSources()
        sourcePopUp.removeAllItems()
        sourcePopUp.addItems(withTitles: sources.map(\.title))
        let firstRun = mode == .firstRun
        window?.title = firstRun ? "Welcome to Keel" : "Import"
        headline.stringValue = firstRun ? "Welcome to Keel" : "Import from Another Browser"
        intro.stringValue = firstRun
            ? "Bring your bookmarks, history, open tabs and passwords from the browser you use now, straight from its files: nothing to export. You can do this again at any time from File → Import From…."
            : "Bookmarks, history, open tabs and passwords, straight from the other browser’s files. Nothing already here is duplicated."
        for view in firstRunRows { view.isHidden = !firstRun }
        for row in firstRunGridRows { row.isHidden = !firstRun }
        window?.setContentSize(NSSize(width: 580, height: firstRun ? 512 : 448))
        doneButton.title = firstRun ? "Start Browsing" : "Done"
        // An engine of the person's own (Settings → General) is none of the
        // built-in rows, so it gets a row of its own, named after its site:
        // without it the pop-up would say DuckDuckGo while the setting said
        // otherwise. The row is not chooseable here — only Settings has the
        // box to type the address in — but picking a built-in engine still
        // replaces it.
        let current = BrowserSettings.searchEngine
        enginePopUp.removeAllItems()
        enginePopUp.addItems(withTitles: SearchEngine.all.map(\.name))
        if let index = SearchEngine.all.firstIndex(where: { $0.id == current.id }) {
            enginePopUp.selectItem(at: index)
        } else {
            enginePopUp.addItem(withTitle: "Custom — \(current.name)")
            enginePopUp.lastItem?.isEnabled = false
            enginePopUp.selectItem(at: enginePopUp.numberOfItems - 1)
        }
        syncDefault()
        bookmarkFileButton.isEnabled = importBookmarkFile != nil
        passwordFileButton.isEnabled = importPasswordFile != nil
        resultLabel.stringValue = ""
        lastResult = nil
        sourceChanged(nil)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    var selectedSource: BrowserImport.Source? {
        sources.indices.contains(sourcePopUp.indexOfSelectedItem) ? sources[sourcePopUp.indexOfSelectedItem] : nil
    }

    var parts: BrowserImport.Parts {
        var parts: BrowserImport.Parts = []
        if bookmarksBox.state == .on { parts.insert(.bookmarks) }
        if historyBox.state == .on { parts.insert(.history) }
        if tabsBox.state == .on && tabsBox.isEnabled { parts.insert(.openTabs) }
        if passwordsBox.state == .on && passwordsBox.isEnabled { parts.insert(.passwords) }
        return parts
    }

    /// What the chosen browser allows, and what it takes.
    @objc private func sourceChanged(_ sender: Any?) {
        guard let source = selectedSource else {
            for box in [bookmarksBox, historyBox, tabsBox, passwordsBox] { box.isEnabled = false }
            note.stringValue = "No other browser was found on this Mac. You can still bring in bookmarks or passwords you exported from any browser to a file — see below."
            noteButton.title = ""
            importButton.isEnabled = false
            setNoteButtonHidden(true)
            return
        }
        let blocked = source.needsFullDiskAccess
        bookmarksBox.isEnabled = !blocked
        historyBox.isEnabled = !blocked
        tabsBox.isEnabled = !blocked && source.offersOpenTabs
        passwordsBox.isEnabled = !blocked && source.offersPasswords
        if blocked {
            note.stringValue = "macOS keeps Safari’s bookmarks and history from other apps. To bring them over, give Keel Full Disk Access in System Settings → Privacy & Security, then come back here."
            noteButton.title = "Open Privacy Settings"
        } else if source.offersPasswords {
            note.stringValue = "\(source.browser.name) keeps its passwords’ key in your Keychain: macOS will ask you to allow Keel to use it, once."
            noteButton.title = ""
        } else {
            let name = source.browser.name
            note.stringValue = source.browser == .safari
                ? "Safari’s passwords live in the Passwords app, which other apps cannot read. To bring them over, open Passwords, choose File → Export All Passwords to File…, then use “Import Passwords from a File…” below."
                : "\(name) keeps its passwords for itself. To bring them over, open its passwords page (about:logins), choose Export…, then use “Import Passwords from a File…” below."
            noteButton.title = ""
        }
        setNoteButtonHidden(blocked == false)
        partsChanged(nil)
    }

    @objc private func partsChanged(_ sender: Any?) {
        importButton.isEnabled = !isImporting && selectedSource.map { !$0.needsFullDiskAccess } == true && !parts.isEmpty
    }

    @objc private func noteAction(_ sender: Any?) {
        if selectedSource?.needsFullDiskAccess == true {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        } else {
            importPasswordFile?()
        }
    }

    @objc func importBookmarkFileClicked(_ sender: Any?) { importBookmarkFile?() }
    @objc func importPasswordFileClicked(_ sender: Any?) { importPasswordFile?() }

    private func setNoteButtonHidden(_ hidden: Bool) {
        noteButton.isHidden = hidden
        (noteButton.superview as? NSGridView)?.cell(for: noteButton)?.row?.isHidden = hidden
    }

    @objc func importClicked(_ sender: Any?) {
        guard let source = selectedSource, !isImporting else { return }
        let parts = parts
        isImporting = true
        partsChanged(nil)
        spinner.startAnimation(nil)
        resultLabel.stringValue = "Bringing things over from \(source.browser.name)…"
        Task { @MainActor in
            let result = await importer.run(source, parts: parts, into: profile())
            lastResult = result
            isImporting = false
            spinner.stopAnimation(nil)
            resultLabel.stringValue = result.summary
            partsChanged(nil)
        }
    }

    // MARK: - First launch

    @objc private func engineChanged(_ sender: Any?) {
        guard SearchEngine.all.indices.contains(enginePopUp.indexOfSelectedItem) else { return }
        BrowserSettings.searchEngine = SearchEngine.all[enginePopUp.indexOfSelectedItem]
    }

    @objc func makeDefault(_ sender: Any?) {
        Task { @MainActor in
            _ = await makeDefaultBrowser()
            syncDefault()
        }
    }

    private func syncDefault() {
        let isDefault = isDefaultBrowser()
        defaultButton.isHidden = isDefault
        defaultLabel.stringValue = isDefault ? "Keel opens your web links." : ""
    }

    @objc func finish(_ sender: Any?) {
        window?.close()
        onFinish?()
    }

    // MARK: - The default browser

    /// Web links, and the web page files, open here. macOS asks the person
    /// to confirm, in its own dialog.
    static func setAsDefaultBrowser() async -> Bool {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return false }
        for scheme in ["http", "https"] {
            do { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) } catch { return false }
        }
        return true
    }

    static func isTheDefaultBrowser() -> Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}
