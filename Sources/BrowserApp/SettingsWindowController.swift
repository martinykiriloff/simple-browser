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

    enum Pane: Int { case general, passwords }

    private let tabs = SettingsTabViewController()
    let passwordsPane: PasswordsSettingsPane

    init(passwords: PasswordService) {
        passwordsPane = PasswordsSettingsPane(service: passwords)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 215),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let general = NSViewController()
        general.view = buildContent()
        general.title = "General"
        tabs.tabStyle = .segmentedControlOnTop
        tabs.addChild(general)
        tabs.addChild(passwordsPane)
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

        let grid = NSGridView(views: [
            [title, homepageField],
            [NSGridCell.emptyContentView, resolvedLabel],
            [NSGridCell.emptyContentView, buttons],
            [NSGridCell.emptyContentView, help],
            [newWindowTitle, newWindowPopUp],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 2).topPadding = 2
        grid.cell(for: buttons)?.xPlacement = .leading
        grid.row(at: 4).topPadding = 10
        grid.row(at: 4).yPlacement = .center
        grid.cell(for: newWindowPopUp)?.xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            homepageField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            root.widthAnchor.constraint(equalToConstant: 560),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])
        return root
    }

    // MARK: - State

    private func refresh() {
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
