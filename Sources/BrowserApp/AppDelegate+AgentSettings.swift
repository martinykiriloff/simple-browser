import AppKit

extension AppDelegate {
    /// Agent → Agents & Permissions…: Settings, on the Agents pane.
    @objc func showAgentSettings(_ sender: Any?) { settingsWindow.show(.agents, sender: sender) }
}
