import AppKit
import AgentKit

/// What Stop & revoke did (G2-06): tokens, sessions, the log. Not modal:
/// the person may go on browsing with it open.
@MainActor
enum AgentStopSummaryController {
    private static var dialogs: [AgentDialog] = []

    static func show(_ summary: AgentTrust.StopSummary, trust: AgentTrust) {
        let width: CGFloat = 480
        let inner = width - 48
        let dialog = AgentDialog(title: "Agent Stopped", width: width)
        dialogs.append(dialog)
        dialog.onClose = { [weak dialog] in dialogs.removeAll { $0 === dialog } }

        let who = summary.clients.isEmpty ? "the agent" : summary.clients.joined(separator: ", ")
        let how = summary.viaShortcut ? " with ⇧⌘." : ""
        let dot = Keel.mark(Keel.idle, size: 10)
        let title = NSStackView(views: [dot, Keel.label("Agent stopped", size: 17, weight: .semibold)])
        title.spacing = 10
        let intro = AgentDialog.text("You stopped \(who) at \(Keel.clock(summary.time, seconds: true))\(how). Nothing more will run, and it cannot reconnect without pairing again.",
                                     width: inner)

        // Tokens.
        let tokens: String
        if summary.tokens.isEmpty {
            tokens = "No token was active."
        } else {
            let list = summary.tokens.count == 1 ? "Token \(summary.tokens[0])" : "Tokens \(summary.tokens.joined(separator: ", "))"
            let names = summary.clients.map { "“\($0) · on this Mac”" }.joined(separator: ", ")
            tokens = "\(list) deleted from Keychain. Pairing for \(names) removed."
        }

        // Sessions.
        let sessionTitle: String
        let sessionText: String
        if summary.sessions.isEmpty {
            sessionTitle = "No session was running"
            sessionText = "There was nothing to close. Your own profile was never touched."
        } else {
            let sandboxed = summary.sessions.allSatisfy(\.sandbox)
            sessionTitle = sandboxed ? "Sandbox session\(summary.sessions.count == 1 ? "" : "s") destroyed" : "Session\(summary.sessions.count == 1 ? "" : "s") ended"
            sessionText = summary.sessions.map { session in
                let tabs = "\(session.tabs) tab\(session.tabs == 1 ? "" : "s")"
                return session.sandbox
                    ? "Session \(session.id) closed: \(tabs), cookies and storage wiped."
                    : "Session \(session.id) closed: \(tabs); lent origins taken back."
            }.joined(separator: " ") + (sandboxed ? " Your own profile was never touched." : "")
        }

        // Actions.
        let cancelled = summary.cancelledApprovals
        let actionsText = "\(summary.completed) completed, \(summary.denied) denied, \(cancelled) approval request\(cancelled == 1 ? "" : "s") cancelled. "
            + "Audit log kept for \(trust.settings.logRetentionDays) days."

        let steps = NSStackView(views: [
            step("Tokens revoked", tokens, width: inner),
            step(sessionTitle, sessionText, width: inner),
            step("\(summary.actions) action\(summary.actions == 1 ? "" : "s") logged", actionsText, width: inner),
        ])
        steps.orientation = .vertical
        steps.spacing = 0
        for view in steps.arrangedSubviews { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }

        let ids = summary.sessions.map(\.id)
        let viewLog = KeelButton("View log", kind: .neutral, target: nil, action: nil)
        viewLog.onPress = { AgentActivityLogController.shared.show(trust: trust, sessionID: ids.first) }
        let replay = KeelButton("Export replay", kind: .neutral, target: nil, action: nil)
        replay.isEnabled = !ids.isEmpty
        replay.alphaValue = ids.isEmpty ? 0.45 : 1
        replay.onPress = { [weak dialog] in exportReplay(ids, trust: trust, from: dialog?.window) }
        let repair = KeelButton("Re-pair", kind: .primary, target: nil, action: nil)
        repair.keyEquivalent = "\r"
        repair.setAccessibilityLabel("Pair an agent again")
        repair.onPress = { [weak dialog] in
            dialog?.close()
            NSApp.sendAction(#selector(AppDelegate.pairNewAgent(_:)), to: nil, from: nil)
        }

        let body = AgentDialog.column([
            title,
            intro,
            steps,
            AgentDialog.footer(leading: [viewLog, replay], trailing: [repair], width: inner),
        ], width: width, spacing: 8)
        body.setCustomSpacing(16, after: steps)
        dialog.show(body)
        if !QuietMode.isOn { dialog.window.orderFrontRegardless() }
    }

    private static func step(_ title: String, _ text: String, width: CGFloat) -> NSView {
        let words = NSStackView(views: [Keel.label(title, size: 13, weight: .semibold), AgentDialog.text(text, width: width - 30, size: 12)])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        let row = NSStackView(views: [Keel.checkBadge(), words])
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        let box = NSStackView(views: [Keel.separator(), row])
        box.orientation = .vertical
        box.spacing = 0
        for view in box.arrangedSubviews { view.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel("Done: \(title). \(text)")
        return box
    }

    /// The stopped sessions' replay: one session as itself, several as a list.
    private static func exportReplay(_ ids: [String], trust: AgentTrust, from window: NSWindow?) {
        let replays = ids.compactMap { id -> JSONValue? in
            let entries = AgentLogs.entries(sessionID: id, trust: trust)
            return entries.isEmpty ? nil : AgentLogs.replay(entries)
        }
        guard !replays.isEmpty else { NSSound.beep(); return }
        let value: JSONValue = replays.count == 1 ? replays[0] : .array(replays)
        AgentLogs.save(value.encoded(pretty: true), name: "keel-replay-\(ids.count == 1 ? ids[0] : "stopped").json", from: window)
    }
}
