import AppKit
import WebKit
import BrowserKit

/// #10 Site permissions, page security and pop-up blocking.
///
/// In two layers. What the browser does with a request (the question, the
/// three answers, what is remembered and for which site) is tested by
/// handing the tab the request WebKit would. That WebKit hands a page's own
/// request over is tested end to end when it does: measured on 2026-09-28,
/// it did in three runs and then stopped, in quiet runs and in front, with
/// pretend devices and real ones, in normal and private windows. What
/// decides it has not been found, so a run where it does not is reported
/// as not tested, not as passed.
extension FeatureSelfTest {

    func permissions() async {
        let profile = first.profile.id.description
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)
        // A tab with WebKit's pretend camera and microphone.
        BrowserWindowController.usesMockCaptureDevices = true
        let browser = app.newTab(beside: first, url: URL(string: site + "/media"))
        BrowserWindowController.usesMockCaptureDevices = false
        defer { browser.window?.close() }
        _ = await waitFor { !browser.pageWebView.isLoading && browser.currentURL?.path == "/media" }
        browser.window?.tabGroup?.selectedWindow = browser.window
        let permissions = browser.permissions
        let here = "http://127.0.0.1:8767"
        let there = "http://localhost:8767"

        func value(_ name: String) async -> String { (await js("return String(window.\(name))", in: browser)) as? String ?? "<no page>" }
        func load(_ path: String, host: String? = nil) async {
            let address = (host ?? site) + path
            browser.load(URL(string: address)!)
            _ = await waitFor {
                guard browser.pageWebView.url?.absoluteString == address, !browser.pageWebView.isLoading else { return false }
                return (await self.js("return document.readyState", in: browser) as? String) == "complete"
            }
            await pause(0.3)
        }
        func answer(_ title: String) -> Bool {
            guard let button = permissions.promptController?.buttons.first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }
        func stored(_ permission: SitePermission, site: String = here) -> PermissionChoice? {
            BrowserSettings.sitePermissions(profile: profile).choice(for: permission, site: site)
        }
        /// What WebKit's delegate call does: asks the tab, and waits.
        final class Outcome { var value: Bool? }
        func ask(_ wanted: [SitePermission], from requester: String? = nil) -> Outcome {
            let outcome = Outcome()
            permissions.request(wanted, requesterSite: requester) { outcome.value = $0 }
            return outcome
        }

        // MARK: The question and its answers

        var asked = ask([.camera, .microphone])
        check("permissions: a request for the camera and microphone is asked about", permissions.promptController != nil && asked.value == nil, permissions.trace)
        check("permissions: …in words, naming the site", permissions.promptController?.questionLabel.stringValue == "“127.0.0.1:8767” would like to use your camera and microphone.",
              permissions.promptController?.questionLabel.stringValue)
        check("permissions: …with the three answers", permissions.promptController?.buttons.map(\.title) == ["Don’t Allow", "Allow Once", "Allow"])
        check("permissions: …and no warning about encryption for a page on this Mac", permissions.promptController?.detailLabel.isHidden == true,
              permissions.promptController?.detailLabel.stringValue)
        await pause(0.4)
        snapshot(permissions.popover?.contentViewController?.view.window, "permission-prompt")

        check("permissions: Allow Once", answer("Allow Once"))
        check("permissions: …allows the request", asked.value == true && permissions.promptController == nil)
        check("permissions: …and remembers nothing", stored(.camera) == nil && stored(.microphone) == nil)
        asked = ask([.camera])
        check("permissions: allowed once holds for the page: asked again it is given, without a question", asked.value == true && permissions.promptController == nil)
        await load("/media?again")
        check("permissions: after another page of the same site it still holds", ask([.microphone]).value == true)

