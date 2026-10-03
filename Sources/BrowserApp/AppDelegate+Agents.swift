import AppKit
import WebKit
import AgentKit
import BrowserKit

/// The trust layer's place in the app: agent windows, the Agent menu, and
/// the kill switch.
extension AppDelegate {

    func configureAgentTrust() {
        let trust = agentTrust
        trust.openTab = { [weak self] live, url, inFront in
            self?.openAgentTab(live, url: url, inFront: inFront)
        }
        trust.closeTabs = { tabs in
            for tab in tabs { tab.window?.close() }
        }
        trust.presentPairing = { [weak self] pending in
            self?.presentAgentPairing(pending)
        }
        trust.presentStopSummary = { [weak self] summary in
            self?.presentAgentStopSummary(summary)
        }
    }

    /// A tab for an agent session: beside its other tabs, else in a window of
    /// its own. A sandbox gets a fresh in-memory data store; a borrowed
    /// session uses the person's current profile.
    func openAgentTab(_ live: AgentTrust.Live, url: URL?, inFront: Bool) -> BrowserWindowController? {
        let existing = live.openTabs.last
        let tab: BrowserWindowController
        switch live.session.mode {
        case .sandbox:
            let store = live.sandbox ?? {
                let made = PrivateSession()
                made.agentSessionID = live.session.id
                live.sandbox = made
                return made
            }()
            tab = makeWindow(profile: currentProfile, sandbox: store)
        case .borrowed:
            tab = makeWindow(profile: currentProfile)
        }
        tab.agentSessionID = live.session.id
        if let window = existing?.window, let tabWindow = tab.window {
            tabWindow.tabbingMode = .automatic
            window.addTabbedWindow(tabWindow, ordered: .above)
            tab.acceptTabs()
            if inFront { tabWindow.orderFront(nil) }
        } else if let tabWindow = tab.window {
            // Its own window, beside the person's rather than over their work.
            tab.showWindow(nil)
            if let front = frontmostBrowser?.window, front !== tabWindow {
                var frame = front.frame.offsetBy(dx: 36, dy: -36)
                frame.size = NSSize(width: max(960, frame.width - 72), height: max(640, frame.height - 72))
                tabWindow.setFrame(frame, display: false)
                if !inFront { front.orderFront(nil) }
            }
        }
        // One group per session, named after it, so its tabs read as the agent's and close in one action.
        if let group = live.groupID, tabOrganizer.group(group) != nil {
            tabOrganizer.add([tab], to: group)
        } else if let group = tabOrganizer.newGroup(with: [tab], name: "\(live.session.clientName) · \(live.session.id)") {
            tabOrganizer.setColor(group, .orange)
            live.groupID = group
        }
        tabOrganizer.changed()
        tab.load(url ?? URL(string: "about:blank")!)
        tab.syncAgentChrome()
        return tab
    }

    // MARK: - Menu actions

    /// Agent → Pair a New Agent… (⌥⌘P).
    @objc func pairNewAgent(_ sender: Any?) {
        AgentPairingController.shared.showManualPairing(trust: agentTrust, server: agentServer)
    }

    /// Agent → Agent Activity Log (⌥⌘A).
    @objc func showAgentActivityLog(_ sender: Any?) {
        AgentActivityLogController.shared.show(trust: agentTrust)
    }

    /// Agent → Pause All Agents (⇧⌘.): pauses every session, or resumes all.
    @objc func pauseAllAgents(_ sender: Any?) {
        agentTrust.togglePauseAll()
    }

    /// Agent → Stop & Revoke All: tokens deleted, sessions ended, sandboxes wiped.
    @objc func stopAndRevokeAllAgents(_ sender: Any?) {
        agentTrust.stopAndRevoke(viaShortcut: (sender as? NSMenuItem)?.keyEquivalent.isEmpty == false)
    }

    /// Session → Borrowed…: lend signed-in origins to the agent session of
    /// the front window (G2-04).
    @objc func lendOriginsToAgent(_ sender: Any?) {
        let live = frontmostBrowser.flatMap { agentTrust.live(for: $0) } ?? agentTrust.sessions.values.first
        guard let live else {
            NSSound.beep()
            return
        }
        AgentBorrowController.shared.show(trust: agentTrust, live: live, profileTabs: controllers.filter { $0.agentSessionID == nil && !$0.isPrivate })
    }

    /// Session → Sandbox: end borrowing for the front window's session.
    @objc func useAgentSandbox(_ sender: Any?) {
        guard let browser = frontmostBrowser, let live = agentTrust.live(for: browser) else { return }
        agentTrust.endBorrowing(live)
    }

    /// Hand to Agent…: gives the front tab to the running agent session,
    /// lending its origin when the session is borrowed.
    @objc func handTabToAgent(_ sender: Any?) {
        guard let browser = frontmostBrowser, browser.agentSessionID == nil, let live = agentTrust.sessions.values.first(where: { $0.session.state != .stopped }) else {
            NSSound.beep()
            return
        }
        guard let url = browser.currentURL, let origin = Origin.of(url) else { return }
        if live.session.mode.kind == .borrowed, live.session.mode.origins.contains(origin) {
            live.adopt(browser)
            browser.syncAgentChrome()
        } else {
            AgentBorrowController.shared.show(trust: agentTrust, live: live, profileTabs: [browser], preselect: [origin], handing: browser)
        }
    }

    /// Agent → Copy Snapshot for AI (⇧⌥⌘C): the exact snapshot an agent receives.
    @objc func copySnapshotForAI(_ sender: Any?) {
        guard let browser = frontmostBrowser else { return }
        Task { @MainActor in
            let result = await agentServer.toolbox.callUntrusted("snapshot", ["tabId": .string(AgentToolbox.shortID(browser))])
            let text = result.text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            browser.showNotice("Copied the snapshot an agent would get: \(TokenEstimate.format(TokenEstimate.count(text))).", seconds: 3)
        }
    }

    // MARK: - Presenting

    func presentAgentPairing(_ pending: AgentTrust.PendingPairing) {
        NSApp.activate()
        AgentPairingController.shared.showRequest(pending, trust: agentTrust, server: agentServer)
    }

    func presentAgentStopSummary(_ summary: AgentTrust.StopSummary) {
        AgentStopSummaryController.show(summary, trust: agentTrust)
    }
}

extension AppDelegate {
    /// The Agent menu's items; nil for anything else.
    func validateAgentMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(pauseAllAgents(_:)):
            item.title = agentTrust.isPausedAll ? "Resume All Agents" : "Pause All Agents"
            return !agentTrust.sessions.isEmpty
        case #selector(stopAndRevokeAllAgents(_:)):
            return !agentTrust.registry.active.isEmpty || !agentTrust.sessions.isEmpty
        case #selector(lendOriginsToAgent(_:)), #selector(useAgentSandbox(_:)):
            let live = frontmostBrowser.flatMap { agentTrust.live(for: $0) }
            if item.action == #selector(useAgentSandbox(_:)) { item.state = live?.session.mode.kind == .sandbox ? .on : .off }
            else { item.state = live?.session.mode.kind == .borrowed ? .on : .off }
            return !agentTrust.sessions.isEmpty
        case #selector(handTabToAgent(_:)):
            return !agentTrust.sessions.isEmpty && frontmostBrowser?.agentSessionID == nil
        default:
            return nil
        }
    }
}
