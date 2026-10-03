import AppKit

/// Developer aid (`--ui-selftest <file>`): drives the real UI wiring from
/// inside the app, for machines where macOS Accessibility is not granted and
/// nothing outside the process may press keys or click.
///
/// Nothing here calls the feature code directly. Key equivalents go through
/// the main menu, text goes through the field editor so the text field's
/// delegate fires, and buttons and toolbar items perform their own
/// target/action, exactly as a key press or click would.
@MainActor
enum UISelfTest {

    static func run(browser: BrowserWindowController, output: String) {
        Task { @MainActor in
            var report: [String: Any] = [:]
            var failures: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
                if !ok { failures.append(detail.map { "\(name): \($0)" } ?? name) }
            }
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

            // Which menu items actually fired, in order.
            var fired: [String] = []
            var expectedFired = ["Settings…", "Home"]
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) { note in
                let title = (note.userInfo?["MenuItem"] as? NSMenuItem)?.title ?? "?"
                MainActor.assumeIsolated { fired.append(title) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            var keyLog: [String] = []
            await pause(2)
            // Launched from a background shell the app is not always made
            // active, and macOS may hand focus back to whatever the user is in.
            // An inactive app has no key window for menu actions to resolve
            // to; that is the environment, not the product, so say so.
            var environment: [String] = []
            /// Focus can be taken back between activating and pressing, so the
            /// check and the key press must not have a suspension between them:
            /// `body` runs synchronously once the browser window is key.
            @MainActor func whenKey(_ step: String, window: NSWindow? = nil, _ body: () -> Void) async -> Bool {
                let window = window ?? browser.window
                for _ in 0..<30 {
                    if NSApp.isActive, window?.isKeyWindow == true { body(); return true }
                    QuietMode.activate()
                    window?.makeKeyAndOrderFront(nil)
                    await pause(0.4)
                }
                let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
                environment.append("\(step): macOS would not make the window key" + (locked ? " because the screen is locked" : ""))
                return false
            }
            let startURL = browser.currentURL
            // A scratch settings suite, emptied first: the user's own homepage
            // is never read or written, even if this run is killed half way.
            let suite = "Keel.ui-selftest"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let scratch = UserDefaults(suiteName: suite) { BrowserSettings.store = scratch }
            check("the self-test got its own settings suite", BrowserSettings.store !== UserDefaults.standard)

            // 1. ⌘, opens Settings through the menu's key equivalent.
            let couldPress = await whenKey("⌘,") {
                check("⌘, is handled by the menu", press(keyCode: 43, .maskCommand, log: &keyLog))
            }
            guard couldPress else {
                report["environment"] = environment
                report["failures"] = [String]()
                report["passed"] = false
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
                }
                return
            }
            await pause(0.6)
            let settings = NSApp.windows.first { $0.title == "Settings" && $0.isVisible }
            check("Settings window opened", settings != nil, NSApp.windows.map(\.title))

            if let settings {
                let field = views(of: NSTextField.self, in: settings).first { $0.isEditable }
                check("homepage field exists", field != nil)
                report["labelsEmpty"] = labels(in: settings)
                check("empty field explains the default", labels(in: settings).contains { $0.contains("default") && $0.contains("duckduckgo.com") }, labels(in: settings))

                // 2. Type a bare host-and-path, the way a person would.
                if let field {
                    settings.makeKeyAndOrderFront(nil)
                    settings.makeFirstResponder(field)
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.selectAll(nil)
                        editor.insertText("127.0.0.1:8765/api/data.json?typed=1", replacementRange: editor.selectedRange())
                    } else { check("field editor available", false) }
                    await pause(0.4)
                    report["typedField"] = field.stringValue
                    report["storedAfterTyping"] = BrowserSettings.homepage
                    report["labelsTyped"] = labels(in: settings)
                    check("typing saves the setting as you type", BrowserSettings.homepage == "127.0.0.1:8765/api/data.json?typed=1", BrowserSettings.homepage)
                    check("label shows the resolved address", labels(in: settings).contains { $0 == "Home opens https://127.0.0.1:8765/api/data.json?typed=1" }, labels(in: settings))

                    // A search phrase is refused, visibly.
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.selectAll(nil)
                        editor.insertText("cute cats", replacementRange: editor.selectedRange())
                    }
                    await pause(0.3)
                    report["labelsSearchPhrase"] = labels(in: settings)
                    check("a search phrase is not accepted as a homepage", labels(in: settings).contains { $0.contains("not a web address") }, labels(in: settings))
                    check("Home still resolves to the default then", BrowserSettings.homepageURL.absoluteString == "https://duckduckgo.com/", BrowserSettings.homepageURL.absoluteString)

                    // Use a plain-http fixture URL for the navigation checks.
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.selectAll(nil)
                        editor.insertText("http://127.0.0.1:8765/api/data.json?home=1", replacementRange: editor.selectedRange())
                    }
                    await pause(0.3)
                }
            }

            // 3. The Home toolbar button performs its own action.
            browser.window?.makeKeyAndOrderFront(nil)
            let homeItem = browser.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "home" }
            check("Home toolbar item exists", homeItem != nil, browser.window?.toolbar?.items.map(\.itemIdentifier.rawValue))
            if let homeItem, let action = homeItem.action {
                report["homeItem"] = ["label": homeItem.label, "toolTip": homeItem.toolTip ?? "", "hasImage": homeItem.image != nil]
                check("Home button click is delivered", NSApp.sendAction(action, to: homeItem.target, from: homeItem))
            }
            await pause(2)
            report["afterHomeButton"] = browser.currentURL?.absoluteString ?? "nil"
            check("Home button opens the homepage", browser.currentURL?.absoluteString == "http://127.0.0.1:8765/api/data.json?home=1", browser.currentURL?.absoluteString)

            // 4. ⇧⌘H from somewhere else.
            if let startURL { browser.load(startURL) }
            await pause(2)
            check("navigated away before the shortcut", browser.currentURL == startURL, browser.currentURL?.absoluteString)
            let activeForShortcut = await whenKey("⇧⌘H") {
                check("⇧⌘H is handled by the menu", press(keyCode: 4, [.maskCommand, .maskShift], log: &keyLog))
            }
            await pause(2)
            report["afterShortcut"] = browser.currentURL?.absoluteString ?? "nil"
            if activeForShortcut { check("⇧⌘H opens the homepage", browser.currentURL?.absoluteString == "http://127.0.0.1:8765/api/data.json?home=1", browser.currentURL?.absoluteString) }

            // 5. ⇧⌘H while Settings is the key window acts on the browser behind it.
            if let settings = NSApp.windows.first(where: { $0.title == "Settings" }), let startURL {
                browser.load(startURL)
                await pause(2)
                let pressed = await whenKey("⇧⌘H from Settings", window: settings) {
                    check("⇧⌘H is handled while Settings is key", press(keyCode: 4, [.maskCommand, .maskShift], log: &keyLog))
                }
                await pause(2)
                report["afterShortcutFromSettings"] = browser.currentURL?.absoluteString ?? "nil"
                if pressed {
                    check("⇧⌘H from Settings sends the browser window home", browser.currentURL?.absoluteString == "http://127.0.0.1:8765/api/data.json?home=1", browser.currentURL?.absoluteString)
                }
                expectedFired.append("Home")
            }

            // 6. The two buttons in Settings.
            if let settings = NSApp.windows.first(where: { $0.title == "Settings" }) {
                settings.makeKeyAndOrderFront(nil)
                await pause(0.3)
                let buttons = views(of: NSButton.self, in: settings)
                report["buttons"] = buttons.map { "\($0.title) enabled=\($0.isEnabled)" }
                if let reset = buttons.first(where: { $0.title == "Reset to Default" }) {
                    reset.performClick(nil)
                    await pause(0.3)
                    check("Reset to Default clears the setting", BrowserSettings.homepage.isEmpty, BrowserSettings.homepage)
                    check("Reset to Default disables itself", !reset.isEnabled)
                }
                if let useCurrent = buttons.first(where: { $0.title == "Set to Current Page" }) {
                    check("Set to Current Page is enabled with a page open", useCurrent.isEnabled)
                    useCurrent.performClick(nil)
                    await pause(0.3)
                    report["afterSetCurrent"] = BrowserSettings.homepage
                    check("Set to Current Page stores the page's URL", BrowserSettings.homepage == browser.currentURL?.absoluteString, BrowserSettings.homepage)
                }
            }

            // 7. "New windows open with" decides what ⌘N starts with.
            if let settings = NSApp.windows.first(where: { $0.title == "Settings" }),
               let popUp = views(of: NSPopUpButton.self, in: settings).first(where: { $0.itemTitles.contains("Empty Page") }) {
                report["newWindowChoices"] = popUp.itemTitles
                var opened: [String: String] = [:]
                for (choice, expected) in [("Empty Page", nil), ("Homepage", BrowserSettings.homepageURL.absoluteString),
                                           ("Start Page", StartPageSchemeHandler.url.absoluteString)] as [(String, String?)] {
                    popUp.selectItem(withTitle: choice)
                    if let action = popUp.action { NSApp.sendAction(action, to: popUp.target, from: popUp) }
                    check("choosing \(choice) is saved", BrowserSettings.newWindowContent.title == choice, BrowserSettings.newWindowContent.rawValue)

                    let before = Set(NSApp.windows.map(ObjectIdentifier.init))
                    let pressed = await whenKey("⌘N with \(choice)") {
                        check("⌘N is handled by the menu", press(keyCode: 45, .maskCommand, log: &keyLog))
                    }
                    guard pressed else { continue }
                    expectedFired.append("New Window")
                    await pause(2.5)
                    let created = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.windowController is BrowserWindowController }
                    check("⌘N with \(choice) opened a window", created != nil)
                    guard let created, let controller = created.windowController as? BrowserWindowController else { continue }
                    opened[choice] = controller.currentURL?.absoluteString ?? "nothing"
                    check("a new window with \(choice) shows the right page", controller.currentURL?.absoluteString == expected, opened[choice])
                    let editor = created.firstResponder as? NSTextView
                    check("the address bar has focus in a new window with \(choice)", editor?.delegate is NSTextField, String(describing: created.firstResponder))
                    created.close()
                    await pause(0.3)
                }
                report["newWindowsOpened"] = opened
            } else {
                check("the New windows pop-up exists", false)
            }

            report["keyEvents"] = keyLog
            report["menuItemsFired"] = fired
            if environment.isEmpty {
                check("the shortcuts fired exactly the expected menu items", fired == expectedFired, fired)
            }
            report["failures"] = failures
            report["environment"] = environment
            report["passed"] = failures.isEmpty && environment.isEmpty
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }

    /// Builds the key-down the window server would deliver for a physical key
    /// (the characters come from the keyboard layout, not from us) and sends
    /// it through the main menu. Creating a CGEvent needs no permission; only
    /// posting one to other apps does.
    private static func press(keyCode: CGKeyCode, _ modifiers: CGEventFlags, log: inout [String]) -> Bool {
        guard let cgEvent = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: keyCode, keyDown: true) else { return false }
        cgEvent.flags = modifiers
        guard let event = NSEvent(cgEvent: cgEvent) else { return false }
        log.append("keyCode \(keyCode): characters=[\(event.characters ?? "nil")] ignoringModifiers=[\(event.charactersIgnoringModifiers ?? "nil")]")
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private static func views<T: NSView>(of type: T.Type, in window: NSWindow) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return found
    }

    private static func labels(in window: NSWindow) -> [String] {
        views(of: NSTextField.self, in: window).filter { !$0.isEditable }.map(\.stringValue)
    }
}
