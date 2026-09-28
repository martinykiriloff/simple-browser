import AppKit

/// Developer aid (`--quiet`): a test run that keeps out of the way of the
/// person at the Mac. The app never makes itself active, shows no Dock
/// icon, and keeps its windows beneath everyone else's.
///
/// Without it a self-test takes the keyboard for as long as it runs, and
/// what the person types meanwhile lands in the test's windows: measured,
/// as stray letters in a field under test, and as a ⌘T and a ⌘W among the
/// menu items a test saw fire.
@MainActor
enum QuietMode {
    static let isOn = CommandLine.arguments.contains("--quiet")

    static func activate() {
        guard !isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// For every window the app makes.
    static func apply(to window: NSWindow?) {
        guard isOn, let window else { return }
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior.insert(.stationary)
    }
}
