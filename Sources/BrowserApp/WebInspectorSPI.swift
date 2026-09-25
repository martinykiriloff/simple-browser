import WebKit

/// WebKit's own Web Inspector -- Elements, Console, Sources, Network,
/// Timelines, Storage, Layers, Audit -- driven through `_WKInspector`.
///
/// This is private API, so it is reached by selector with a runtime probe and
/// never linked against directly. The Developer ID build gets the full
/// inspector at zero cost; a build where the SPI is missing falls back to
/// "Debug in Safari" via `isInspectable`. Everything else in the dev tools
/// keeps working either way.
@MainActor
enum WebInspectorSPI {

    /// Enables the "Inspect Element" context-menu item and the `_inspector`
    /// object. Must be set on the configuration before the web view exists.
    static func enableDeveloperExtras(on configuration: WKWebViewConfiguration) {
        let preferences = configuration.preferences
        let key = "developerExtrasEnabled"
        // KVC on a private preference: harmless if the key ever disappears.
        if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            preferences.setValue(true, forKey: key)
        }
    }

    /// Keeps a page debuggable while its window is hidden.
    ///
    /// WebKit suppresses the process of a page whose window is not visible.
    /// A page paused in the debugger sits in a nested run loop, and in a
    /// suppressed process that loop stops servicing inspector messages after
    /// about three seconds: pause on a breakpoint, switch to another app, and
    /// the debugger is dead when you come back. Measured on a hidden window:
    /// 12 probes answered, then a hang at 3.3 s; with suppression off, every
    /// probe answered. The preference is only read when the page's process is
    /// set up (changing it later, turning off App Nap, and turning off window
    /// occlusion detection were all tried at runtime and did nothing), so it
    /// is set for every page. The cost is that pages in hidden windows are not
    /// napped; tab hibernation is the intended answer to background cost.
    static func keepDebuggableWhenHidden(_ configuration: WKWebViewConfiguration) {
        setPreference("pageVisibilityBasedProcessSuppressionEnabled", false, on: configuration.preferences)
    }

    /// Turns a boolean private preference on or off, if this WebKit has it.
    /// KVC finds the `_set<Key>:` setter; unknown keys are skipped, not fatal.
    @discardableResult
    static func setPreference(_ key: String, _ value: Bool, on preferences: WKPreferences) -> Bool {
        let setter = "_set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard preferences.responds(to: NSSelectorFromString(setter)) else { return false }
        preferences.setValue(value, forKey: key)
        return true
    }

    static func isAvailable(for webView: WKWebView) -> Bool {
        inspector(for: webView) != nil
    }

    /// Opens the inspector attached to the web view's window.
    @discardableResult
    static func show(_ webView: WKWebView) -> Bool {
        send("show", to: webView)
    }

    @discardableResult
    static func showConsole(_ webView: WKWebView) -> Bool {
        send("showConsole", to: webView)
    }

    @discardableResult
    static func showResources(_ webView: WKWebView) -> Bool {
        send("showResources", to: webView)
    }

    @discardableResult
    static func close(_ webView: WKWebView) -> Bool {
        send("close", to: webView)
    }

    static func isVisible(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(for: webView),
              inspector.responds(to: NSSelectorFromString("isVisible")) else { return false }
        return (inspector.value(forKey: "visible") as? Bool) ?? false
    }

    // MARK: - Plumbing

    private static func inspector(for webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector),
              let unmanaged = webView.perform(selector) else { return nil }
        return unmanaged.takeUnretainedValue() as? NSObject
    }

    private static func send(_ name: String, to webView: WKWebView) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let inspector = inspector(for: webView), inspector.responds(to: selector) else { return false }
        _ = inspector.perform(selector)
        return true
    }
}
