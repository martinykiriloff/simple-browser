import AppKit
import BrowserKit
import DataKit
import PasswordKit

/// #16 The first launch, and importing from Chrome, Safari and Firefox.
extension FeatureSelfTest {

    func importing() async {
        let browser = first
        let profile = browser.profile
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Keel-import-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let secret = "fixture-safe-storage"
        let key = ChromiumPasswords.key(from: secret)!
        do {
            try BrowserImportFixture.write(into: home, tabs: site + "/page?title=") { ChromiumPasswords.encrypt($0, key: key) }
        } catch {
            check("import: (setup) fixture browsers", false, error)
            return
        }
        let window = app.importWindow
        window.findSources = { BrowserImport.sources(home: home) }
        var askedForKey: [BrowserImport.Browser] = []
        window.importer.chromiumSecret = { browser in
            askedForKey.append(browser)
            return secret
        }
        var madeDefault = false
        var isDefault = false
        window.makeDefaultBrowser = {
            madeDefault = true
            isDefault = true
            return true
        }
        window.isDefaultBrowser = { isDefault }
        let before = app.browserControllers.count

        // The first launch.
        let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "File" }?.items.first { $0.title == "Import From…" }
        check("import: File → Import From…", menu?.action == #selector(AppDelegate.showImport(_:)))
        BrowserSettings.didFirstRun = false
        window.show(.firstRun)
        check("import: the first launch welcomes", window.window?.isVisible == true && window.headline.stringValue == "Welcome to Keel")
        check("import: …offering every browser on the Mac", window.sourcePopUp.itemTitles == ["Google Chrome — Ada", "Google Chrome — Work", "Firefox", "Safari"],
              window.sourcePopUp.itemTitles)
        check("import: …the search engine and the default browser", !window.enginePopUp.isHidden && !window.defaultButton.isHidden)
        check("import: everything is chosen to come over", window.parts == .all)
        check("import: the Keychain prompt is explained before it comes", window.note.stringValue.contains("Keychain"))
        snapshot(window.window, "import-first-run")

        // A Chrome user, one click.
        window.importClicked(nil)
        check("import: Import brings Chrome over", await waitFor(15) { window.lastResult != nil }, window.resultLabel.stringValue)
        let result = window.lastResult ?? .init()
        check("import: …saying what came", result.bookmarks == 5 && result.pages == 5 && result.tabs == 3 && result.passwords == 2 && result.problems.isEmpty,
              window.resultLabel.stringValue)
        check("import: …asking the Keychain for Chrome's key, once", askedForKey == [.chrome])
        let bookmarks = app.bookmarks(for: profile)
        // In order, after whatever favorites there were.
        let bar = BrowserImportFixture.chromeBar
        check("import: Chrome's bookmarks bar is the favorites bar", bookmarks?.favorites.map(\.title).filter(bar.contains) == bar,
              bookmarks?.favorites.map(\.title) as Any)
        check("import: …and shows under the toolbar", await waitFor { browser.favoritesBar.titles.filter(bar.contains) == bar }, browser.favoritesBar.titles)
        let vault = (try? await app.passwords(for: profile).store.all()) ?? []
        check("import: Chrome's passwords are saved, as they were", Set(vault.map { "\($0.origin) \($0.username)" }) .isSuperset(of: [
            "https://accounts.example.com ada@example.com", "https://shop.example.org ada"]), vault.map(\.origin))
        if let saved = vault.first(where: { $0.username == "ada@example.com" }) {
            check("import: …each with its password", (try? await app.passwords(for: profile).store.password(for: saved.id)) == "correct horse battery")
        }
        let opened = app.browserControllers.dropFirst(before)
        check("import: Chrome's open tabs, in their windows", opened.count == 3 && Set(opened.compactMap { $0.window?.tabbedWindows?.count }) == [2, 1],
              opened.map { $0.window?.title ?? "" })
        check("import: …asleep until shown", opened.filter(\.isHibernated).count >= 1)

        // The top sites: a new tab's start page.
        let content = BrowserSettings.newWindowContent
        BrowserSettings.newWindowContent = .startPage
        let fresh = app.newTab(beside: browser, inFront: false)
        _ = await waitFor { StartPageSchemeHandler.isStartPage(fresh.currentURL ?? URL(string: "x:")!) && !fresh.pageWebView.isLoading }
        func tiles(_ heading: String) async -> [String] {
            await js("""
                const heading = Array.from(document.querySelectorAll('h2')).find(h => h.textContent === '\(heading)');
                return heading ? Array.from(heading.parentElement.querySelectorAll('.tiles a')).map(a => a.href) : [];
                """, in: fresh) as? [String] ?? []
        }
        let favorites = await tiles("Favorites"), frequent = await tiles("Frequently Visited")
        // The start page leaves out of Frequently Visited what is a favorite already.
        check("import: Chrome's top sites are on the start page", favorites.contains(BrowserImportFixture.chromeTopSite.absoluteString)
              && frequent.prefix(2) == ["https://news.ycombinator.com/", "https://mail.google.com/mail/u/0/"], (favorites, frequent))
        snapshot(fresh.window, "import-start-page")
        BrowserSettings.newWindowContent = content
        fresh.window?.performClose(nil)

        // Again: nothing doubles.
        window.importClicked(nil)
        check("import: importing again", await waitFor(15) { !window.isImporting && window.lastResult != result })
        check("import: …brings nothing twice", window.lastResult?.bookmarks == 0 && window.lastResult?.passwords == 0
              && bookmarks?.favorites.map(\.title).filter { $0 == "GitHub" }.count == 1, window.resultLabel.stringValue)
        for tab in app.browserControllers.dropFirst(before) { tab.window?.performClose(nil) }

        // The search engine and the default browser, on the first launch.
        window.enginePopUp.selectItem(withTitle: "Kagi")
        _ = window.enginePopUp.target?.perform(window.enginePopUp.action, with: window.enginePopUp)
        check("import: the search engine is chosen there", BrowserSettings.searchEngine.id == "kagi", BrowserSettings.searchEngine.id)
        BrowserSettings.searchEngine = .default
        window.makeDefault(nil)
        check("import: Make Default asks macOS", await waitFor { madeDefault && window.defaultButton.isHidden && window.defaultLabel.stringValue.contains("opens your web links") })
        window.finish(nil)
        check("import: Start Browsing closes it, for good", window.window?.isVisible == false && BrowserSettings.didFirstRun)

        // Firefox: its tabs; its passwords from a file.
        window.show(.importOnly)
        check("import: File → Import From… is the same, without the welcome", window.enginePopUp.isHidden && window.headline.stringValue.hasPrefix("Import"))
        window.sourcePopUp.selectItem(withTitle: "Firefox")
        _ = window.sourcePopUp.target?.perform(window.sourcePopUp.action, with: window.sourcePopUp)
        check("import: Firefox's passwords are not offered, and where to get them is said", !window.passwordsBox.isEnabled
              && window.note.stringValue.contains("about:logins") && !window.noteButton.isHidden)
        let foxBefore = app.browserControllers.count
        window.importClicked(nil)
        check("import: Firefox comes over", await waitFor(15) { !window.isImporting && window.lastResult?.tabs == 1 }, window.resultLabel.stringValue)
        check("import: …its toolbar into the favorites bar", bookmarks?.favorites.contains { $0.title == "MDN" } == true)
        for tab in app.browserControllers.dropFirst(foxBefore) { tab.window?.performClose(nil) }

        // Safari, without Full Disk Access.
        for file in ["Bookmarks.plist", "History.db"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: home.appendingPathComponent("Library/Safari/\(file)").path)
        }
        window.show(.importOnly)
        window.sourcePopUp.selectItem(withTitle: "Safari")
        _ = window.sourcePopUp.target?.perform(window.sourcePopUp.action, with: window.sourcePopUp)
        check("import: Safari without Full Disk Access says what to do", window.note.stringValue.contains("Full Disk Access")
              && window.noteButton.title == "Open Privacy Settings" && !window.importButton.isEnabled)
        snapshot(window.window, "import-safari")
        window.window?.close()
        _ = await waitFor { self.tabs(of: browser).count == 1 }
    }
}
