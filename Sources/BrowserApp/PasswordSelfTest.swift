import AppKit
import PasswordKit

/// Developer aid (`--passwords-selftest <file>`, run by `scripts/test-passwords.sh`):
/// signs in to the fixture site the way a person would and checks what the
/// password manager does about it.
///
/// It acts through the page and through the app's own controls -- typing into
/// fields, pressing the page's buttons, clicking Save in the prompt, choosing
/// rows in the list under a field -- and then reads the vault to see what
/// really happened. The vault and settings it uses are scratch copies: the
/// user's own passwords are never opened.
@MainActor
enum PasswordSelfTest {

    private final class ScriptedAuthenticator: PasswordAuthenticator {
        var answer = true
        var asked: [String] = []
        func authenticate(reason: String) async -> Bool {
            asked.append(reason)
            return answer
        }
    }

    /// - Parameter snapshots: a directory to save pictures of the prompt, the
    ///   list and the Settings pane into, for a person to look at.
    static func run(app: AppDelegate, browser: BrowserWindowController, output: String, snapshots: String? = nil) {
        Task { @MainActor in
            var report: [String: Any] = [:]
            var failures: [String] = []
            var environment: [String] = []
            var passed = 0
            func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
                if ok { passed += 1 } else { failures.append(detail.map { "\(name): \($0)" } ?? name) }
            }
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func waitFor(_ seconds: Double = 6, _ condition: () async -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if await condition() { return true }
                    await pause(0.1)
                }
                return await condition()
            }

            @MainActor func snapshot(_ window: NSWindow?, _ name: String) {
                guard let snapshots, let window else { return }
                window.displayIfNeeded()
                AppDelegate.snapshot(window, to: snapshots + "/" + name + ".png")
            }

            let site = "http://127.0.0.1:8766"
            let other = "http://localhost:8766"
            let coordinator = browser.passwordCoordinator
            let store = app.passwords.store
            let authenticator = ScriptedAuthenticator()
            app.passwords.authenticator = authenticator

            // Scratch settings, as the UI self-test uses: never the user's own.
            let suite = "SimpleBrowser.passwords-selftest"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let scratch = UserDefaults(suiteName: suite) { BrowserSettings.store = scratch }
            check("the self-test has its own settings suite", BrowserSettings.store !== UserDefaults.standard)
            check("the agent was installed", coordinator.installError == nil, coordinator.installError)

            // MARK: Acting as the person at the keyboard

