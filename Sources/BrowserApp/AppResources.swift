import Foundation

/// The app target's resource bundle.
enum AppResources {
    /// SwiftPM's `Bundle.module` only looks beside the executable, which is
    /// wrong inside an `.app`, where the packaging script puts resource
    /// bundles in `Contents/Resources`. Check there first.
    static let bundle: Bundle = {
        let name = "SimpleBrowser_BrowserApp.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }()
}
