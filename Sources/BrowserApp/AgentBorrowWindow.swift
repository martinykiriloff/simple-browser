import AppKit
import AgentKit

/// Lending signed-in origins (G2-04): which of the person's sites an agent
/// session may act on as them, and for how long.
@MainActor
final class AgentBorrowController {
    static let shared = AgentBorrowController()

    private var dialog: AgentDialog?
    private var flow: BorrowFlow?

    func show(trust: AgentTrust, live: AgentTrust.Live, profileTabs: [BrowserWindowController], preselect: [String] = [],
              handing: BrowserWindowController? = nil) {
        dialog?.close()
        let dialog = AgentDialog(title: "Lend Signed-in Sessions", width: 560)
        dialog.onClose = { [weak self, weak dialog] in
            guard let self, self.dialog === dialog else { return }
            self.dialog = nil
            self.flow = nil
        }
        self.dialog = dialog
        let flow = BorrowFlow(dialog: dialog, trust: trust, live: live, profileTabs: profileTabs, preselect: preselect, handing: handing)
        self.flow = flow
        NSApp.activate()
        flow.start()
    }
}

@MainActor
private final class BorrowFlow {
    private struct Candidate {
        let origin: String
        /// A tab of the person's on it, to say where it comes from.
        let tabTitle: String?
        let lendable: Bool
    }

    private let dialog: AgentDialog
    private let trust: AgentTrust
    private weak var live: AgentTrust.Live?
    private weak var handing: BrowserWindowController?
    private let sessionID: String
    private let candidates: [Candidate]
    private var picked: Set<String>
    /// 15, 60, or nil: until the person stops it.
    private var minutes: Int? = 60
    private var rows: [String: KeelOptionRow] = [:]
    private let endsNote = Keel.label("", size: 12, color: Keel.dim)
    private let agreement = NSTextField(wrappingLabelWithString: "")
    private let summary = Keel.label("", size: 12, color: Keel.dim)
    private let lend = KeelButton("Lend", kind: .coral, target: nil, action: nil)
    private var inner: CGFloat { dialog.width - 48 }

    init(dialog: AgentDialog, trust: AgentTrust, live: AgentTrust.Live, profileTabs: [BrowserWindowController], preselect: [String],
         handing: BrowserWindowController?) {
        self.dialog = dialog
        self.trust = trust
        self.live = live
        self.handing = handing
        sessionID = live.session.id

        // The asked-for origins first, then the person's open sites.
        var seen = Set<String>()
        var found: [Candidate] = []
        func add(_ origin: String, title: String?) {
            let origin = Origin.normalize(origin)
            guard !origin.isEmpty, seen.insert(origin).inserted else { return }
            let lendable = !NeverLendable.contains(origin) && trust.rules.rule(for: origin) != .never
            found.append(Candidate(origin: origin, tabTitle: title, lendable: lendable))
        }
        let titled = profileTabs.compactMap { tab -> (String, String?)? in
            guard let url = tab.currentURL, url.scheme == "https" || url.scheme == "http", let origin = Origin.of(url) else { return nil }
            return (origin, tab.window?.title)
        }
        for origin in preselect { add(origin, title: titled.first { $0.0 == Origin.normalize(origin) }?.1) }
        for (origin, title) in titled.sorted(by: { $0.0 < $1.0 }) { add(origin, title: title) }
        candidates = found

        let lendable = found.filter(\.lendable).map(\.origin)
        let asked = Set(preselect.map(Origin.normalize)).intersection(lendable)
        picked = !asked.isEmpty ? asked : lendable.count == 1 ? Set(lendable) : []
    }

    private var clientName: String { live?.session.clientName ?? "The agent" }

    func start() {
        dialog.onTrustChange = { [weak self] in
            // The session ended while the person was choosing.
            guard let self else { return }
            if self.trust.live(self.sessionID) == nil { self.dialog.close() }
        }
        build()
    }