            @MainActor func js(_ script: String) async -> Any? {
                try? await browser.evaluateInPage(script)
            }
            @MainActor func open(_ path: String, on origin: String? = nil) async {
                let base = origin ?? site
                browser.load(URL(string: base + path)!)
                _ = await waitFor {
                    guard browser.currentURL?.absoluteString == base + path else { return false }
                    return (await js("return document.readyState") as? String) == "complete"
                }
                await pause(0.5)   // the agent's report, the vault lookup, the fill
            }
            /// Typing: the value changes beneath any framework's tracking and
            /// an input event follows, which is what a key press amounts to.
            @MainActor func type(_ selector: String, _ text: String) async {
                _ = await js("""
                const el = document.querySelector('\(selector)');
                el.focus();
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, '\(text)');
                el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '\(text)', inputType: 'insertText' }));
                """)
            }
            @MainActor func click(_ selector: String) async { _ = await js("document.querySelector('\(selector)').click()") }
            @MainActor func value(_ selector: String) async -> String { await js("return document.querySelector('\(selector)').value") as? String ?? "<missing>" }
            /// Every listed field holds the listed value.
            @MainActor func fields(_ expected: [String: String]) async -> Bool {
                for (selector, wanted) in expected where await value(selector) != wanted { return false }
                return true
            }
            @MainActor func path() async -> String { await js("return location.pathname") as? String ?? "" }
            @MainActor func signIn(_ username: String, _ password: String) async {
                await type("#username", username)
                await type("#password", password)
                await click("#submit")
            }
            @MainActor func promptAppears() async -> Bool { await waitFor { coordinator.promptController != nil } }
            @MainActor func noPrompt(_ seconds: Double = 2.2) async -> Bool {
                !(await waitFor(seconds) { coordinator.promptController != nil || coordinator.hasPrompt })
            }
            @MainActor func press(_ title: String) -> Bool {
                guard let button = coordinator.promptController?.buttons.first(where: { $0.title == title }) else { return false }
                button.performClick(nil)
                return true
            }
            @MainActor func saved() async -> [String: String] {
                var result: [String: String] = [:]
                for credential in (try? await store.all()) ?? [] {
                    result[credential.origin + " " + credential.username] = (try? await store.password(for: credential.id)) ?? "<unreadable>"
                }
                return result
            }
            /// DOM focus only reaches the agent when the page really has focus,
            /// which needs a key window; see the UI self-test for why the check
            /// and the act share a run-loop turn.
            @MainActor func focusField(_ selector: String, step: String) async -> Bool {
                for _ in 0..<30 {
                    if NSApp.isActive, browser.window?.isKeyWindow == true {
                        browser.focusPage()
                        _ = await js("document.activeElement && document.activeElement.blur(); document.querySelector('\(selector)').focus()")
                        return true
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    browser.window?.makeKeyAndOrderFront(nil)
                    await pause(0.4)
                }
                environment.append("\(step): macOS would not make the browser window key, so the page could not take focus")
                return false
            }

            await pause(1.5)
            _ = await js("await fetch('/reset', { method: 'POST' })")

            // MARK: 1. A first sign-in is offered, saved, and encrypted on disk

            await open("/login")
            check("nothing is filled when nothing is saved", await value("#password") == "")
            await signIn("ada", "correct-horse")
            check("1. a successful sign-in is followed by “Save password?”", await promptAppears(), coordinator.trace.suffix(6))
            check("1. the prompt names the account", coordinator.promptController?.usernameField.stringValue == "ada")
            check("1. the prompt is for saving, not updating", coordinator.promptController?.titleText == "Save password?")
            check("1. the prompt survived the page load that followed the sign-in", await path() == "/welcome")
            check("1. the key button says a password is waiting", browser.passwordsToolbarItem?.toolTip == "Save this password?", browser.passwordsToolbarItem?.toolTip)
            check("1. nothing is saved before the answer", await saved().isEmpty)
            await pause(0.4)
            snapshot(coordinator.promptController?.view.window, "1-save-prompt")
            snapshot(browser.window, "1-browser-with-prompt")
            check("1. Save is there to press", press("Save"))
            check("1. the sign-in is saved", await waitFor { await saved() == ["\(site) ada": "correct-horse"] }, await saved())
            check("1. the prompt is gone", await waitFor { coordinator.promptController == nil && !coordinator.hasPrompt })

            // MARK: 2. It is filled in next time, and not offered again

            await open("/login")
            check("2. the username is filled on load", await waitFor { await value("#username") == "ada" }, await value("#username"))
            check("2. the password is filled on load", await value("#password") == "correct-horse")
            check("2. the unrelated search box is left alone", await value("input[name=q]") == "")
            check("2. the key button shows the site has a saved sign-in", await waitFor { browser.passwordsToolbarItem?.toolTip == "1 password saved for this site" }, browser.passwordsToolbarItem?.toolTip)
            await click("#submit")
            _ = await waitFor { await path() == "/welcome" }
            check("2. signing in with the saved password asks nothing", await noPrompt(), coordinator.trace.suffix(6))
            check("2. …and marks the sign-in as used", await waitFor { ((try? await store.all())?.first?.lastUsedAt) != nil })

            // MARK: 3. A wrong password is not offered

            await open("/login")
            await signIn("ada", "not-the-password")
            _ = await waitFor { (await js("return document.getElementById('error').textContent") as? String)?.isEmpty == false }
            check("3. a rejected sign-in is not offered for saving", await noPrompt(), coordinator.trace.suffix(6))
            check("3. …because the sign-in form came back", coordinator.trace.contains("the sign-in form came back: not offering to save"))
            check("3. the saved password is untouched", await saved() == ["\(site) ada": "correct-horse"])

            // MARK: 4. “Show password” ticked before signing in

            await open("/login")
            await type("#username", "bob")
            await type("#password", "bobs-password")
            await click("#show")
            check("4. the page turned the field into a text field", await js("return document.getElementById('password').type") as? String == "text")
            await click("#submit")
            check("4. a second account is offered even with the password shown", await promptAppears(), coordinator.trace.suffix(6))
            check("4. …as bob, not the search box or anything else", coordinator.promptController?.usernameField.stringValue == "bob")
            _ = press("Save")
            check("4. both accounts are saved", await waitFor { await saved().count == 2 }, await saved().keys.sorted())

            // MARK: 5. The list under the field

            await open("/login")
            check("5. the most recently used account is the one filled", await waitFor { await value("#username") == "bob" }, await value("#username"))
            if await focusField("#username", step: "5. the list under the field") {
                check("5. focusing the field drops the list", await waitFor { coordinator.suggestions.isVisible }, coordinator.trace.suffix(6))
                snapshot(coordinator.suggestions.rows.first?.window, "5-list-under-field")
                check("5. it offers both accounts, then Manage", coordinator.suggestions.titles == ["bob", "ada", "Manage Passwords…"], coordinator.suggestions.titles)
                if let frame = coordinator.suggestions.rows.first?.window?.frame, let window = browser.window {
                    check("5. the list sits inside the window, under the toolbar", window.frame.contains(frame) && frame.maxY < window.frame.maxY - 40, "\(frame) in \(window.frame)")
                }
                coordinator.suggestions.rows.first { $0.item.title == "ada" }?.choose()
                check("5. choosing ada fills ada", await waitFor { await fields(["#username": "ada", "#password": "correct-horse"]) }, [await value("#username"), await value("#password")])
                check("5. the list closes after a choice", !coordinator.suggestions.isVisible)

                if await focusField("#password", step: "5. keyboard") {
                    _ = await waitFor { coordinator.suggestions.isVisible }
                    @MainActor func key(_ code: UInt16) -> Bool {
                        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: browser.window?.windowNumber ?? 0,
                                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return false }
                        return coordinator.suggestions.handleKeyDown(event)
                    }
                    check("5. Return with nothing highlighted is left for the page", !key(36))
                    check("5. ↓ ↓ ↑ ↩ are the list's keys", key(125) && key(125) && key(126) && key(36))
                    check("5. …and chose the first row, bob", await waitFor { await fields(["#username": "bob", "#password": "bobs-password"]) }, await value("#username"))
                    _ = await focusField("#username", step: "5. escape")
                    _ = await waitFor { coordinator.suggestions.isVisible }
                    check("5. Escape closes the list", key(53) && !coordinator.suggestions.isVisible)
                }

                _ = await focusField("#username", step: "5. filter")
                await type("#username", "a")
                check("5. typing narrows the list to matching accounts", await waitFor { coordinator.suggestions.titles == ["ada", "Manage Passwords…"] }, coordinator.suggestions.titles)
                await type("#username", "zed")
                check("5. no match, no list", await waitFor { !coordinator.suggestions.isVisible })
            }