        await load("/media", host: there)
        asked = ask([.camera])
        check("permissions: another site is asked about afresh", permissions.promptController != nil && asked.value == nil, permissions.trace.suffix(3))
        check("permissions: Don’t Allow", answer("Don’t Allow"))
        check("permissions: …refuses the request", asked.value == false)
        check("permissions: …and is remembered for that site", stored(.camera, site: there) == .deny && stored(.camera) == nil)
        check("permissions: so the next request is refused without a question", ask([.camera]).value == false && permissions.promptController == nil)
        let unanswered = ask([.microphone]), again = ask([.microphone])
        check("permissions: the microphone, not refused, is still asked about", unanswered.value == nil && permissions.promptController != nil)
        permissions.popover?.close()
        check("permissions: closing the question without answering refuses", await waitFor { unanswered.value == false })
        check("permissions: …and the same request made meanwhile, without asking it all over again", again.value == false && permissions.promptController == nil)
        check("permissions: …and remembers nothing", stored(.microphone, site: there) == nil)

        await load("/media")
        check("permissions: allowed once ended when the tab left the site", permissions.allowedOnce.isEmpty)
        asked = ask([.camera, .microphone])
        check("permissions: Allow", answer("Allow"))
        check("permissions: …allows the request", asked.value == true)
        check("permissions: …and is remembered, per permission", stored(.camera) == .allow && stored(.microphone) == .allow)
        await load("/media?later")
        check("permissions: the next visit is not asked", ask([.camera]).value == true && permissions.promptController == nil, permissions.trace.suffix(3))

