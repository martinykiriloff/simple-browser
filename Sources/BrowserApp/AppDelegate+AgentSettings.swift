import AppKit

extension AppDelegate {
    /// Agent → Agents & Permissions…: Settings, on the Agents pane.
    @objc func showAgentSettings(_ sender: Any?) { settingsWindow.show(.agents, sender: sender) }
}

extension AppDelegate {
    /// Settings → Agents & permissions → Edit: the client's grants (G2-02).
    @objc func showAgentGrants(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String else { return }
        AgentPairingController.shared.showGrants(clientID: id, trust: agentTrust)
    }
}