            // MARK: 6. A changed password is offered as an update, for the right account

            await open("/change")
            await type("#current", "correct-horse")
            await type("#new", "new-horse-2026")
            await type("#confirm", "new-horse-2026")
            await click("#submit")
            check("6. changing a password on the site is followed by “Update password?”", await promptAppears(), coordinator.trace.suffix(6))
            check("6. …titled as an update", coordinator.promptController?.titleText == "Update password?")
            check("6. …for ada, whose current password was typed, not bob", coordinator.promptController?.usernameField.stringValue == "ada")
            await pause(0.4)
            snapshot(coordinator.promptController?.view.window, "6-update-prompt")
            check("6. an update has no Never button", coordinator.promptController?.buttons.map(\.title) == ["Not Now", "Update"], coordinator.promptController?.buttons.map(\.title))
            _ = press("Update")
            check("6. ada's password is updated, bob's is not", await waitFor { await saved() == ["\(site) ada": "new-horse-2026", "\(site) bob": "bobs-password"] }, await saved())
            await open("/login")
            _ = await js("await fetch('/reset', { method: 'POST' })")

            // MARK: 7. Never for this site

            try? await store.deleteAll()
            app.passwords.changed()
            await open("/login")
            await signIn("ada", "correct-horse")
            check("7. offered again once nothing is saved", await promptAppears())
            check("7. Never is there to press", press("Never for This Site"))
            check("7. the site is remembered as never", await waitFor { BrowserSettings.neverSavePasswordOrigins == [site] }, BrowserSettings.neverSavePasswordOrigins)
            await open("/login")
            await signIn("ada", "correct-horse")
            _ = await waitFor { await path() == "/welcome" }
            check("7. a never site is not asked about again", await noPrompt(), coordinator.trace.suffix(6))
            check("7. …and nothing was saved", await saved().isEmpty)
            app.passwords.allowSaving(site)