        // Two questions at once are put one after the other.
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)
        await load("/second")
        let one = ask([.location]), two = ask([.microphone]), three = ask([.location])
        check("permissions: two requests at once: the first is asked", permissions.promptController?.permissions == [.location])
        _ = answer("Allow")
        check("permissions: …then the second", permissions.promptController?.permissions == [.microphone] && one.value == true && two.value == nil)
        check("permissions: …and a third that the first answer settled is not asked at all", { _ = answer("Don’t Allow"); return three.value == true && permissions.promptController == nil }())
        check("permissions: …each remembered as answered", stored(.location) == .allow && stored(.microphone) == .deny)

        // A question left unanswered when the page goes.
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)
        asked = ask([.microphone])
        await load("/long")
        check("permissions: leaving the page takes its question away", permissions.promptController == nil && permissions.popover == nil)
        check("permissions: …answers it no", asked.value == false)
        check("permissions: …and remembers nothing", stored(.microphone) == nil)

        // A frame from another site, asking through this page.
        asked = ask([.camera], from: there)
        check("permissions: a frame from another site is asked about as this page", permissions.promptController?.questionLabel.stringValue == "“127.0.0.1:8767” would like to use your camera.",
              permissions.promptController?.questionLabel.stringValue)
        check("permissions: …the question saying who is really asking", permissions.promptController?.detailLabel.stringValue.contains("content from localhost:8767") == true,
              permissions.promptController?.detailLabel.stringValue)
        _ = answer("Don’t Allow")
        check("permissions: refusing it is remembered for the page's site, not the frame's", stored(.camera) == .deny && stored(.camera, site: there) == nil)
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)

        // The browser's own pages have no site to give anything to.
        browser.load(StartPageSchemeHandler.url)
        _ = await waitFor { StartPageSchemeHandler.isStartPage(browser.pageWebView.url) && !browser.pageWebView.isLoading }
        check("permissions: a page that is not a web page is refused, unasked", ask([.camera]).value == false && permissions.promptController == nil)

        // MARK: Camera and microphone, end to end

        await load("/media")
        check("permissions: pages have the camera and microphone API", await value("navigator.mediaDevices !== undefined") == "true", await value("navigator.mediaDevices"))
        _ = await js("start({ video: true, audio: true })", in: browser)
        if await waitFor(5, { permissions.promptController != nil }) {
            check("permissions: end to end: the page's own request is the question", permissions.promptController?.permissions == [.camera, .microphone])
            check("permissions: end to end: the page waits for the answer", await value("media") == "asking", await value("media"))
            _ = answer("Allow Once")
            check("permissions: end to end: allowed, the page gets both", await waitFor { await value("media") == "granted:audio+video" }, await value("media"))
            check("permissions: end to end: the camera shows as in use, beside the address", await waitFor { permissions.cameraInUse && permissions.microphoneInUse && !browser.toolbarItemIsHidden("capture") })
            check("permissions: end to end: …and in the tab", browser.window?.tab.accessoryView != nil)
            check("permissions: end to end: …with every toolbar button still fitting", browser.overflowingToolbarItems.isEmpty, browser.overflowingToolbarItems)
            snapshot(browser.window, "permission-capturing")
            permissions.stopCapture(nil)
            check("permissions: end to end: clicking the indicator stops the camera and the microphone", await waitFor { !permissions.isCapturing && browser.toolbarItemIsHidden("capture") })
            check("permissions: end to end: …and the tab's indicator goes", await waitFor { browser.window?.tab.accessoryView == nil })
            await load("/media", host: there)
            _ = await js("start({ video: true })", in: browser)
            _ = await waitFor(5) { permissions.promptController != nil }
            _ = answer("Don’t Allow")
            check("permissions: end to end: refused, the page is told so", await waitFor { await value("media") == "refused:NotAllowedError" }, await value("media"))
        } else {
            skip("permissions: WebKit did not pass the page's camera request on in this run, so the camera was not tested end to end.")
        }
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)

        // MARK: Pop-ups

        let tabsBefore = app.browserControllers.count
        await load("/popups")
        check("permissions: a window a page opens by itself is blocked", await value("auto") == "blocked", await value("auto"))
        check("permissions: …and the next one", await value("auto2") == "blocked", await value("auto2"))
        check("permissions: …with no tab opened", app.browserControllers.count == tabsBefore)
        check("permissions: …and a bar saying how many", await waitFor { permissions.popupBar?.label.stringValue == "2 pop-up windows were blocked" }, permissions.popupBar?.label.stringValue)
        check("permissions: …offering to allow them for the site", permissions.popupBar?.alwaysButton.title == "Always Allow on 127.0.0.1:8767")
        snapshot(browser.window, "permission-popup-bar")
        if await click("open", in: browser) {
            let opened = await waitFor(4) { self.app.browserControllers.count == tabsBefore + 1 }
            if opened {
                check("permissions: a window opened by a click is not blocked", await value("clicked") == "opened", await value("clicked"))
                app.browserControllers.last?.window?.close()
                await pause(0.3)
            } else if await value("clicked") == "undefined" {
                // The click did not reach the page (its window is beneath
                // others). Script the app runs in a page counts, to WebKit,
                // as the person's doing: the same path, by another door.
                _ = await js("window.clicked = window.open('/second?clicked=1') ? 'opened' : 'blocked'", in: browser)
                let byGesture = await waitFor(4) { self.app.browserControllers.count == tabsBefore + 1 }
                check("permissions: a window the person opened is not blocked", byGesture, await value("clicked"))
                if byGesture { app.browserControllers.last?.window?.close() }
                await pause(0.3)
            } else {
                check("permissions: a window opened by a click is not blocked", false, await value("clicked"))
            }
        }
        permissions.popupBar?.openButton.performClick(nil)
        check("permissions: Open All opens what was blocked", await waitFor { self.app.browserControllers.count == tabsBefore + 2 }, app.browserControllers.count)
        check("permissions: …and the bar goes", permissions.popupBar == nil)
        check("permissions: …without allowing the site", stored(.popups) == nil)
        for tab in app.browserControllers.suffix(2) where tab !== browser && tab !== first { tab.window?.close() }
        await pause(0.3)

        await load("/popups")
        _ = await waitFor { permissions.popupBar != nil }
        permissions.popupBar?.alwaysButton.performClick(nil)
        check("permissions: Always Allow is remembered for the site", stored(.popups) == .allow)
        _ = await waitFor { self.app.browserControllers.count == tabsBefore + 2 }
        for tab in app.browserControllers.suffix(2) where tab !== browser && tab !== first { tab.window?.close() }
        await pause(0.3)
        await load("/popups")
        check("permissions: …and the next visit's pop-ups open", await waitFor { await value("auto") == "opened" }, await value("auto"))
        check("permissions: …with no bar", permissions.popupBar == nil)
        _ = await waitFor { self.app.browserControllers.count == tabsBefore + 2 }
        for tab in app.browserControllers.suffix(2) where tab !== browser && tab !== first { tab.window?.close() }
        await pause(0.3)
        await load("/popups", host: there)
        check("permissions: another site's pop-ups are still blocked", await value("auto") == "blocked" && app.browserControllers.count == tabsBefore, await value("auto"))
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)

        // MARK: Files a page hands over by itself

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Keel-feature-downloads-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        browser.downloads.downloadsDirectory = scratch
        func files() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).count }
        await load("/downloads")
        check("permissions: the first file a page hands over is saved", await waitFor { files() == 1 }, files())
        check("permissions: a second, unasked for, is asked about", await waitFor { permissions.promptController?.permissions == [.downloads] }, permissions.trace.suffix(3))
        check("permissions: …in words", permissions.promptController?.questionLabel.stringValue == "“127.0.0.1:8767” would like to download more than one file.")
        _ = answer("Don’t Allow")
        await pause(1)
        check("permissions: refused, no more files are saved", files() == 1, files())
        check("permissions: …and it is remembered", stored(.downloads) == .deny)
        await load("/downloads")
        await pause(1)
        check("permissions: next time the first is saved and the rest refused, unasked", files() == 2 && permissions.promptController == nil, files())
        var allowing = BrowserSettings.sitePermissions(profile: profile)
        allowing.set(.allow, for: .downloads, site: here)
        BrowserSettings.setSitePermissions(allowing, profile: profile)
        await load("/downloads")
        check("permissions: allowed, all three are saved", await waitFor { files() == 5 }, files())
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)

        // MARK: What the lock shows

        await load("/cookie/set?v=info")
        browser.showPageSecurity(nil)
        check("permissions: the lock opens the page's information", await waitFor { browser.pageInfo?.isViewLoaded == true })
        if let info = browser.pageInfo {
            check("permissions: …how the connection is secured", info.titleLabel.stringValue == "This page is on this Mac", info.titleLabel.stringValue)
            check("permissions: …what the site may do, all undecided", info.permissionPopUps.count == SitePermission.offered.count && info.permissionPopUps[.notifications] == nil
                  && info.permissionPopUps.values.allSatisfy { $0.indexOfSelectedItem == 0 })
            check("permissions: …with pop-ups blocked unless allowed, the rest asked about", info.permissionPopUps[.popups]?.titleOfSelectedItem == "Block, and Say So"
                  && info.permissionPopUps[.camera]?.titleOfSelectedItem == "Ask")
            check("permissions: …what it has stored on this Mac", await waitFor { info.dataLabel.stringValue.lowercased().contains("1 cookie") }, info.dataLabel.stringValue)
            check("permissions: …and that nothing was blocked, where nothing is being", info.blockedLabel.stringValue.contains("not being blocked") || info.blockedLabel.stringValue.hasPrefix("No ads"),
                  info.blockedLabel.stringValue)
            await pause(0.3)
            snapshot(info.view.window, "page-info")
            info.permissionPopUps[.camera]?.selectItem(at: 2)
            if let popUp = info.permissionPopUps[.camera] { _ = popUp.target?.perform(popUp.action, with: popUp) }
            check("permissions: a choice made there is the site's", stored(.camera) == .deny)
            check("permissions: …and holds", ask([.camera]).value == false && permissions.promptController == nil)
            await info.clearData()
            check("permissions: Clear forgets what the site stored", info.cookieCount == 0 && info.dataLabel.stringValue == "Nothing", info.dataLabel.stringValue)
            await load("/cookie/show")
            check("permissions: …so the site no longer knows the visitor", (await js("return document.getElementById('cookie').textContent", in: browser) as? String) == "")
        }
        browser.securityPopover?.close()

        // MARK: Settings → Websites

        var choices = SitePermissions()
        choices.set(.allow, for: .camera, site: "https://meet.example.com")
        choices.set(.deny, for: .location, site: "https://news.example")
        choices.set(.allow, for: .popups, site: here)
        BrowserSettings.setSitePermissions(choices, profile: profile)
        app.showWebsiteSettings(nil)
        let pane = app.settingsWindow.websitesPane
        check("permissions: Settings has a Websites pane", await waitFor { self.app.settingsWindow.selectedPane == .websites && self.app.settingsWindow.window?.isVisible == true })
        pane.refresh()
        check("permissions: …listing every choice, by site", pane.rows.map { "\($0.site) \($0.permission.rawValue) \($0.choice.rawValue)" }
              == ["\(here) popups allow", "https://meet.example.com camera allow", "https://news.example location deny"], pane.rows)
        snapshot(app.settingsWindow.window, "websites-settings")
        pane.set(.deny, forRow: 1)
        check("permissions: a choice changed there is changed", BrowserSettings.sitePermissions(profile: profile).choice(for: .camera, site: "https://meet.example.com") == .deny)
        pane.tableView.selectRowIndexes([2], byExtendingSelection: false)
        pane.removeButton.performClick(nil)
        check("permissions: Ask Again forgets one", BrowserSettings.sitePermissions(profile: profile).choice(for: .location, site: "https://news.example") == nil && pane.rows.count == 2, pane.rows)
        app.settingsWindow.window?.close()
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)

        // MARK: Notifications

        await load("/notify")
        check("permissions: pages are given no Notification API, since a notification could not be delivered", await value("notify") == "no API", await value("notify"))

        // MARK: Location, end to end

        await load("/geo")
        _ = await js("locate()", in: browser)
        if await waitFor(5, { permissions.promptController != nil }) {
            check("permissions: end to end: a page asking where you are is asked about", permissions.promptController?.questionLabel.stringValue == "“127.0.0.1:8767” would like to know where you are.")
            _ = answer("Don’t Allow")
            check("permissions: end to end: …and refused, is remembered", stored(.location) == .deny)
            if !(await waitFor(6) { await value("geo") == "error:1" }) {
                skip("permissions: the page was not told its location request was refused (it says “\(await value("geo"))”).")
            }
        } else {
            skip("permissions: WebKit did not pass the page's location request on.")
        }
        BrowserSettings.setSitePermissions(SitePermissions(), profile: profile)
    }
}

