import AppKit
import WebKit
import BrowserKit

/// #15 Web extensions.
extension FeatureSelfTest {

    func webExtensions() async {
        let browser = first
        let profile = browser.profile
        let store = app.extensionStore
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Keel-fixture-extension-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { try Self.writeFixtureExtension(to: folder) } catch { check("extensions: (setup) a fixture extension", false, error); return }

        // Adding it, from Settings.
        let settings = app.settingsWindow
        let pane = settings.extensionsPane
        settings.show(.extensions)
        check("extensions: Settings has an Extensions pane", settings.selectedPane == .extensions && pane.isViewLoaded)
        var asked: (String, [String])?
        store.confirmInstall = { name, lines in
            asked = (name, lines)
            return true
        }
        pane.chooseSource = { folder }
        pane.add(nil)
        check("extensions: Add Extension… adds it", await waitFor(10) { store.installed.count == 1 }, pane.statusLabel.stringValue)
        guard let item = store.installed.first else { return }
        check("extensions: …after saying, in plain words, what it could do", asked?.0 == "Fixture Filler"
              && asked?.1.first == "Read and change your data on 127.0.0.1" && asked?.1.contains("See the addresses and titles of your open tabs") == true,
              asked as Any)
        check("extensions: its files are kept by the browser, not where they came from", FileManager.default.fileExists(atPath: store.folder(of: item).appendingPathComponent("manifest.json").path)
              && !store.folder(of: item).path.hasPrefix(folder.path))
        let running = app.extensions(for: profile)
        check("extensions: it runs in the profile it was added to", await waitFor(10) { running.contexts[item.id]?.isLoaded == true }, running.loadErrors)
        check("extensions: the pane lists it, on", pane.table.numberOfRows == 1 && pane.enabledCheckbox.state == .on)
        settings.window?.close()

        // In the pages.
        await open("/signin", in: browser)
        check("extensions: its content script runs in the page", await waitFor(8) {
            (await self.js("return document.documentElement.dataset.fixtureExtension || ''", in: browser) as? String) == "ran"
        })
        check("extensions: its button is in the toolbar", await waitFor { browser.extensionButton(for: item.id) != nil && browser.extensionsItem?.isHidden == false })
        check("extensions: …with the badge its background worker set", await waitFor(8) { browser.extensionButton(for: item.id)?.badge == "3" },
              browser.extensionButton(for: item.id)?.badge as Any)
        check("extensions: every toolbar button still fits", browser.overflowingToolbarItems.isEmpty, browser.overflowingToolbarItems)
        snapshot(browser.window, "extensions-toolbar")

        // A password manager's job: the popup fills the sign-in form.
        if let button = browser.extensionButton(for: item.id) { browser.extensionButtonClicked(button) }
        check("extensions: its button opens its popup", await waitFor(8) { running.lastPopup?.popupWebView?.isLoading == false && running.lastPopup?.popupPopover?.isShown == true })
        if let popup = running.lastPopup?.popupWebView {
            _ = try? await popup.evaluateJavaScript("document.getElementById('fill').click()")
            check("extensions: the popup fills the sign-in form, through chrome.tabs", await waitFor(8) {
                let fields = await self.js("return [document.getElementById('username').value, document.getElementById('password').value]", in: browser) as? [String]
                return fields == ["ada@example.com", "correct horse battery"]
            })
            let result = try? await popup.evaluateJavaScript("document.body.dataset.result || ''") as? String
            check("extensions: …and hears back from the page", result == #"{"filled":true}"#, result as Any)
            snapshot(browser.window, "extensions-popup")
            running.lastPopup?.closePopup()
        }
        check("extensions: its items are in the page's right-click menu", await waitFor(5) { browser.extensionMenuItems().contains { $0.title == "Fixture Filler: Fill" } },
              browser.extensionMenuItems().map(\.title))

        // Only where it may.
        store.setAccess(item.id, .sites(["example.com"]), in: profile)
        _ = await waitFor { running.contexts[item.id]?.hasAccess(to: URL(string: self.site + "/signin")!) == false }
        await open("/second", in: browser)
        let blockedHere = await js("return document.documentElement.dataset.fixtureExtension || ''", in: browser) as? String
        check("extensions: limited to other sites, it does not run here", blockedHere == "", blockedHere as Any)
        store.setAccess(item.id, .allRequested, in: profile)
        _ = await waitFor { running.contexts[item.id]?.hasAccess(to: URL(string: self.site + "/signin")!) == true }

        // Another profile has its own.
        let other = Profile(name: "Extension isolation")
        let elsewhere = ProfileExtensions(profile: other, store: store, dataStore: .nonPersistent(), persistent: false)
        await elsewhere.sync()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = elsewhere.controller.configuration.defaultWebsiteDataStore
        configuration.webExtensionController = elsewhere.controller
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let holder = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        QuietMode.apply(to: holder)
        QuietMode.apply(to: page)
        holder.isReleasedWhenClosed = false
        holder.contentView = page
        holder.orderBack(nil)
        defer { holder.close() }
        func marked() async -> String? {
            page.load(URLRequest(url: URL(string: site + "/signin")!))
            _ = await waitFor { !page.isLoading && page.url != nil }
            await pause(0.5)
            return try? await page.evaluateJavaScript("document.documentElement.dataset.fixtureExtension || ''") as? String
        }
        let beforeOn = await marked()
        check("extensions: one profile's extension does not run in another's", elsewhere.contexts.isEmpty && beforeOn == "", beforeOn as Any)
        store.setEnabled(item.id, true, in: other)
        await elsewhere.sync()
        var afterOn: String?
        let ran = await waitFor(10) {
            afterOn = await marked()
            return afterOn == "ran"
        }
        check("extensions: …until it is turned on there too", elsewhere.contexts[item.id] != nil && ran, afterOn as Any)
        store.setEnabled(item.id, false, in: other)
        await elsewhere.sync()
        check("extensions: …and turning it off there leaves this one's on", elsewhere.contexts.isEmpty && running.contexts[item.id] != nil)

        // Private windows run none.
        app.newPrivateWindow(nil)
        let privately = app.browserControllers.last { $0.isPrivate }
        check("extensions: a private window runs no extensions", privately?.extensions == nil && privately?.pageWebView.configuration.webExtensionController == nil)
        privately?.window?.performClose(nil)

        // A .crx from the Chrome Web Store, and saying no.
        let zip = folder.deletingLastPathComponent().appendingPathComponent("fixture-\(UUID().uuidString).zip")
        let crx = zip.deletingPathExtension().appendingPathExtension("crx")
        defer { try? FileManager.default.removeItem(at: zip); try? FileManager.default.removeItem(at: crx) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()
        if let data = try? Data(contentsOf: zip) {
            try? (Data("Cr24".utf8) + Data([3, 0, 0, 0, 4, 0, 0, 0, 1, 2, 3, 4]) + data).write(to: crx)
        }
        store.confirmInstall = { _, _ in false }
        _ = try? await store.install(from: crx, for: profile)
        check("extensions: saying no adds nothing, and keeps nothing", store.installed.count == 1
              && (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0 != "Extensions.json" }.count) == 1)
        store.confirmInstall = { _, _ in true }
        let fromCRX = try? await store.install(from: crx, for: profile)
        check("extensions: a .crx is added", fromCRX?.name == "Fixture Filler" && store.installed.count == 2)
        if let fromCRX { store.remove(fromCRX.id) }

        // Removing.
        settings.show(.extensions)
        pane.table.selectRowIndexes([0], byExtendingSelection: false)
        pane.remove(nil)
        check("extensions: Remove takes it away", await waitFor { store.installed.isEmpty && running.contexts.isEmpty && browser.extensionButton(for: item.id) == nil })
        check("extensions: …and its files", !FileManager.default.fileExists(atPath: store.folder(of: item).path))
        settings.window?.close()
    }

    /// A password manager in miniature: a content script that fills sign-in
    /// forms when asked, a popup that asks, a background worker with a badge
    /// and a right-click item.
    static func writeFixtureExtension(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files: [String: String] = [
            "manifest.json": """
                {"manifest_version": 3, "name": "Fixture Filler", "version": "1.2", "description": "Fills sign-in forms, for tests.",
                 "permissions": ["storage", "activeTab", "tabs", "contextMenus"],
                 "host_permissions": ["http://127.0.0.1/*"],
                 "action": {"default_title": "Fixture Filler", "default_popup": "popup.html", "default_icon": {"16": "icon.png", "32": "icon.png"}},
                 "icons": {"48": "icon.png"},
                 "background": {"service_worker": "background.js"},
                 "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_end"}]}
                """,
            "content.js": """
                document.documentElement.dataset.fixtureExtension = "ran";
                chrome.runtime.onMessage.addListener((message, sender, reply) => {
                  if (!message.fill) return;
                  const user = document.querySelector('input[name=username], input[type=email]');
                  const password = document.querySelector('input[type=password]');
                  if (user) user.value = message.fill.username;
                  if (password) password.value = message.fill.password;
                  reply({filled: !!(user && password)});
                });
                """,
            "popup.html": "<!doctype html><meta charset=utf-8><body style='width:160px'><button id=fill>Fill</button><script src=popup.js></script>",
            "popup.js": """
                document.getElementById('fill').addEventListener('click', async () => {
                  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
                  const answer = await chrome.tabs.sendMessage(tab.id, {fill: {username: 'ada@example.com', password: 'correct horse battery'}});
                  document.body.dataset.result = JSON.stringify(answer);
                });
                """,
            "background.js": """
                // Made each time the worker starts, not in runtime.onInstalled, which this
                // WebKit does not deliver (measured; see the README).
                chrome.contextMenus.removeAll(() => {
                  chrome.contextMenus.create({id: 'fill', title: 'Fixture Filler: Fill', contexts: ['all']});
                });
                chrome.action.setBadgeText({text: '3'});
                """,
        ]
        for (name, text) in files { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: folder.appendingPathComponent("icon.png"))
        }
    }
}
