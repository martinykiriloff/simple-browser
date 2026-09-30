import AppKit
import WebKit
import BrowserKit

/// #19: the tab overview, Handoff, and the picture of a tab it keeps.
extension BrowserWindowController {

    // MARK: - Every tab at once

    /// View → Show All Tabs (⇧⌘\), and a pinch in on the page.
    @objc func toggleTabOverview(_ sender: Any?) {
        if tabOverview != nil { hideTabOverview(); return }
        // Over the page, not the window's content view: that is a split view,
        // which would take a new subview for a pane of its own.
        let contentView = pageOverlayHost
        let overview = TabOverviewController()
        overview.onClose = { [weak self] in self?.hideTabOverview() }
        overview.view.translatesAutoresizingMaskIntoConstraints = false
        overview.view.alphaValue = Accessibility.reduceMotion ? 1 : 0
        contentView.addSubview(overview.view)
        NSLayoutConstraint.activate([
            overview.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overview.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overview.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            overview.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        tabOverview = overview
        let tabs = organizer?.tabs(besides: self) ?? [self]
        Task { @MainActor in
            var entries: [TabOverviewController.Entry] = []
            for tab in tabs {
                entries.append(.init(controller: tab, title: tab.isHibernated ? tab.hibernatedTitle : (tab.window?.title ?? ""), url: tab.currentURL,
                                     image: await tab.overviewImage(fresh: tab === self)))
            }
            guard self.tabOverview === overview else { return }
            overview.show(entries, selected: self)
            self.window?.makeFirstResponder(overview.view)
            if !Accessibility.reduceMotion {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0.18
                overview.view.animator().alphaValue = 1
                NSAnimationContext.endGrouping()
            }
        }
    }

    func hideTabOverview() {
        guard let overview = tabOverview else { return }
        tabOverview = nil
        overview.view.removeFromSuperview()
        window?.makeFirstResponder(pageWebView)
    }

    /// The tab as it looks (`fresh`, for the tab in front), or last looked
    /// in front, or a stand-in.
    func overviewImage(fresh: Bool) async -> NSImage? {
        if isHibernated { return hibernationImage ?? lastSnapshot }
        if fresh, let image = try? await pageWebView.takeSnapshot(configuration: nil) {
            lastSnapshot = image
            return image
        }
        return lastSnapshot
    }

    /// Kept as the tab leaves the front: a background tab cannot be pictured.
    func cacheSnapshot() {
        guard !isHibernated, pageWebView.url != nil else { return }
        Task { @MainActor in
            if let image = try? await self.pageWebView.takeSnapshot(configuration: nil) { self.lastSnapshot = image }
        }
    }

    // MARK: - Handoff

    /// The page, offered to the person's other devices; nothing from a
    /// private window, and nothing but web pages.
    func updateHandoff() {
        guard !isPrivate, let url = currentURL, url.scheme == "http" || url.scheme == "https" else {
            userActivity?.invalidate()
            userActivity = nil
            return
        }
        if userActivity?.webpageURL == url {
            userActivity?.title = window?.title
            return
        }
        userActivity?.invalidate()
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        activity.title = window?.title
        userActivity = activity
    }
}