    private func build() {
        let width = inner
        var originViews: [NSView] = []
        for candidate in candidates {
            let subtitle = candidate.lendable
                ? candidate.tabTitle.map { "Open in “\($0)”" } ?? "Requested by \(clientName)"
                : "Email, banking and password managers are never lendable"
            let row = KeelOptionRow(title: candidate.origin, subtitle: subtitle, indicator: .check, accent: .lend, monoTitle: true)
            row.setTextWidth(width - 200)
            row.isOn = picked.contains(candidate.origin)
            row.isDisabled = !candidate.lendable
            if !candidate.lendable {
                let chip = KeelChip()
                chip.set("Never lendable", fill: Keel.inputBorder, color: Keel.muted, dot: nil)
                row.trailing.addArrangedSubview(chip)
                row.setAccessibilityLabel("\(candidate.origin), never lendable")
            }
            row.onToggle = { [weak self] in self?.toggle(candidate.origin) }
            rows[candidate.origin] = row
            originViews.append(row)
        }
        if candidates.isEmpty {
            originViews.append(AgentDialog.text("None of your tabs is on a site you could lend. Open the site in a tab first, signed in, then lend it.",
                                                width: width, size: 12, color: Keel.dim))
        }
        let list: NSView
        if originViews.count > 5 {
            // Many open sites: the list scrolls, the dialog stays on screen.
            let stack = NSStackView(views: originViews)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            for view in originViews { view.widthAnchor.constraint(equalToConstant: width - 12).isActive = true }
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            stack.translatesAutoresizingMaskIntoConstraints = false
            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack)
            scroll.documentView = document
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                scroll.heightAnchor.constraint(equalToConstant: 5 * 64),
            ])
            list = scroll
        } else {
            let stack = NSStackView(views: originViews)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            for view in originViews { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
            list = stack
        }

        let duration = KeelSegmented(["15 min", "1 h", "Until I stop"], selected: 1, label: "Duration")
        duration.onChange = { [weak self] index in
            self?.minutes = [15, 60, nil][index]
            self?.sync()
        }

        agreement.preferredMaxLayoutWidth = width - 28
        let agreementBox = KeelPanel(fill: Keel.coralChip, border: Keel.hex(0x6B2F1B), radius: 9)
        AgentDialog.embed(agreement, in: agreementBox, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        let cancel = KeelButton("Cancel", kind: .neutral, target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        cancel.onPress = { [weak self] in self?.dialog.close() }
        lend.keyEquivalent = "\r"
        lend.onPress = { [weak self] in self?.commit() }
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [summary, cancel, lend])
        footer.spacing = 8

        let body = AgentDialog.column([
            AgentDialog.heading("Lend your signed-in sessions",
                                "\(clientName) asked to work inside accounts you are already signed in to. Choose which sites it may use.", width: width),
            AgentDialog.section("Origins", [list], width: width),
            AgentDialog.section("Duration", [duration, endsNote], width: width),
            agreementBox,
            footer,
        ], width: dialog.width)
        sync()
        dialog.show(body)
    }

    private func toggle(_ origin: String) {
        if picked.contains(origin) { picked.remove(origin) } else { picked.insert(origin) }
        sync()
    }

    /// The origins picked, in the order they are listed.
    private var chosen: [String] { candidates.map(\.origin).filter { picked.contains($0) } }

    private var durationText: String { minutes.map { $0 < 60 ? "\($0) min" : "\($0 / 60) h" } ?? "until you stop" }

    private func sync() {
        for (origin, row) in rows { row.isOn = picked.contains(origin) }
        let chosen = self.chosen

        if let minutes {
            endsNote.stringValue = "Ends at \(Keel.clock(Date().addingTimeInterval(Double(minutes) * 60))). You can end it sooner from the banner at any time."
        } else {
            endsNote.stringValue = "Lasts until you end it from the banner, or the session reaches its own time limit."
        }

        let body: [NSAttributedString.Key: Any] = [.font: Keel.font(13), .foregroundColor: Keel.hex(0xE8C4B6)]
        let text = NSMutableAttributedString(string: "What you are agreeing to\n", attributes: [
            .font: Keel.font(13, .bold), .foregroundColor: Keel.coralText,
        ])
        let period = minutes.map { $0 < 60 ? "For \($0) minutes" : $0 == 60 ? "For 1 hour" : "For \($0 / 60) hours" } ?? "Until you stop it"
        text.append(NSAttributedString(string: "\(period), \(clientName) can act ", attributes: body))
        text.append(NSAttributedString(string: "as you", attributes: [.font: Keel.font(13, .bold), .foregroundColor: Keel.hex(0xE8C4B6)]))
        text.append(NSAttributedString(string: " on ", attributes: body))
        let sites = chosen.isEmpty ? "the sites you pick" : chosen.joined(separator: ", ")
        text.append(NSAttributedString(string: sites, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Keel.hex(0xE8C4B6),
        ]))
        text.append(NSAttributedString(string: ": read what your account shows there and make changes. Purchases, deletions and anything that sends data still need your approval each time. Every action is logged. It cannot see other sites, saved passwords or cards.",
                                       attributes: body))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        agreement.attributedStringValue = text
        agreement.setAccessibilityLabel(text.string)

        let hint = live.flatMap { live in trust.clients.first { $0.id == live.session.clientID } }?.tokenHint
        var parts = ["\(chosen.count) origin\(chosen.count == 1 ? "" : "s")", minutes == nil ? "until stopped" : durationText]
        if let hint { parts.append("token \(ClientRegistry.tokenPrefix)…\(hint)") }
        summary.stringValue = parts.joined(separator: " · ")

        let title = chosen.count == 1 ? "Lend \(chosen[0])" : chosen.isEmpty ? "Lend" : "Lend \(chosen.count) origins"
        lend.title = title
        lend.attributedTitle = NSAttributedString(string: title, attributes: [.font: Keel.font(13, .semibold), .foregroundColor: Keel.hex(0x2A0F05)])
        lend.invalidateIntrinsicContentSize()
        lend.isEnabled = !chosen.isEmpty
        lend.alphaValue = chosen.isEmpty ? 0.45 : 1
        dialog.refit()
    }

    private func commit() {
        guard let live, trust.live(sessionID) != nil else { dialog.close(); return }
        let chosen = self.chosen
        guard !chosen.isEmpty else { NSSound.beep(); return }
        trust.lend(live, origins: chosen, minutes: minutes)
        if let handing, let url = handing.currentURL, let origin = Origin.of(url), live.session.mode.origins.contains(origin) {
            live.adopt(handing)
            handing.syncAgentChrome()
        }
        dialog.close()
    }
}