            // MARK: 8. A single-page sign-in, with no form and no page load

            await open("/spa")
            await signIn("ada", "wrong-on-purpose")
            _ = await waitFor { (await js("return document.getElementById('error').textContent") as? String)?.isEmpty == false }
            check("8. a rejected single-page sign-in is not offered", await noPrompt(1.5), coordinator.trace.suffix(6))
            await type("#password", "correct-horse")
            await click("#submit")
            check("8. the page swapped its sign-in form away without loading", await waitFor { (await js("return location.pathname === '/spa' && !!document.getElementById('signed-in')") as? Bool) == true })
            check("8. that is recognised as a successful sign-in", await promptAppears(), coordinator.trace.suffix(8))
            check("8. with the password that worked, not the rejected one", coordinator.promptController?.passwordField.stringValue == "correct-horse")
            _ = press("Not Now")
            check("8. Not Now forgets the question", await waitFor { !coordinator.hasPrompt })
            check("8. …and saves nothing", await saved().isEmpty)

            // MARK: 9. Sign-up with a generated password

            await open("/signup")
            await type("#fullname", "Grace Hopper")
            await type("#email", "grace@example.com")
            if await focusField("#password", step: "9. strong password") {
                check("9. a new-password field is offered a strong password", await waitFor { coordinator.suggestions.titles.first == "Use Strong Password" }, coordinator.suggestions.titles)
                snapshot(coordinator.suggestions.rows.first?.window, "9-strong-password")
                let offered = coordinator.suggestions.rows.first?.item.subtitle ?? ""
                check("9. the offer shows the password it would use", offered.split(separator: "-").count == 3 && offered.count == 20, offered)
                coordinator.suggestions.rows.first?.choose()
                check("9. it goes into the password field and its confirmation", await waitFor { await fields(["#password": offered, "#confirm": offered]) }, [await value("#password"), await value("#confirm")])
                check("9. it is saved at once, under the email, not the full name", await waitFor { await saved() == ["\(site) grace@example.com": offered] }, await saved())
                await click("#submit")
                _ = await waitFor { await path() == "/welcome" }
                check("9. submitting the sign-up asks nothing more", await noPrompt(), coordinator.trace.suffix(6))
                let server = await js("return await (await fetch('/state')).json()") as? [String: Any]
                check("9. the site received the very password that was saved", server?["grace@example.com"] as? String == offered, server)
            }

            // MARK: 10. A React-style controlled form

