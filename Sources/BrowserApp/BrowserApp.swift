import AppKit

@main
struct BrowserApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // A packaged .app gets its Dock icon from AppIcon.icns. Run from the
        // build folder there is no bundle to carry one, and the Dock would
        // show a generic executable, so the same artwork is set here.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
           let url = AppResources.bundle.url(forResource: "AppIcon", withExtension: "png", subdirectory: "AppIcon"),
           let icon = NSImage(contentsOf: url) {
            app.applicationIconImage = icon
        }
        // `NSApplication.delegate` is weak; keep ours alive for the run loop's lifetime.
        withExtendedLifetime(delegate) { app.run() }
    }
}