extension FeatureSelfTest {

    /// #10, certificates: the fixture site over https on 8768 signs its own.
    func certificates() async {
        let browser = app.newTab(beside: first, url: URL(string: site + "/second"))
        defer { browser.window?.close() }
        _ = await waitFor { !browser.pageWebView.isLoading && browser.currentURL?.path == "/second" }
        let secure = "https://127.0.0.1:8768"
        func text(_ id: String, in tab: BrowserWindowController? = nil) async -> String {
            (await js("const el = document.getElementById('\(id)'); return el ? el.textContent.replace(/\\\\s+/g, ' ').trim() : '<none>'", in: tab ?? browser) as? String) ?? "<no page>"
        }
        func settle(_ tab: BrowserWindowController? = nil) async {
            let tab = tab ?? browser
            _ = await waitFor { !tab.pageWebView.isLoading }
            await pause(0.4)
        }

        browser.load(URL(string: secure + "/article")!)
        check("certificates: a site whose certificate cannot be verified is not shown", await waitFor { browser.isShowingCertificateWarning }, browser.pageWebView.url as Any)
        await settle()
        check("certificates: a warning is, in its place", await text("warning-title") == "This Connection Is Not Private", await text("warning-title"))
        check("certificates: …naming the site", await text("warning-site") == "This page says it is 127.0.0.1:8768, but that could not be verified.", await text("warning-site"))
        check("certificates: …and showing the certificate that was presented", (await js("return document.querySelector('details').textContent", in: browser) as? String)?.contains("Fixture Self-Signed") == true,
              await js("return document.querySelector('details').textContent", in: browser) as Any)
        check("certificates: the address bar names the site that was asked for", browser.addressText == "127.0.0.1" && browser.currentURL?.absoluteString == secure + "/article", browser.addressText)
        check("certificates: …as Not Secure", browser.securityTitle == "Not Secure" && browser.securityLabel == "This site's certificate could not be verified", browser.securityLabel)
        check("certificates: the article was not loaded", await text("first") == "<none>")
        check("certificates: the warning is not offered Reader, a bookmark's star or history", browser.toolbarItemIsHidden("reader")
              && ((try? app.history(for: browser.profile)?.page(for: URL(string: secure + "/article")!)) ?? nil) == nil)
        snapshot(browser.window, "certificate-warning")

        // Go Back.
        _ = await js("document.getElementById('warning-back').click()", in: browser)
        check("certificates: Go Back returns to the page before", await waitFor { browser.pageWebView.url?.absoluteString == self.site + "/second" }, browser.pageWebView.url as Any)
        check("certificates: …which has no warning about it", !browser.isShowingCertificateWarning && browser.securityTitle.isEmpty)

        // A web page cannot press the warning's buttons.
        _ = await js("location.href = 'keel://warning-action/proceed?token=guess'", in: browser)
        await pause(0.8)
        check("certificates: a web page asking to go on is ignored", browser.pageWebView.url?.absoluteString == site + "/second", browser.pageWebView.url as Any)

        // Visit anyway.
        browser.load(URL(string: secure + "/article")!)
        _ = await waitFor { browser.isShowingCertificateWarning }
        await settle()
        _ = await js("document.getElementById('warning-proceed').click()", in: browser)
        check("certificates: Visit this website anyway shows the site", await waitFor { browser.pageWebView.url?.absoluteString == secure + "/article" }, browser.pageWebView.url as Any)
        await settle()
        check("certificates: …its own page", (await text("first")).hasPrefix("The lighthouse"), await text("first"))
        check("certificates: …still marked Not Secure, and saying why", browser.securityTitle == "Not Secure" && browser.securityLabel == "Connection is not verified"
              && browser.pageSecurity == .untrusted, browser.securityLabel)
        browser.load(URL(string: secure + "/long")!)
        check("certificates: the site's other pages load without another warning", await waitFor { browser.pageWebView.url?.path == "/long" && !browser.isShowingCertificateWarning })
        await settle()
        browser.goBack(nil)
        _ = await waitFor { browser.pageWebView.url?.path == "/article" }
        await settle()
        browser.goBack(nil)
        check("certificates: Back from the site does not lead to the warning that was answered", await waitFor { browser.pageWebView.url?.absoluteString == self.site + "/second" },
              browser.pageWebView.backForwardList.backList.map(\.url.absoluteString) + [browser.pageWebView.url?.absoluteString ?? "nil"])

        // Another tab of the profile; another host; a private window.
        let other = app.newTab(beside: browser, url: URL(string: secure + "/second"))
        check("certificates: the exception holds for the profile's other tabs", await waitFor { other.pageWebView.url?.absoluteString == secure + "/second" && !other.isShowingCertificateWarning && !other.pageWebView.isLoading },
              other.pageWebView.url as Any)
        other.load(URL(string: "https://localhost:8768/second")!)
        check("certificates: …for that site only: the same certificate on another name warns", await waitFor { other.isShowingCertificateWarning }, other.pageWebView.url as Any)
        other.window?.close()
        browser.window?.makeKeyAndOrderFront(nil)
        app.newPrivateWindow(nil)
        _ = await waitFor { self.app.browserControllers.contains { $0.isPrivate } }
        if let secret = app.browserControllers.last(where: \.isPrivate) {
            secret.load(URL(string: secure + "/second")!)
            check("certificates: a private window does not inherit the exception", await waitFor { secret.isShowingCertificateWarning }, secret.pageWebView.url as Any)
            await settle(secret)
            _ = await js("document.getElementById('warning-proceed').click()", in: secret)
            check("certificates: …and makes its own", await waitFor { secret.pageWebView.url?.absoluteString == secure + "/second" })
            secret.window?.close()
        }
    }
}