            try? await store.deleteAll()
            _ = try? await store.save(origin: site, username: "ada", password: "correct-horse")
            app.passwords.changed()
            await open("/react")
            check("10. a controlled form is filled", await waitFor { await value("#password") == "correct-horse" }, await value("#password"))
            let state = await js("return window.__state") as? [String: Any]
            check("10. …and the framework's own state saw the fill, not only the DOM", state?["username"] as? String == "ada" && state?["password"] as? String == "correct-horse", state)
            await click("#submit")
            check("10. the page signs in with what was filled", await waitFor { (await js("return document.getElementById('result').textContent") as? String) == "ok" })
            check("10. an already saved sign-in asks nothing", await noPrompt(1.5))

            // MARK: 11. Origins and frames

            _ = try? await store.save(origin: other, username: "local-only", password: "localhost-secret")
            await open("/login", on: other)
            check("11. localhost gets localhost's sign-in", await waitFor { await value("#username") == "local-only" }, await value("#username"))
            await open("/login")
            check("11. 127.0.0.1 gets its own, never localhost's", await waitFor { await fields(["#username": "ada", "#password": "correct-horse"]) }, await value("#username"))
            let before = coordinator.trace.count
            await open("/frames")
            await pause(1)
            let sameFrame = await js("return document.getElementById('same').contentDocument.getElementById('password').value") as? String
            check("11. a sign-in form in a frame is not filled unasked", sameFrame == "", sameFrame)
            let sinceFrames = coordinator.trace.dropFirst(before)
            check("11. both frames reported their forms", sinceFrames.filter { $0.hasPrefix("forms frame login=1") }.count == 2, Array(sinceFrames))
            check("11. nothing was filled anywhere on that page", !sinceFrames.contains { $0.hasPrefix("autofill") || $0.hasPrefix("fill") }, Array(sinceFrames))

            // MARK: 12. Username on one page, password on the next

            try? await store.deleteAll()
            app.passwords.changed()
            await open("/two-step")
            await type("#username", "ada")
            await click("#submit")
            _ = await waitFor { (await js("return !!document.getElementById('password')") as? Bool) == true }
            await type("#password", "correct-horse")
            await click("#submit")
            check("12. a two-page sign-in is offered", await promptAppears(), coordinator.trace.suffix(8))
            check("12. …with the username from the first page", coordinator.promptController?.usernameField.stringValue == "ada", coordinator.promptController?.usernameField.stringValue)
            _ = press("Save")
            check("12. …and saved under it", await waitFor { await saved() == ["\(site) ada": "correct-horse"] }, await saved())

            // MARK: 13. Automatic filling switched off

            BrowserSettings.autofillPasswords = false
            await open("/login")
            check("13. with filling off, the page loads empty", await fields(["#username": "", "#password": ""]))
            browser.showSitePasswords(nil)
            check("13. the key button lists this site's accounts", await waitFor { coordinator.accountsController?.fillButtons.count == 1 })
            await pause(0.4)
            snapshot(coordinator.accountsController?.view.window, "13-key-button-accounts")
            check("13. Fill is enabled because the page has a sign-in form", coordinator.accountsController?.fillButtons.first?.isEnabled == true)
            coordinator.accountsController?.fillButtons.first?.performClick(nil)
            check("13. Fill fills", await waitFor { await fields(["#username": "ada", "#password": "correct-horse"]) }, await value("#username"))
            BrowserSettings.autofillPasswords = true

            // MARK: 14. Saving switched off

            try? await store.deleteAll()
            app.passwords.changed()
            BrowserSettings.offerToSavePasswords = false
            await open("/login")
            await signIn("ada", "correct-horse")
            _ = await waitFor { await path() == "/welcome" }
            check("14. with offering off, nothing is asked", await noPrompt(), coordinator.trace.suffix(6))
            BrowserSettings.offerToSavePasswords = true

            // MARK: 15. Settings → Passwords

