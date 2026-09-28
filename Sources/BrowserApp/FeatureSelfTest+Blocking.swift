import AppKit
import WebKit
import BlockKit

/// #8 Content blocking. The filter lists are the fixture site's own: a test
/// run never asks EasyList's servers for anything.
extension FeatureSelfTest {

    func blocking() async {
        let browser = first
        let blocker = app.blocker
        let profile = browser.profile.id.description
        browser.window?.makeKeyAndOrderFront(nil)
        _ = await js("await fetch('\(site)/filters/reset')", in: browser)

        func loaded() async -> [String] { (await js("return window.loaded", in: browser) as? [String]) ?? ["<no page>"] }
        func shown(_ id: String) async -> Bool {
            (await js("return getComputedStyle(document.getElementById('\(id)')).display !== 'none'", in: browser) as? Bool) ?? false
        }
        func imageLoaded(_ id: String) async -> Bool {
            (await js("return document.getElementById('\(id)').naturalWidth > 0", in: browser) as? Bool) ?? false
        }
        func requests() async -> [String: [[String: Any]]] {
            (await js("return await (await fetch('\(site)/filters/requests')).json()", in: browser) as? [String: [[String: Any]]]) ?? [:]
        }

        // Before there are any lists.
        check("blocking: a test run starts with no filter lists", blocker.sources.isEmpty && !blocker.isReady)
        await open("/blocking", in: browser)
        check("blocking: without lists everything loads", await loaded() == ["banner", "allowed", "tracker", "app"], await loaded())
        check("blocking: the shield says the lists are not there yet", browser.blocking.summary == "The filter lists have not been downloaded yet", browser.blocking.summary)

        // Download and compile.
        blocker.sources = [
            FilterList(id: "ads", name: "Test Ads", about: "Ads", url: URL(string: site + "/filters/ads.txt")!, onByDefault: true),
            FilterList(id: "privacy", name: "Test Privacy", about: "Trackers", url: URL(string: site + "/filters/privacy.txt")!, onByDefault: true),
        ]
        let firstUpdate = await blocker.update()
        check("blocking: both lists are downloaded", firstUpdate.downloaded == ["ads", "privacy"] && firstUpdate.failed.isEmpty, firstUpdate)
        check("blocking: …and compiled", firstUpdate.compiled && blocker.isReady && firstUpdate.lists >= 1, firstUpdate)
        check("blocking: the one selector WebKit's CSS parser refuses is left out", blocker.state.refusedSelectors == 1 && firstUpdate.rejected == 0, blocker.state.refusedSelectors as Any)
        check("blocking: filters WebKit cannot express are counted, not guessed at", blocker.state.skipped == 3, blocker.state.skipped)
        check("blocking: the download sent no cookies", await requests().values.allSatisfy { $0.allSatisfy { $0["cookie"] is NSNull || $0["cookie"] == nil } }, await requests())

        // The page again.
        await open("/blocking", in: browser)
        check("blocking: the ad and the tracker are not loaded; the exception and the site's own script are", await loaded() == ["allowed", "app"], await loaded())
        check("blocking: the tracking pixel is not loaded", !(await imageLoaded("pixel")))
        check("blocking: …the photo is", await imageLoaded("photo"))
        check("blocking: an ad's element is hidden", !(await shown("hidden-ad")))
        check("blocking: the refused selector hides nothing, and takes no other selector with it", await shown("sponsored"))
        check("blocking: a selector for this site hides here", !(await shown("promo")))
        check("blocking: a selector for another site does not", await shown("elsewhere"))
        check("blocking: the article is untouched", await shown("content"))
        check("blocking: the shield counts what was blocked", await waitFor { browser.blocking.blockedCount == 4 }, "\(browser.blocking.blockedCount) \(browser.blocking.blockedHosts)")
        check("blocking: …and shows the number", browser.blocking.button.title == "4" && browser.blocking.summary == "4 items blocked on this page", browser.blocking.button.title)
        check("blocking: …and where the requests were going", browser.blocking.blockedHosts == ["127.0.0.1": 2, "localhost": 2], browser.blocking.blockedHosts)
        let events = app.blockedRequestsRecorded(for: browser)
        check("blocking: DevTools' network log has them as blocked", events.count >= 4 && events.contains { $0.hasSuffix("/ads/banner.js") }, events)
        browser.blocking.showPopover(nil)
        check("blocking: the shield opens its popover", await waitFor { browser.blocking.popoverController?.titleLabel.stringValue == "4 items blocked on this page" })
        check("blocking: …with the switch on, named for the site", browser.blocking.popoverController?.siteSwitch.state == .on
              && browser.blocking.popoverController?.switchLabel.stringValue == "Block ads and trackers on 127.0.0.1")
        snapshot(browser.blocking.popover?.contentViewController?.view.window, "blocking-popover")
        snapshot(browser.window, "blocking-shield")
        browser.blocking.popover?.close()

        // Nothing changed on the server: nothing is downloaded or compiled.
        let second = await blocker.update()
        check("blocking: asked again, the server says not modified", second.notModified == ["ads", "privacy"] && second.downloaded.isEmpty, second)
        check("blocking: …and nothing is compiled again", second.reused && !second.compiled)
        check("blocking: …because the request named what it has", await requests()["ads"]?.last?["if-none-match"] as? String == "\"ads-0\"", await requests()["ads"] as Any)

        // Off for this site.
        browser.blocking.setOff(true)
        check("blocking: switched off for the site, the page reloads unblocked", await waitFor { await loaded() == ["banner", "allowed", "tracker", "app"] }, await loaded())
        check("blocking: …with its elements showing", await shown("hidden-ad"))
        check("blocking: …the site's own too", await shown("promo"))
        check("blocking: …and the shield says so", browser.blocking.summary == "Blocking is off for 127.0.0.1" && browser.blocking.button.title.isEmpty, browser.blocking.summary)
        check("blocking: the choice is remembered for the profile", BrowserSettings.blockingOffSites(profile: profile) == ["127.0.0.1"], BrowserSettings.blockingOffSites(profile: profile))
        let other = app.newTab(beside: browser, url: URL(string: site + "/blocking"))
        _ = await waitFor { !other.pageWebView.isLoading && other.currentURL?.path == "/blocking" }
        await pause(0.5)
        check("blocking: a new tab on the same site is unblocked too", (await js("return window.loaded", in: other) as? [String]) == ["banner", "allowed", "tracker", "app"])
        other.load(URL(string: "http://localhost:8767/blocking")!)
        _ = await waitFor { !other.pageWebView.isLoading && other.currentURL?.host() == "localhost" }
        await pause(0.5)
        // On localhost the "tracker" is the site's own, so it loads; the ad does not.
        check("blocking: …while another site in that tab is still blocked", (await js("return window.loaded", in: other) as? [String]) == ["allowed", "tracker", "app"],
              await js("return window.loaded", in: other) as Any)
        other.window?.close()

        // Settings → Privacy.
        app.showPrivacySettings(nil)
        let pane = app.settingsWindow.privacyPane
        check("blocking: Settings has a Privacy pane", await waitFor { self.app.settingsWindow.selectedPane == .privacy && self.app.settingsWindow.window?.isVisible == true })
        pane.refresh()
        check("blocking: …listing the filter lists, both on", pane.listCheckboxes.map(\.title) == ["Test Ads: ads", "Test Privacy: trackers"] && pane.listCheckboxes.allSatisfy { $0.state == .on },
              pane.listCheckboxes.map(\.title))
        check("blocking: …when they were updated and how many rules", pane.statusLabel.stringValue.hasPrefix("Updated ") && pane.statusLabel.stringValue.hasSuffix(" rules"), pane.statusLabel.stringValue)
        check("blocking: …and the sites blocking is off for", pane.shownSites == ["127.0.0.1"], pane.shownSites)
        snapshot(app.settingsWindow.window, "blocking-settings")
        pane.sitesTable.selectRowIndexes([0], byExtendingSelection: false)
        pane.removeButton.performClick(nil)
        check("blocking: removing a site there turns blocking back on for it", BrowserSettings.blockingOffSites(profile: profile).isEmpty)
        await open("/blocking", in: browser)
        check("blocking: …and the page is blocked again", await loaded() == ["allowed", "app"], await loaded())

        // One list off.
        pane.listCheckboxes.last?.performClick(nil)
        check("blocking: a list switched off is compiled out", await waitFor(10) { !blocker.isBusy && blocker.state.enabledLists == ["ads"] }, blocker.state.enabledLists)
        await open("/blocking", in: browser)
        check("blocking: …so its tracker loads, and the other list's ad still does not", await loaded() == ["allowed", "tracker", "app"], await loaded())
        pane.listCheckboxes.last?.performClick(nil)
        _ = await waitFor(10) { !blocker.isBusy && blocker.state.enabledLists == ["ads", "privacy"] }

        // The master switch.
        pane.blockingCheckbox.performClick(nil)
        await open("/blocking", in: browser)
        check("blocking: switched off altogether, nothing is blocked", await loaded() == ["banner", "allowed", "tracker", "app"], await loaded())
        check("blocking: …or hidden", await shown("hidden-ad"))
        check("blocking: …and the shield says so", browser.blocking.summary == "Content blocking is off", browser.blocking.summary)
        pane.blockingCheckbox.performClick(nil)
        _ = await waitFor(10) { !blocker.isBusy && blocker.isReady }
        await open("/blocking", in: browser)
        check("blocking: switched on again, it blocks again", await loaded() == ["allowed", "app"], await loaded())
        app.settingsWindow.window?.close()

        // A newer list.
        let before = blocker.state.identifiers
        _ = await js("await fetch('/filters/bump')", in: browser)
        let third = await blocker.update()
        check("blocking: a list that changed is downloaded, the other is not", third.downloaded == ["ads"] && third.notModified == ["privacy"], third)
        check("blocking: …and the rules are compiled anew", third.compiled && blocker.state.identifiers != before && third.rejected == 0, third)
        await open("/blocking", in: browser)
        check("blocking: …and apply to the tab that was already open", await loaded() == ["allowed"], await loaded())
        check("blocking: the rule lists they replace are removed from disk", await blocker.compiledOnDisk() == blocker.state.identifiers.sorted(), await blocker.compiledOnDisk())

        // A download that is not a filter list.
        blocker.sources[0] = FilterList(id: "ads", name: "Test Ads", about: "Ads", url: URL(string: site + "/filters/portal.txt")!, onByDefault: true)
        let portal = await blocker.update(force: true)
        check("blocking: a sign-in page in place of a list is refused", portal.failed["ads"] == "what the server sent is not a filter list", portal.failed)
        check("blocking: …and the list that works is kept", blocker.isReady && !portal.compiled)
        await open("/blocking", in: browser)
        check("blocking: …still blocking", await loaded() == ["allowed"], await loaded())

        // The next launch: what was compiled is looked up, not downloaded.
        let unreachable = FilterList(id: "ads", name: "Test Ads", about: "Ads", url: URL(string: "http://127.0.0.1:9/never.txt")!, onByDefault: true)
        let relaunched = ContentBlocker(directory: blocker.directory, sources: [unreachable, blocker.sources[1]])
        let controller = WKUserContentController()
        relaunched.register(controller)
        relaunched.start()
        await relaunched.waitUntilLookedUp()
        check("blocking: at the next launch the compiled rules are ready at once, with no network", relaunched.isReady && relaunched.state.identifiers == blocker.state.identifiers)
        check("blocking: …and already on the tab made before they were looked up", await waitFor(2) { relaunched.ruleLists.count == blocker.ruleLists.count })
    }
}
