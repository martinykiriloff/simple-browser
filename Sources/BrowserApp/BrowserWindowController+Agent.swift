import AppKit
import AgentKit

/// What agent activity puts over a tab's page. Owned by the tab.
@MainActor
final class AgentChromeViews {
    /// 3 pt amber along the top of a page an agent drives.
    var edge: NSView?
    var banner: NSView?
    var bannerKind = ""
    var bannerLabel: NSTextField?
    var approvals: [UUID: NSView] = [:]
    var handoff: NSView?
    var injection: NSView?
    var handoffDone: ((String) -> Void)?
    var waitingTimer: Timer?
    /// The chips in the toolbar: identity and "N waiting".
    let identityChip = KeelChip()
    let waitingChip = KeelChip()
    lazy var toolbarStack: NSStackView = {
        let stack = NSStackView(views: [identityChip, waitingChip])
        stack.spacing = 8
        return stack
    }()
    var observer: NSObjectProtocol?
}

extension NSToolbarItem.Identifier {
    static let agentStatus = NSToolbarItem.Identifier("agentStatus")
}

extension BrowserWindowController {

    private var trust: AgentTrust? { agentTrust?() }
    private var live: AgentTrust.Live? { trust?.live(for: self) }

    /// The toolbar item carrying the identity and waiting chips.
    func makeAgentStatusItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .agentStatus)
        item.view = agentChrome.toolbarStack
        item.label = "Agents"
        item.visibilityPriority = .high
        agentChrome.identityChip.onClick = { [weak self] in self?.showAgentSessionMenu() }
        agentChrome.waitingChip.onClick = { [weak self] in self?.revealWaitingApproval() }
        if agentChrome.observer == nil {
            agentChrome.observer = NotificationCenter.default.addObserver(forName: .agentTrustDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncAgentChrome() }
            }
        }
        syncAgentChrome()
        return item
    }

    // MARK: - Chrome

    /// Brings the amber edge, the chips, the tab's marker and the banners in
    /// line with the session that owns this tab (or none).
    func syncAgentChrome() {
        guard window != nil else { return }
        let live = self.live
        let session = live?.session

        // Identity chip: only on windows an agent owns.
        let identity = agentChrome.identityChip
        if let session {
            switch session.mode {
            case .sandbox:
                identity.set("Sandbox · ephemeral", fill: Keel.greenChip, color: Keel.greenText, dot: nil)
            case .borrowed(let origins, let expires):
                let left = expires.map { " · \(Self.minutesLeft(until: $0)) min" } ?? ""
                identity.set("Borrowed · \(origins.first ?? "")\(origins.count > 1 ? " +\(origins.count - 1)" : "")\(left)",
                             fill: Keel.coralChip, color: Keel.coralText, dot: Keel.coral)
            }
            identity.isHidden = false
            identity.toolTip = "Agent session \(session.id) · \(session.clientName). Click for the session menu."
        } else {
            identity.isHidden = true
        }

        // Waiting chip: on every window, so a request is never out of sight.
        let waiting = trust?.approvals.count ?? 0
        agentChrome.waitingChip.set("\(waiting) waiting", fill: Keel.amberChip, color: Keel.amber, dot: Keel.amber)
        agentChrome.waitingChip.isHidden = waiting == 0
        agentChrome.waitingChip.toolTip = "An agent is waiting for your OK. Click to see it."

        // The amber edge on the page.
        let running = session.map { $0.state != .stopped } ?? false
        if running, agentChrome.edge == nil {
            let edge = NSView()
            edge.wantsLayer = true
            edge.layer?.backgroundColor = Keel.amber.cgColor
            edge.translatesAutoresizingMaskIntoConstraints = false
            edge.setAccessibilityElement(false)
            pageContainer.addSubview(edge, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                edge.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                edge.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                edge.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                edge.heightAnchor.constraint(equalToConstant: 3),
            ])
            agentChrome.edge = edge
        } else if !running, let edge = agentChrome.edge {
            edge.removeFromSuperview()
            agentChrome.edge = nil
        }
        agentChrome.edge?.layer?.backgroundColor = (session?.state == .paused ? Keel.idle : Keel.amber).cgColor

        // The tab in the strip: an amber marker with the client's name.
        if let session, running {
            let marker = KeelChip()
            marker.set(session.clientName, fill: Keel.amberChip, color: Keel.amber, dot: Keel.amber)
            marker.setAccessibilityLabel("Driven by \(session.clientName)")
            window?.tab.accessoryView = marker
            window?.tab.toolTip = "\(session.clientName) · agent session \(session.id)"
        } else if window?.tab.accessoryView is KeelChip {
            window?.tab.accessoryView = nil
            syncTabAccessoryAfterAgent()
        }

        // Banners: borrowed, paused.
        if let session, case .borrowed(let origins, let expires) = session.mode, running {
            let left = expires.map { " · \(Self.minutesLeft(until: $0)) min left" } ?? ""
            showAgentBanner(kind: "borrowed",
                            text: "\(session.clientName) is using your signed-in session on \(origins.joined(separator: ", "))\(left)",
                            fill: Keel.coralChip, color: Keel.coralText, button: "End now") { [weak self] in
                guard let self, let live = self.live else { return }
                self.trust?.endBorrowing(live)
            }
        } else if let session, session.state == .paused {
            showAgentBanner(kind: "paused", text: "\(session.clientName) is paused. Nothing runs until you resume it.",
                            fill: Keel.raised, color: Keel.text, button: "Resume") { [weak self] in
                guard let self, let live = self.live else { return }
                self.trust?.resume(live)
            }
        } else if agentChrome.bannerKind == "borrowed" || agentChrome.bannerKind == "paused" {
            hideAgentBanner()
        }
    }

    private func syncTabAccessoryAfterAgent() {
        // The strip's own marker (pin, group, sound) comes back.
        tabAccessoryKey = ""
        syncTabAccessory()
    }

    static func minutesLeft(until date: Date) -> Int { max(0, Int(ceil(date.timeIntervalSinceNow / 60))) }

    // MARK: - Banners

    func showAgentBanner(kind: String, text: String, fill: NSColor, color: NSColor, button: String?, action: (() -> Void)?) {
        if agentChrome.bannerKind == kind, let label = agentChrome.bannerLabel {
            label.stringValue = text
            return
        }
        hideAgentBanner()
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = fill.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.appearance = NSAppearance(named: .darkAqua)
        let label = Keel.label(text, size: 13, weight: .medium, color: color)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let button {
            let control = KeelButton(button, kind: kind == "borrowed" ? .coral : .neutral, target: nil, action: nil)
            control.onPress = action
            stack.addView(NSView(), in: .trailing)
            stack.addArrangedSubview(control)
        }
        bar.addSubview(stack)
        pageContainer.addSubview(bar, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            bar.topAnchor.constraint(equalTo: pageContainer.topAnchor, constant: 3),
            bar.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.group)
        bar.setAccessibilityLabel(text)
        agentChrome.banner = bar
        agentChrome.bannerKind = kind
        agentChrome.bannerLabel = label
    }

    func hideAgentBanner() {
        agentChrome.banner?.removeFromSuperview()
        agentChrome.banner = nil
        agentChrome.bannerKind = ""
        agentChrome.bannerLabel = nil
    }

    // MARK: - Handing over (AR-7)

    func showAgentHandoff(message: String, client: String, done: @escaping (String) -> Void) {
        agentChrome.handoffDone = done
        showAgentBanner(kind: "handoff", text: "\(client) handed this tab to you: \(message)",
                        fill: Keel.amberChip, color: Keel.amberSoft, button: "Done — hand back") { [weak self] in
            self?.agentChrome.handoffDone?("done")
        }
    }

    func hideAgentHandoff() {
        agentChrome.handoffDone = nil
        if agentChrome.bannerKind == "handoff" { hideAgentBanner() }
        syncAgentChrome()
    }

    // MARK: - Untrusted content (G2-07)

    /// A page tried to instruct the agent: the person sees what and where.
    func showAgentInjectionNotice(_ finding: InjectionScanner.Finding, client: String) {
        agentChrome.injection?.removeFromSuperview()
        let card = KeelPanel(fill: Keel.raised, border: Keel.menuBorder, radius: 12)
        let mark = Keel.label("!", size: 13, weight: .bold, color: Keel.dangerText)
        let title = Keel.label("Instruction in page content flagged", size: 14, weight: .semibold)
        let body = Keel.label("While reading this page, \(client) found text addressed to AI agents (“\(finding.phrase)”). Text on a web page is never treated as an instruction: actions on this page now ask you first.",
                              size: 12, color: Keel.muted, wraps: true)
        let excerpt = Keel.monoLabel("“\(finding.excerpt.prefix(160))”", color: Keel.dim)
        excerpt.lineBreakMode = .byTruncatingTail
        let dismiss = KeelButton("Keep ignoring", kind: .neutral, target: nil, action: nil)
        dismiss.onPress = { [weak self] in self?.agentChrome.injection?.removeFromSuperview(); self?.agentChrome.injection = nil }
        let header = NSStackView(views: [mark, title])
        header.spacing = 8
        let stack = NSStackView(views: [header, body, excerpt, dismiss])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        pageContainer.addSubview(card, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 348), excerpt.widthAnchor.constraint(equalToConstant: 348),
            card.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor, constant: 20),
            card.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor, constant: -20),
        ])
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Instruction in page content flagged")
        agentChrome.injection = card
    }

    // MARK: - Approval card (G2-05)

    func presentAgentApproval(_ pending: AgentTrust.PendingApproval, trust: AgentTrust) {
        if let window, let group = window.tabGroup, group.selectedWindow !== window { group.selectedWindow = window }
        window?.orderFront(nil)
        let card = AgentApprovalCard(pending: pending, page: currentURL, title: window?.title ?? "") { [weak trust, weak pending] decision in
            guard let trust, let pending else { return }
            trust.resolve(pending, decision)
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(card, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            card.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: pageContainer.topAnchor, constant: 56),
            card.widthAnchor.constraint(equalToConstant: 420),
            card.bottomAnchor.constraint(lessThanOrEqualTo: pageContainer.bottomAnchor, constant: -20),
        ])
        agentChrome.approvals[pending.id] = card
        window?.makeFirstResponder(card.defaultButton)
        syncAgentChrome()
    }

    func dismissAgentApproval(_ pending: AgentTrust.PendingApproval) {
        agentChrome.approvals.removeValue(forKey: pending.id)?.removeFromSuperview()
        syncAgentChrome()
    }

    private func revealWaitingApproval() {
        guard let first = trust?.approvals.first, let tab = first.tab, let window = tab.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Session menu (G2-03)

    func showAgentSessionMenu() {
        guard let trust, let live else { return }
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        let heading = NSMenuItem(title: "Session identity for agents", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let sandbox = AgentMenuItem(title: "Sandbox · ephemeral", subtitle: "Empty profile, destroyed when the agent stops") { [weak trust, weak live] in
            guard let trust, let live else { return }
            trust.endBorrowing(live)
        }
        sandbox.state = live.session.mode.kind == .sandbox ? NSControl.StateValue.on : .off
        menu.addItem(sandbox)
        let borrowed = AgentMenuItem(title: "Borrowed · choose origins…", subtitle: "Lend selected signed-in sites for a limited time") {
            NSApp.sendAction(#selector(AppDelegate.lendOriginsToAgent(_:)), to: nil, from: nil)
        }
        borrowed.state = live.session.mode.kind == .borrowed ? NSControl.StateValue.on : .off
        menu.addItem(borrowed)
        menu.addItem(.separator())
        menu.addItem(AgentMenuItem(title: live.session.state == .paused ? "Resume \(live.session.clientName)" : "Pause \(live.session.clientName)") { [weak trust, weak live] in
            guard let trust, let live else { return }
            if live.session.state == .paused { trust.resume(live) } else { trust.pause(live) }
        })
        let log = NSMenuItem(title: "Agent Activity Log", action: #selector(AppDelegate.showAgentActivityLog(_:)), keyEquivalent: "")
        menu.addItem(log)
        menu.addItem(withTitle: "Pause All Agents", action: #selector(AppDelegate.pauseAllAgents(_:)), keyEquivalent: "")
        let stop = NSMenuItem(title: "Stop & Revoke All", action: #selector(AppDelegate.stopAndRevokeAllAgents(_:)), keyEquivalent: "")
        stop.attributedTitle = NSAttributedString(string: "Stop & Revoke All", attributes: [.foregroundColor: Keel.dangerText])
        menu.addItem(stop)
        let chip = agentChrome.identityChip
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: chip.bounds.height + 4), in: chip)
    }
}

/// A menu item with a second line, and a closure.
@MainActor
final class AgentMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }

    init(title: String, subtitle: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
        let text = NSMutableAttributedString(string: title + "\n", attributes: [.font: Keel.font(13, .medium)])
        text.append(NSAttributedString(string: subtitle, attributes: [.font: Keel.font(11), .foregroundColor: NSColor.secondaryLabelColor]))
        attributedTitle = text
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire(_ sender: Any?) { handler?() }
}

extension KeelButton {
    private static var handlers: [ObjectIdentifier: () -> Void] = [:]

    /// A closure instead of target/action.
    var onPress: (() -> Void)? {
        get { Self.handlers[ObjectIdentifier(self)] }
        set {
            Self.handlers[ObjectIdentifier(self)] = newValue
            target = self
            action = #selector(pressed(_:))
        }
    }

    @objc private func pressed(_ sender: Any?) { Self.handlers[ObjectIdentifier(self)]?() }
}

/// The card that asks the person before a consequential action.
final class AgentApprovalCard: KeelPanel {
    private let pending: AgentTrust.PendingApproval
    private let answer: (AgentSession.Decision) -> Void
    private let timerLabel = Keel.monoLabel("waiting 00:00", color: Keel.dim)
    private var timer: Timer?
    private(set) var defaultButton: NSButton?

    init(pending: AgentTrust.PendingApproval, page: URL?, title: String, answer: @escaping (AgentSession.Decision) -> Void) {
        self.pending = pending
        self.answer = answer
        super.init(fill: Keel.approvalBackground, border: Keel.approvalBorder, radius: 14)
        layer?.shadowOpacity = 0
        build(page: page, title: title)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(pending.clientName) needs your OK")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func removeFromSuperview() {
        timer?.invalidate()
        super.removeFromSuperview()
    }

    private func tick() {
        let seconds = Int(Date().timeIntervalSince(pending.created))
        timerLabel.stringValue = String(format: "waiting %02d:%02d", seconds / 60, seconds % 60)
    }

    private func build(page: URL?, title: String) {
        let header = NSStackView(views: [Keel.sectionLabel("Needs your OK", color: Keel.amber), NSView(), timerLabel])
        header.distribution = .fill

        let verb: String
        switch pending.tool {
        case "click": verb = "click"
        case "fill", "fill_form", "type_text": verb = "type into"
        case "press_key": verb = "press a key in"
        case "upload_files": verb = "upload files to"
        case "evaluate": verb = "run JavaScript on"
        case "storage": verb = "change storage on"
        default: verb = pending.tool.replacingOccurrences(of: "_", with: " ")
        }
        let headline = Keel.label("\(pending.clientName) wants to \(verb) \(pending.target)", size: 15, weight: .semibold, wraps: true)

        func row(_ name: String, _ value: String, color: NSColor = Keel.approvalBody) -> NSView {
            let key = Keel.label(name, size: 12, weight: .semibold, color: Keel.dim)
            key.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let text = Keel.label(value, size: 13, color: color, wraps: true)
            let stack = NSStackView(views: [key, text])
            stack.alignment = .firstBaseline
            stack.spacing = 10
            return stack
        }

        let origin = pending.origin ?? page.flatMap(Origin.of) ?? "this page"
        let what = row("What", pending.risk.reason ?? "A consequential action.")
        let where_ = row("Where", "\(origin)\(page.map { $0.path.isEmpty ? "" : " " + $0.path } ?? "") · tab “\(title)”")
        let why: NSView
        if let instruction = pending.pageInstruction {
            why = row("Why", "Instruction found in page content: “\(instruction)”. The request may not have come from you.", color: Keel.amberSoft)
        } else {
            why = row("Why", "\(pending.clientName) chose this step for your task. Actions like this always ask.")
        }

        let details = NSStackView(views: [
            Keel.monoLabel("tool \(pending.tool)\(pending.ref.map { " · ref \($0)" } ?? "")"),
            Keel.monoLabel("kind \(pending.risk.kind?.rawValue ?? "action")"),
            Keel.monoLabel("budget \(pending.actionsUsed) / \(pending.actionsBudget) actions · session \(pending.sessionID)"),
        ])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 3
        let detailBox = KeelPanel(fill: Keel.hex(0x14110B), border: Keel.hex(0x3A2C12), radius: 9)
        details.translatesAutoresizingMaskIntoConstraints = false
        detailBox.addSubview(details)
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 12),
            details.trailingAnchor.constraint(lessThanOrEqualTo: detailBox.trailingAnchor, constant: -12),
            details.topAnchor.constraint(equalTo: detailBox.topAnchor, constant: 10),
            details.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor, constant: -10),
        ])

        let allow = KeelButton("Allow once", kind: .allow, target: nil, action: nil)
        allow.onPress = { [weak self] in self?.answer(.allowOnce) }
        allow.keyEquivalent = "\r"
        defaultButton = allow
        let deny = KeelButton("Deny", kind: .neutral, target: nil, action: nil)
        deny.onPress = { [weak self] in self?.answer(.deny) }
        deny.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [allow, deny])
        buttons.spacing = 8

        let always = NSButton(title: "Always allow on this origin for 1 h", target: nil, action: nil)
        always.isBordered = false
        always.attributedTitle = NSAttributedString(string: "Always allow on this origin for 1 h",
                                                    attributes: [.font: Keel.font(12, .medium), .foregroundColor: Keel.amberSoft,
                                                                 .underlineStyle: NSUnderlineStyle.single.rawValue])
        always.isHidden = pending.risk.kind == .payment || pending.risk.kind == .credential || pending.origin == nil
        KeelButtonActions.attach(always) { [weak self] in self?.answer(.allowOnOrigin(until: Date().addingTimeInterval(3600))) }

        let footnote = Keel.label("Denying tells \(pending.clientName) the action was refused.", size: 12, color: Keel.dim, wraps: true)
        let stop = KeelButton("Stop & revoke", kind: .danger, target: nil, action: nil)
        stop.onPress = { [weak self] in self?.answer(.stop) }
        let bottom = NSStackView(views: [footnote, NSView(), stop])

        let stack = NSStackView(views: [header, headline, what, where_, why, detailBox, buttons, always, separator(), bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(6, after: header)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in [header, headline, what, where_, why, detailBox, bottom] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Keel.approvalBorder.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: 384).isActive = true
        return line
    }
}

/// Closures for plain NSButtons.
@MainActor
enum KeelButtonActions {
    private final class Target: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run(_ sender: Any?) { handler() }
    }
    private static var targets: [ObjectIdentifier: Target] = [:]

    static func attach(_ button: NSButton, _ handler: @escaping () -> Void) {
        let target = Target(handler)
        targets[ObjectIdentifier(button)] = target
        button.target = target
        button.action = #selector(Target.run(_:))
    }
}
