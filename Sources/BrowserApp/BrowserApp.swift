import AppKit

@main
struct BrowserApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // `NSApplication.delegate` is weak; keep ours alive for the run loop's lifetime.
        withExtendedLifetime(delegate) { app.run() }
    }
}
