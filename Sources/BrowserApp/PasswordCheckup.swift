import AppKit
import PasswordKit

/// Settings → Passwords → Checkup…: which saved passwords are
/// leaked, reused or weak, worst first, and a way to go and change each one.
///
/// Nothing is fixed from here. A password can only really be changed on the
/// site, so the sheet's job is to say which ones and take the person there.
@MainActor
final class PasswordCheckupViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let service: PasswordService
    /// Selects the entry in the Passwords list behind the sheet.
    var onShowInList: ((Credential) -> Void)?

    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let leakCheckbox = NSButton(checkboxWithTitle: "Check for leaked passwords online", target: nil, action: nil)
    let tableView = NSTableView()
    let changeButton = NSButton(title: "Change on Site", target: nil, action: nil)
    let showButton = NSButton(title: "Show in List", target: nil, action: nil)
    let recheckButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private(set) var report: PasswordAuditReport?
    private var running = false

    init(service: PasswordService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
        title = "Password Checkup"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Password Checkup")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        leakCheckbox.target = self
        leakCheckbox.action = #selector(toggleLeakCheck(_:))
        leakCheckbox.state = BrowserSettings.checkLeakedPasswords ? .on : .off
        let leakHelp = NSTextField(wrappingLabelWithString:
            "Asks Have I Been Pwned using only the first 5 characters of each password’s SHA-1 hash. Your passwords, and their full hashes, never leave this Mac.")
        leakHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        leakHelp.textColor = .secondaryLabelColor

        for (identifier, title, width) in [("site", "Website", 170.0), ("username", "Username", 150.0), ("problem", "Problem", 280.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 80
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.target = self
        tableView.doubleAction = #selector(changeOnSite(_:))
        tableView.setAccessibilityLabel("Passwords with problems")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [(changeButton, #selector(changeOnSite(_:))), (showButton, #selector(showInList(_:))),
                                 (recheckButton, #selector(recheck(_:)))] {
            button.target = self
            button.action = action
        }
        changeButton.toolTip = "Open the site to change this password there. Update it here afterwards, or accept the offer to update it when you sign in."
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [changeButton, showButton, spacer, spinner, recheckButton, done])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, summaryLabel, scroll, leakCheckbox, leakHelp, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: leakCheckbox)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 660),
            summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 240),
            leakHelp.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 40),
            leakHelp.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = root
        summaryLabel.stringValue = "Checking…"
        updateButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if report == nil && !running { run() }
    }

    /// Returns once the report is shown, or the person declined to authenticate.
    @discardableResult
    func run() -> Task<Void, Never> {
        running = true
        spinner.startAnimation(nil)
        recheckButton.isEnabled = false
        summaryLabel.stringValue = "Checking…"
        return Task { @MainActor in
            defer {
                running = false
                spinner.stopAnimation(nil)
                recheckButton.isEnabled = true
            }
            do {
                guard let report = try await service.checkup(checkLeaks: leakCheckbox.state == .on) else {
                    summaryLabel.stringValue = "Checking needs your Mac password or Touch ID, because it reads every saved password."
                    return
                }
                self.report = report
                summaryLabel.stringValue = Self.summary(of: report)
                summaryLabel.textColor = report.issues.isEmpty ? .labelColor : (report.compromised > 0 ? .systemRed : .labelColor)
            } catch {
                summaryLabel.stringValue = PasswordCoordinator.describe(error)
                summaryLabel.textColor = .systemRed
            }
            tableView.reloadData()
            updateButtons()
        }
    }

    static func summary(of report: PasswordAuditReport) -> String {
        var parts: [String] = []
        if report.compromised > 0 { parts.append("\(report.compromised) leaked") }
        if report.reused > 0 { parts.append("\(report.reused) reused") }
        if report.weak > 0 { parts.append("\(report.weak) weak") }
        let checked = report.checked == 1 ? "1 password" : "\(report.checked) passwords"
        var text = parts.isEmpty ? "No problems found in \(checked)." : "Checked \(checked): " + parts.joined(separator: ", ") + "."
        if report.compromised > 0 {
            text += " Change leaked passwords first: they are on lists attackers try against every site."
        }
        if let error = report.breachCheckError {
            text += " " + error + " Leaks were not checked."
        } else if !report.breachChecked && report.checked > 0 {
            text += " Leaks were not checked."
        }
        return text
    }

    static func describe(_ kind: PasswordIssue.Kind) -> String {
        switch kind {
        case .compromised(let count):
            return "Leaked" + (count > 1 ? " (seen \(count.formatted()) times)" : "")
        case .reused(let sites):
            let shown = sites.prefix(2).joined(separator: ", ")
            return "Also used on " + shown + (sites.count > 2 ? " and \(sites.count - 2) more" : "")
        case .weak(let reasons):
            return "Weak: " + reasons.map(\.explanation).joined(separator: ", ")
        }
    }

    // MARK: - Table

    private var issues: [PasswordIssue] { report?.issues ?? [] }

    func numberOfRows(in tableView: NSTableView) -> Int { issues.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, issues.indices.contains(row) else { return nil }
        let issue = issues[row]
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        switch identifier.rawValue {
        case "site":
            label.stringValue = issue.credential.site
            label.toolTip = issue.credential.origin
        case "username":
            label.stringValue = issue.credential.username.isEmpty ? "No username" : issue.credential.username
            label.textColor = issue.credential.username.isEmpty ? .secondaryLabelColor : .labelColor
        default:
            label.stringValue = issue.kinds.map(Self.describe).joined(separator: " · ")
            label.toolTip = issue.kinds.map(Self.describe).joined(separator: "\n")
            if issue.severity == 3 { label.textColor = .systemRed }
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private var selected: PasswordIssue? {
        issues.indices.contains(tableView.selectedRow) ? issues[tableView.selectedRow] : nil
    }

    private func updateButtons() {
        changeButton.isEnabled = selected != nil
        showButton.isEnabled = selected != nil
    }

    // MARK: - Actions

    @objc private func toggleLeakCheck(_ sender: Any?) {
        BrowserSettings.checkLeakedPasswords = leakCheckbox.state == .on
    }

    @objc private func changeOnSite(_ sender: Any?) {
        guard let issue = selected, let url = URL(string: issue.credential.origin + "/") else { return }
        (NSApp.delegate as? AppDelegate)?.openInBrowser(url)
    }

    @objc private func showInList(_ sender: Any?) {
        guard let issue = selected else { return }
        dismiss(nil)
        onShowInList?(issue.credential)
    }

    @objc private func recheck(_ sender: Any?) { run() }

    @objc private func done(_ sender: Any?) { dismiss(nil) }
}