            _ = try? await store.save(origin: site, username: "ada", password: "correct-horse")
            _ = try? await store.save(origin: "https://example.com", username: "ada@example.com", password: "example-secret")
            _ = try? await store.save(origin: "http://plain.example", username: "", password: "no-name")
            let appMenu = NSApp.mainMenu?.items.first?.submenu
            if let index = appMenu?.items.firstIndex(where: { $0.title == "Passwords…" }) {
                appMenu?.performActionForItem(at: index)
            } else { check("15. the app menu has Passwords…", false, appMenu?.items.map(\.title)) }
            let pane = app.settingsWindow.passwordsPane
            check("15. Passwords… opens Settings on the Passwords pane", await waitFor { app.settingsWindow.window?.isVisible == true && app.settingsWindow.selectedPane == .passwords })
            check("15. the window is still called Settings", app.settingsWindow.window?.title == "Settings", app.settingsWindow.window?.title)
            check("15. every saved sign-in is listed, by site", await waitFor { pane.visible.map(\.site) == ["127.0.0.1:8766", "example.com", "plain.example"] }, pane.visible.map(\.site))
            check("15. the count is shown", pane.countLabel.stringValue == "3 passwords", pane.countLabel.stringValue)
            @MainActor func cell(_ row: Int, _ column: Int) -> String {
                (pane.tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? "<none>"
            }
            check("15. passwords are dots until asked for", (0..<3).allSatisfy { cell($0, 2) == "••••••••" })
            check("15. a plain-http site is marked", cell(2, 0) == "plain.example  (not encrypted)", cell(2, 0))
            check("15. a sign-in without a username says so", cell(2, 1) == "No username", cell(2, 1))

            pane.searchField.stringValue = "example.com"
            pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: pane.searchField))
            check("15. search narrows by site or username", pane.visible.map(\.username) == ["ada@example.com"] && pane.countLabel.stringValue == "1 of 3", pane.countLabel.stringValue)
            pane.searchField.stringValue = ""
            pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: pane.searchField))

            pane.tableView.selectRowIndexes([1], byExtendingSelection: false)
            authenticator.answer = false
            authenticator.asked = []
            await pane.toggleShowSelection()
            check("15. Show asks who is asking", authenticator.asked == ["show saved passwords"], authenticator.asked)
            check("15. refused: the password stays hidden", cell(1, 2) == "••••••••" && pane.revealed.isEmpty)
            authenticator.answer = true
            await pane.toggleShowSelection()
            check("15. confirmed: the password is shown", cell(1, 2) == "example-secret", cell(1, 2))
            check("15. the button now offers Hide", pane.showButton.title == "Hide")
            snapshot(app.settingsWindow.window, "15-settings-passwords")
            await pane.toggleShowSelection()
            check("15. Hide hides it again", cell(1, 2) == "••••••••")

            // Add, through the sheet.
            pane.addButton.performClick(nil)
            check("15. Add… opens the editor", await waitFor { pane.editor != nil })
            if let editor = pane.editor {
                check("15. Save is disabled until there is a site and a password", !editor.saveButton.isEnabled)
                await pause(0.5)
                snapshot(editor.view.window, "15-add-sheet")
                editor.siteField.stringValue = "news.example/login?next=/"
                editor.usernameField.stringValue = "reader"
                editor.passwordField.stringValue = "typed-by-hand"
                editor.validate()
                check("15. …and enabled once there is", editor.saveButton.isEnabled)
                editor.saveButton.performClick(nil)
                check("15. the added sign-in is stored by origin, https assumed", await waitFor { await saved()["https://news.example reader"] == "typed-by-hand" }, await saved().keys.sorted())
                check("15. …and appears in the list", await waitFor { pane.visible.count == 4 })
            }

            // Delete, through its confirmation sheet.
            if let row = pane.visible.firstIndex(where: { $0.site == "news.example" }) {
                pane.tableView.selectRowIndexes([row], byExtendingSelection: false)
                pane.deleteButton.performClick(nil)
                let sheetAppeared = await waitFor { app.settingsWindow.window?.attachedSheet != nil }
                check("15. Delete asks first", sheetAppeared)
                check("15. …and has not deleted anything yet", await saved().count == 4)
                if let sheet = app.settingsWindow.window?.attachedSheet, let root = sheet.contentView {
                    var buttons: [NSButton] = []
                    @MainActor func walk(_ view: NSView) { if let b = view as? NSButton { buttons.append(b) }; view.subviews.forEach(walk) }
                    walk(root)
                    buttons.first { $0.title == "Delete" }?.performClick(nil)
                }
                check("15. confirming deletes it", await waitFor { await saved()["https://news.example reader"] == nil && pane.visible.count == 3 }, await saved().keys.sorted())
            }

            // MARK: 16. Import and export

            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBrowser-passwords-selftest-files-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let chromeCSV = scratch.appendingPathComponent("Chrome Passwords.csv")
            try? Data("name,url,username,password,note\r\nexample.com,https://example.com/login,ada@example.com,example-secret,\r\nshop,https://shop.example/account,ada,\"comma, \"\"quote\"\" and\nnewline\",\r\nexample.com,https://example.com/,second@example.com,changed-elsewhere,\r\napp,android://hash@com.example/,x,y,\r\n".utf8).write(to: chromeCSV)
            await pane.importCSV(from: chromeCSV)
            check("16. importing a Chrome CSV reports what happened", pane.lastImportMessage.contains("2 added, 0 updated, 1 already saved") && pane.lastImportMessage.contains("1 skipped"), pane.lastImportMessage)
            check("16. …keeps awkward characters intact", await saved()["https://shop.example ada"] == "comma, \"quote\" and\nnewline")
            check("16. …and warns that the CSV is still in the clear", pane.lastImportMessage.contains("Delete it when you are done"))
            if let sheet = app.settingsWindow.window?.attachedSheet { app.settingsWindow.window?.endSheet(sheet) }

            let exported = scratch.appendingPathComponent("export.csv")
            authenticator.answer = false
            let refused = try? await app.passwords.exportCSV(to: exported)
            check("16. export refused without confirmation writes no file", refused == nil && !FileManager.default.fileExists(atPath: exported.path))
            authenticator.answer = true
            let count = try? await app.passwords.exportCSV(to: exported)
            check("16. export writes every sign-in", count == 5, count as Any)
            let permissions = (try? FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions] as? NSNumber)?.intValue
            check("16. the export is readable by its owner only", permissions == 0o600, permissions.map { String($0, radix: 8) } as Any)
            if let text = try? String(contentsOf: exported, encoding: .utf8), let parsed = try? PasswordCSV.parse(text) {
                var roundTrip: [String: String] = [:]
                for row in parsed.rows { roundTrip[row.origin + " " + row.username] = row.password }
                let inVault = await saved()
                check("16. the export reads back as exactly what is saved", roundTrip == inVault, roundTrip.keys.sorted())
            } else { check("16. the export parses", false) }

            // MARK: 17. What is on disk

            let vaults = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("SimpleBrowser-passwords-selftest-") && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Passwords.sbvault").path) } ?? []
            if let vault = vaults.max(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }),
               let raw = try? Data(contentsOf: vault.appendingPathComponent("Passwords.sbvault")) {
                for needle in ["correct-horse", "example-secret", "ada", "example.com", "127.0.0.1"] {
                    check("17. the vault file does not contain “\(needle)”", raw.range(of: Data(needle.utf8)) == nil)
                }
                try? FileManager.default.removeItem(at: vault)
            } else { check("17. the scratch vault was found on disk", false) }
            let realVault = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SimpleBrowser/Profiles/\(browser.profile.id)/Passwords.sbvault")
            report["realVaultExists"] = FileManager.default.fileExists(atPath: realVault.path)

            UserDefaults.standard.removePersistentDomain(forName: suite)
            report["passed"] = failures.isEmpty && environment.isEmpty
            report["checksPassed"] = passed
            report["failures"] = failures
            report["environment"] = environment
            report["trace"] = Array(coordinator.trace.suffix(120))
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }
}
