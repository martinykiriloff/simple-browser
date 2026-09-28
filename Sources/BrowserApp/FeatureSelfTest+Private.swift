import AppKit
import WebKit
import BrowserKit

/// #11 Private windows.
extension FeatureSelfTest {

    func privateWindows() async {
        let browser = first
        let profile = browser.profile.id.description
        browser.window?.makeKeyAndOrderFront(nil)
        guard let history = app.history(for: browser.profile) else { return }
        try? history.deleteVisits(since: .distantPast)
        BrowserSettings.newWindowContent = .startPage
        defer { BrowserSettings.newWindowContent = .empty }

        func text(_ id: String, in tab: BrowserWindowController) async -> String {
            (await js("const el = document.getElementById('\(id)'); return el ? el.textContent : '<none>'", in: tab) as? String) ?? "<no page>"
        }
        func load(_ path: String, in tab: BrowserWindowController, host: String? = nil) async {
            let address = (host ?? site) + path
            tab.load(URL(string: address)!)
            _ = await waitFor {
                guard tab.pageWebView.url?.absoluteString == address, !tab.pageWebView.isLoading else { return false }
                return (await self.js("return document.readyState", in: tab) as? String) == "complete"
            }
            await pause(0.3)
        }

        // The normal window signs in.
        await load("/cookie/set?v=normal", in: browser)
        await load("/cookie/show", in: browser)
        check("private: (setup) the normal window is signed in", await text("cookie", in: browser) == "session=normal", await text("cookie", in: browser))

        // File → New Private Window.
        let file = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "File" }
        let item = file?.items.first { $0.title == "New Private Window" }
        check("private: File → New Private Window, ⇧⌘N", item?.keyEquivalent == "n" && item?.keyEquivalentModifierMask == [.command, .shift], file?.items.map(\.title))
        let before = Set(app.browserControllers.map(ObjectIdentifier.init))
        if let item, let index = file?.index(of: item) { file?.performActionForItem(at: index) }
        _ = await waitFor { self.app.browserControllers.contains { !before.contains(ObjectIdentifier($0)) } }
        guard let secret = app.browserControllers.first(where: { !before.contains(ObjectIdentifier($0)) }) else {
            check("private: a private window opened", false)
            return
        }
        check("private: a private window opened", secret.isPrivate && secret.window?.isVisible == true)
        check("private: …in the profile of the window it was opened from", secret.profile.id == browser.profile.id)
        check("private: its data store is in memory only", !secret.pageWebView.configuration.websiteDataStore.isPersistent)
        check("private: the normal window's is not", browser.pageWebView.configuration.websiteDataStore.isPersistent)
        check("private: its toolbar is dark", secret.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        check("private: …and says Private", !secret.toolbarItemIsHidden("private") && browser.toolbarItemIsHidden("private"))
        check("private: every toolbar button fits beside the badge", secret.overflowingToolbarItems.isEmpty, secret.overflowingToolbarItems)
        check("private: the page still follows the system's appearance, not the toolbar's",
              secret.pageWebView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        check("private: it opens on a page that says what private means", await waitFor { await text("private-title", in: secret) == "Private Browsing" }, await text("private-title", in: secret))
        snapshot(secret.window, "private-window")

        // Signed in there is not signed in here, and the other way round.
        await load("/cookie/show", in: secret)
        check("private: the normal window's sign-in is not the private window's", await text("cookie", in: secret) == "", await text("cookie", in: secret))
        check("private: …nor what the site stored", await text("stored", in: secret) == "", await text("stored", in: secret))
        await load("/cookie/set?v=private", in: secret)
        await load("/cookie/show", in: secret)
        check("private: signing in in the private window works there", await text("cookie", in: secret) == "session=private", await text("cookie", in: secret))
        await load("/cookie/show", in: browser)
        check("private: …and leaves the normal window signed in as it was", await text("cookie", in: browser) == "session=normal", await text("cookie", in: browser))
        check("private: …with its own stored data", await text("stored", in: browser) == "normal", await text("stored", in: browser))

        // A second private tab shares the private session; tabs do not mix.
        secret.window?.makeKeyAndOrderFront(nil)
        let count = app.browserControllers.count
        secret.newWindowForTab(nil)
        _ = await waitFor { self.app.browserControllers.count == count + 1 }
        let second = app.browserControllers.last!
        check("private: ⌘T in a private window is a private tab of that window", second.isPrivate && second !== secret
              && second.window?.tabGroup === secret.window?.tabGroup && second.privateSession === secret.privateSession)
        await load("/cookie/show", in: second)
        check("private: private tabs share the private session", await text("cookie", in: second) == "session=private", await text("cookie", in: second))
        check("private: a private tab cannot be dragged into a normal window, nor one out",
              secret.window?.tabbingIdentifier != browser.window?.tabbingIdentifier && second.window?.tabbingIdentifier == secret.window?.tabbingIdentifier)
        let viaLink = app.newTab(beside: secret, url: URL(string: site + "/second"), inFront: false)
        check("private: a link opened in a new tab from a private window is private", viaLink.isPrivate)
        _ = await waitFor { !viaLink.pageWebView.isLoading && viaLink.pageWebView.url?.path == "/second" }

        // Nothing kept.
        await load("/article", in: secret)
        await load("/long", in: secret)
        await pause(0.5)
        func visited(_ path: String) -> Bool { ((try? history.page(for: URL(string: site + path)!)) ?? nil) != nil }
        check("private: history has what the normal window visited", visited("/cookie/show"))
        check("private: …and nothing the private window did", !visited("/article") && !visited("/long") && !visited("/cookie/set?v=private"))
        browser.window?.makeKeyAndOrderFront(nil)
        browser.typeInAddressBar("Long")
        check("private: the address bar does not offer a private tab, nor a page seen in one", !browser.suggestionTitles.contains("Long page"), browser.suggestionTitles)
        browser.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))
        browser.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))
        secret.typeInAddressBar("Seco")
        check("private: a private window is offered its own private tabs", secret.suggestionKinds.contains { if case .switchToTab = $0 { return true } else { return false } }, secret.suggestionTitles)
        secret.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))
        secret.pressInAddressBar(#selector(NSResponder.cancelOperation(_:)))
        let session = app.currentSession()
        check("private: the session to restore has no private window", session.windows.count == 1
              && session.windows.allSatisfy { $0.tabs.allSatisfy { $0.url?.path != "/long" && $0.url?.path != "/second" } }, session.windows.map { $0.tabs.map(\.url) })

        // Search suggestions.
        BrowserSettings.searchSuggestions = true
        check("private: what is typed in a private window is not sent for suggestions", secret.suggestionsURL(for: "weather tomorrow") == nil)
        check("private: …as it would be from a normal window", browser.suggestionsURL(for: "weather tomorrow")?.host() == "duckduckgo.com")
        check("private: an address is never sent, from either", browser.suggestionsURL(for: "bank.example/login") == nil)
        BrowserSettings.searchSuggestions = false

        // Zoom and blocking, by site, are not remembered.
        await load("/second", in: secret)
        secret.zoomIn(nil)
        check("private: zoom works", abs(secret.zoom - 1.1) < 0.001 && secret.zoomIndicator == "110%")
        check("private: …and the site's other private tabs follow", await waitFor { abs(viaLink.zoom - 1.1) < 0.001 }, viaLink.zoom)
        check("private: …but the site is not written down", BrowserSettings.zoomLevels(profile: profile).isEmpty, BrowserSettings.zoomLevels(profile: profile))
        await load("/second", in: browser)
        check("private: …and the normal window is not zoomed", browser.zoom == 1)
        secret.blocking.setOff(true)
        check("private: blocking switched off for a site holds for the private session", await waitFor { secret.blocking.isOffForSite })
        check("private: …and is not written down either", BrowserSettings.blockingOffSites(profile: profile).isEmpty && !browser.blocking.isOffForSite)

        // Passwords: filled, never saved.
        let store = app.passwords(for: browser.profile).store
        try? await store.deleteAll()
        _ = try? await store.save(origin: site, username: "ada", password: "correct-horse")
        app.passwords(for: browser.profile).changed()
        await load("/signin", in: secret)
        check("private: a saved sign-in is filled", await waitFor { (await self.js("return document.getElementById('password').value", in: secret) as? String) == "correct-horse" })
        _ = await js("""
        for (const [id, value] of [['username', 'grace'], ['password', 'new-in-private']]) {
          const el = document.getElementById(id);
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
          el.dispatchEvent(new InputEvent('input', { bubbles: true }));
        }
        document.getElementById('submit').click();
        """, in: secret)
        _ = await waitFor { secret.pageWebView.url?.path == "/second" }
        await pause(2)
        check("private: a new sign-in is not offered for saving", !secret.passwordCoordinator.hasPrompt && secret.passwordCoordinator.promptController == nil,
              secret.passwordCoordinator.trace.suffix(4))
        check("private: …and the coordinator says why", secret.passwordCoordinator.trace.contains("private window: not offered"), secret.passwordCoordinator.trace.suffix(4))
        check("private: …and nothing was added to the vault", ((try? await store.all()) ?? []).map(\.username) == ["ada"])
        try? await store.deleteAll()

        // Closed private tabs are gone.
        let couldReopen = app.canReopenClosedTab
        viaLink.window?.close()
        second.window?.close()
        await pause(0.4)
        check("private: a closed private tab cannot be reopened", app.canReopenClosedTab == couldReopen)
        check("private: the session lasts while a private tab is open", app.hasPrivateSession)
        secret.window?.close()
        check("private: closing the last private tab ends the private session", await waitFor { !self.app.hasPrivateSession })

        // A new private window starts from nothing.
        browser.window?.makeKeyAndOrderFront(nil)
        app.newPrivateWindow(nil)
        _ = await waitFor { self.app.browserControllers.contains { $0.isPrivate } }
        if let fresh = app.browserControllers.first(where: \.isPrivate) {
            await load("/cookie/show", in: fresh)
            check("private: a new private window is signed in to nothing", await text("cookie", in: fresh) == "", await text("cookie", in: fresh))
            check("private: …and has nothing stored", await text("stored", in: fresh) == "", await text("stored", in: fresh))
            check("private: …and no zoom or blocking choice from the last one", fresh.zoom == 1 && !fresh.blocking.isOffForSite)
            fresh.window?.close()
        } else {
            check("private: a second private window opened", false)
        }
        await load("/cookie/show", in: browser)
        check("private: the normal window is still signed in", await text("cookie", in: browser) == "session=normal", await text("cookie", in: browser))
        BrowserSettings.setZoomLevels([:], profile: profile)
        browser.window?.makeKeyAndOrderFront(nil)
    }
}
