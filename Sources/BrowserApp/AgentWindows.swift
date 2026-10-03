import AppKit
import AgentKit

// Stubs: the windows the trust layer shows. Each is replaced by its full
// design (G2-01, G2-02, G2-04, G2-06, the activity log).

/// Pairing (G2-01) and the client's grants (G2-02).
@MainActor
final class AgentPairingController {
    static let shared = AgentPairingController()

    /// Agent → Pair a New Agent…: the person sets up a client by hand.
    func showManualPairing(trust: AgentTrust, server: AgentServer) {
        let alert = NSAlert()
        alert.messageText = "Pair an agent"
        alert.informativeText = "A token of its own for one MCP client."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let paired = trust.pair(name: "Claude Code")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.claudeCodeCommand(token: paired.token), forType: .string)
    }

    /// A client asked to pair over `/pair`.
    func showRequest(_ pending: AgentTrust.PendingPairing, trust: AgentTrust, server: AgentServer) {
        let alert = NSAlert()
        alert.messageText = "\(pending.request.clientName) wants to pair"
        alert.informativeText = "Code \(pending.request.displayCode)"
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        trust.answer(pending, approve: alert.runModal() == .alertFirstButtonReturn)
    }
}

/// Lending signed-in origins (G2-04).
@MainActor
final class AgentBorrowController {
    static let shared = AgentBorrowController()

    func show(trust: AgentTrust, live: AgentTrust.Live, profileTabs: [BrowserWindowController], preselect: [String] = [],
              handing: BrowserWindowController? = nil) {
        let origins = preselect.isEmpty ? Array(Set(profileTabs.compactMap { $0.currentURL.flatMap(Origin.of) })).sorted() : preselect
        guard let first = origins.first else { return }
        trust.lend(live, origins: [first], minutes: 60)
        if let handing { live.adopt(handing); handing.syncAgentChrome() }
    }
}

/// What Stop & revoke did (G2-06).
@MainActor
enum AgentStopSummaryController {
    static func show(_ summary: AgentTrust.StopSummary, trust: AgentTrust) {
        let alert = NSAlert()
        alert.messageText = "Agent stopped"
        alert.informativeText = "\(summary.clients.joined(separator: ", ")) · \(summary.actions) actions logged"
        alert.runModal()
    }
}

/// Agent → Agent Activity Log.
@MainActor
final class AgentActivityLogController {
    static let shared = AgentActivityLogController()
    func show(trust: AgentTrust) {
        NSWorkspace.shared.open(trust.logsDirectory)
    }
}
