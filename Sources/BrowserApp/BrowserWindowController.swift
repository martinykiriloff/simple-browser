import AppKit
import WebKit
import BrowserKit
import DataKit
import TranslateKit
import InspectKit

/// One tab: a window with one live web view, shown as a tab of its window's
/// native tab group, as Safari's and Finder's tabs are.
///
/// Every tab of a group belongs to the same profile: the group's tabbing
/// identifier is the profile's, so AppKit will not merge or drop a tab into
/// another profile's window.
@MainActor
final class BrowserWindowController: NSWindowController,
                                     NSWindowDelegate,
                                     NSToolbarDelegate,
                                     NSToolbarItemValidation,
                                     NSMenuItemValidation,
                                     NSTextFieldDelegate,
                                     NSSplitViewDelegate,
                                     WKNavigationDelegate,
                                     WKUIDelegate {

    /// Set for a private window: its tabs share this and nothing else.
    let privateSession: PrivateSession?
    var isPrivate: Bool { privateSession != nil }
    private weak var privateItem: NSToolbarItem?
    private var appearanceObservation: NSKeyValueObservation?

    /// Which identity this window browses as. Fixed for the window's life:
    /// its web view's data store was chosen from it. Replaced only by a
    /// rename, which keeps the data store.
    var profile: Profile {
        didSet {
            precondition(profile.dataStoreIdentifier == oldValue.dataStoreIdentifier, "a window cannot change profile")
            syncProfileItem()
        }
    }
    var onClose: (() -> Void)?
    var onBecomeKey: (() -> Void)?
    /// Fills the menu under the profile button. Set by the app delegate.
    var profilesMenuFiller: ProfilesMenuFiller?
    private let profileButton = NSButton()

    /// Replaced when the tab sleeps: a sleeping tab holds a fresh web view
    /// that has loaded nothing, so the page's web process can go.
    private var webView: BrowserWebView
    /// Every web view this tab makes comes from it: same data store, same
    /// agents and message handlers.
    private let configuration: WKWebViewConfiguration
    private let addressField = AddressField()
    private let suggestionsPanel = SuggestionsPanel()
    /// What the person actually typed, without the inline completion.
    private var typedAddress = ""
    /// Where Return goes while an inline completion is showing.
    private var completionURL: URL?
    private var searchSuggestions: [String] = []
    private var suggestTask: Task<Void, Never>?

    /// What the address bar suggests from, gathered per keystroke by the app delegate.
    struct AddressSources {
        var tabs: [(id: String, title: String, url: URL)] = []
        var bookmarks: [SuggestionRanker.Candidate] = []
        var history: [SuggestionRanker.Candidate] = []
    }
    var addressSources: ((String) -> AddressSources)?
    var switchToTab: ((String) -> Void)?
    var removeFromHistory: ((URL) -> Void)?
    private let splitView = NSSplitView()
    private let pageContainer = NSView()
    private var fillConstraints: [NSLayoutConstraint] = []
    private var deviceConstraints: [NSLayoutConstraint] = []
    /// Device-mode state as the DevTools UI sent it; nil when off.
    private(set) var emulation: [String: Any]?

    // Dev tools. The recorder starts with the tab, not with the panel.
    let tab = TabID()
    /// The `alert()`, `confirm()` or `prompt()` showing, if any.
    var pageDialog: PageDialog?
    /// What the agent endpoint knows about this tab while an agent drives it.
    var agentState: AgentTabState?
    private let recorder: InspectorRecorder
    private let bridge: InspectorBridge
    private(set) var devTools: DevToolsController?
    private var devToolsWindow: NSWindow?
    private(set) var isDevToolsVisible = false
    private var recorderPanel: InspectorPanelController?
    private var userAgentIndex = 0
    private var keyMonitor: Any?

    /// Saved sign-ins for this web view: filling, the list under a field, and
    /// the "Save password?" question.
    let passwordCoordinator: PasswordCoordinator
    /// Addresses, cards and one-time codes in forms.
    let autofill: AutofillCoordinator
    /// What the tab plays: its sound, video, Picture in Picture.
    let media = TabMedia()
    /// Told when what the tab plays changes, for the now-playing control.
    var onMediaChange: (() -> Void)?
    let nowPlaying = NowPlayingControl()
    private(set) var pictureInPictureItem: NSToolbarItem?
    private(set) var nowPlayingItem: NSToolbarItem?
    private var mediaObserver: NSObjectProtocol?
    /// View → Show All Tabs, while it is up.
    var tabOverview: TabOverviewController?
    /// How many pages have finished loading in this tab; the performance run waits on it.
    private(set) var pageFinishedCount = 0
    /// The tab as it last looked while in front, for the overview.
    var lastSnapshot: NSImage?
    private var magnifyMonitor: Any?
    private var pinchTotal: CGFloat = 0
    /// Went into Picture in Picture by itself as another tab was chosen.
    var autoPictureInPictureActive = false
    var autoPictureInPictureTask: Task<Void, Never>?
    var wasSelected = false
    private weak var passwordsItem: NSToolbarItem?
    /// Google Translate for this page, and the toolbar button that offers it.
    let translator = PageTranslator()
    private let translateButton = NSButton()
    let downloads: DownloadController
    private let downloadsButton = DownloadsButton()
    private weak var downloadsItem: NSToolbarItem?
    private(set) var downloadsPopover: NSPopover?
    private(set) var downloadsList: DownloadsListController?
    private var downloadsObserver: NSObjectProtocol?
    var showAllDownloads: (() -> Void)?
    /// The right-click menu. Set by the app delegate's `openInNewWindow`.
    let contextMenu: PageContextMenu
    /// Opens a URL in a new window of this window's profile. Set by the app delegate.
    var openInNewWindow: ((URL) -> Void)?
    /// Opens a URL in a new tab beside this one; `true` brings it to the front.
    var openInNewTab: ((URL, Bool) -> Void)?
    /// ⌘T, and the tab bar's "+". Set by the app delegate.
    var onNewTab: (() -> Void)?
    /// A page's `window.open` or `target=_blank`: a new tab whose web view is
    /// created from the configuration WebKit hands over, so `window.opener` works.
    var onPopup: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?
    /// A page finished loading, or a single-page site moved to a new address:
    /// the URL, its title, and whether the person typed it.
    var onVisit: ((URL, String, Bool) -> Void)?
    /// A page's title arrived or changed after it loaded.
    var onTitleChange: ((URL, String) -> Void)?
    /// Set by a navigation from the address bar, for the visit it causes.
    private var typedNavigation = false
    private var pageObservations: [NSKeyValueObservation] = []
    private let backButton = NavigationButton()
    private let forwardButton = NavigationButton()
    // Bookmarks, set by the app delegate.
    /// The profile's bookmarks and reading list.
    var bookmarks: (() -> BookmarkStore?)?
    /// After a change here, so every window's star, bar and menu follow.
    var onBookmarksChanged: (() -> Void)?
    /// Where the reading list keeps its offline copy of a page.
    var readingListArchive: ((BookmarkStore.ReadingItem) -> URL)?
    private let starButton = NSButton()
    private let securityButton = NSButton()
    /// What the site may do, and the questions about it.
    let permissions = PermissionsController()
    private weak var captureItem: NSToolbarItem?
    /// Set by the self-test before it makes a tab: WebKit's pretend camera
    /// and microphone, so getUserMedia can be tested on a Mac with neither,
    /// and without the system's own permission.
    static var usesMockCaptureDevices = false
    /// Reader: the article alone, when the page has one.
    let reader = ReaderController()
    private weak var readerItem: NSToolbarItem?
    private weak var readerAppearanceItem: NSToolbarItem?
    /// Find in page (⌘F).
    let finder = FindController()
    /// "125%", beside the address, while the page is not at its actual size.
    private let zoomButton = NSButton()
    private weak var zoomItem: NSToolbarItem?
    /// The shield: what was blocked on this page, and the site's switch.
    let blocking = BlockingController()
    private(set) var pageSecurity = PageSecurity.none
    let favoritesBar = FavoritesBarController()
    /// Called as the tab closes, with what "Reopen Closed Tab" needs.
    var onTabClosed: ((URL?, Data?, String) -> Void)?

    /// The profile's web extensions: none in private windows.
    let extensions: ProfileExtensions?
    let extensionButtons = NSStackView()
    private(set) var extensionsItem: NSToolbarItem?
    private var extensionsObserver: NSObjectProtocol?

    /// The group this tab is in, and whether it is pinned: see `TabOrganizer`.
    var groupID: TabGroupID?
    var isPinned = false
    weak var organizer: TabOrganizer?
    /// ⌘K, which the app delegate shows over this window.
    var onCommandPalette: (() -> Void)?
    /// Makes this window's sidebar, the first time it is shown.
    var makeSidebar: (() -> TabSidebarController)?
    private(set) var sidebar: TabSidebarController?
    /// Holds the sidebar beside the page and its DevTools.
    private let sidebarSplit = NSSplitView()
    private var tabAccessoryKey = ""
    private var sidebarObserver: NSObjectProtocol?
    /// What the sidebar last showed for this tab, so it reloads only on a change.
    private var listedAs = ""

    init(profile: Profile, recorder: InspectorRecorder, passwords: PasswordService,
         configuration popupConfiguration: WKWebViewConfiguration? = nil, startPage: StartPageSchemeHandler? = nil,
         blocker: ContentBlocker? = nil, privateSession: PrivateSession? = nil, downloads manager: DownloadManager? = nil,
         extensions: ProfileExtensions? = nil) {
        self.extensions = extensions
        self.profile = profile
        self.privateSession = privateSession
        // A private window's downloads are listed with the private session.
        self.downloads = DownloadController(manager: privateSession?.downloads ?? manager ?? DownloadManager(directory: nil))
        self.recorder = recorder
        self.bridge = InspectorBridge(recorder: recorder, tab: tab)
        self.passwordCoordinator = PasswordCoordinator(service: passwords)
        self.autofill = AutofillCoordinator(service: passwords)
        self.contextMenu = PageContextMenu(translator: translator, downloads: downloads)

        let configuration: WKWebViewConfiguration
        if let popupConfiguration {
            // WebKit requires the pop-up's web view to be made from the
            // configuration it hands over, which carries the opener's data
            // store. Its content controller is the opener's too, and this
            // tab installs its own agents and handlers, so it gets a fresh one.
            configuration = popupConfiguration
            configuration.userContentController = WKUserContentController()
        } else {
            configuration = WKWebViewConfiguration()
            // Per-profile isolation at the WebKit level. Never `.default()`.
            // A private window's store is in memory only, and the session's own.
            configuration.websiteDataStore = privateSession?.dataStore ?? WKWebsiteDataStore(forIdentifier: profile.dataStoreIdentifier)
        }
        if let startPage { StartPageSchemeHandler.install(startPage, into: configuration) }
        // The profile's extensions run in its pages; a pop-up's configuration has them already.
        if popupConfiguration == nil, let extensions { configuration.webExtensionController = extensions.controller }
        // Keeps the `_inspector` object alive for the WebKit-inspector menu item.
        WebInspectorSPI.enableDeveloperExtras(on: configuration)
        WebInspectorSPI.keepDebuggableWhenHidden(configuration)
        // Agent scripts and message handlers must exist before the first document.
        bridge.install(into: configuration)
        passwordCoordinator.install(into: configuration)
        autofill.install(into: configuration)
        media.install(into: configuration)
        translator.install(into: configuration)
        contextMenu.install(into: configuration)
        reader.install(into: configuration)
        // Measured: in this app WebKit leaves `mediaDevicesEnabled` off, and
        // a page then has no `navigator.mediaDevices` at all, so no site can
        // even ask for the camera. A browser has to offer it; what a site
        // gets is decided by `PermissionsController`, and by macOS.
        WebInspectorSPI.setPreference("mediaDevicesEnabled", true, on: configuration.preferences)
        // No Notification API for pages: see `SitePermission.offered`.
        WebInspectorSPI.setPreference("notificationsEnabled", false, on: configuration.preferences)
        if Self.usesMockCaptureDevices { WebInspectorSPI.setPreference("mockCaptureDevicesEnabled", true, on: configuration.preferences) }
        // Every window a page opens comes to `createWebViewWith`, where the
        // ones it opened by itself are held back and can be let through.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // The rule lists compiled last time are in place before the first page.
        blocker?.register(configuration.userContentController)
        blocking.blocker = blocker
        blocking.contentController = configuration.userContentController
        blocking.profileID = profile.id.description
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        QuietMode.apply(to: webView)
        self.configuration = configuration

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        QuietMode.apply(to: window)
        window.title = "New Tab"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // Not a tab until it is on screen: ⌘N must open a window even when the
        // person's macOS setting prefers tabs. `didShow` lets it take tabs.
        window.tabbingMode = .disallowed
        // Private tabs only ever join private windows, of the same profile.
        window.tabbingIdentifier = Self.tabbingIdentifier(for: profile) + (privateSession == nil ? "" : ".private")
        if privateSession != nil {
            // Dark chrome, so a private window is known at a glance. The
            // page itself keeps following the system's appearance.
            window.appearance = NSAppearance(named: .darkAqua)
            webView.appearance = NSApp.effectiveAppearance
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
                DispatchQueue.main.async { self?.webView.appearance = app.effectiveAppearance }
            }
            passwordCoordinator.allowsSaving = false
            autofill.allowsSaving = false
        }
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        window.setFrameAutosaveName("BrowserWindow")
        window.delegate = self

        // The page lives in a container so device mode can give it a phone's
        // viewport and centre it on a backdrop, as Chrome's device toolbar does.
        pageContainer.wantsLayer = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(webView)
        fillConstraints = [
            webView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(fillConstraints)

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(pageContainer)
        sidebarSplit.isVertical = true
        sidebarSplit.dividerStyle = .thin
        sidebarSplit.delegate = self
        sidebarSplit.addArrangedSubview(splitView)
        window.contentView = sidebarSplit

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true   // pinch, and two-finger double-tap to zoom in on a part
        // Always shippable per ARCHITECTURE.md: "Debug in Safari" is the escape hatch.
        webView.isInspectable = true
        webView.contextMenu = contextMenu
        contextMenu.webView = webView
        contextMenu.inspect = { [weak self] point in
            guard let self else { return }
            self.showDevTools(panel: "elements")
            self.devTools?.inspectElement(atPagePoint: point)
        }
        contextMenu.viewSource = { [weak self] in self?.showDevTools(panel: "sources") }
        contextMenu.openInNewWindow = { [weak self] url in self?.openInNewWindow?(url) }
        contextMenu.openInNewTab = { [weak self] url in self?.openInNewTab?(url, false) }
        contextMenu.openInSplitView = { [weak self] url in self?.openLinkInSplitView(url) }
        contextMenu.extensionItems = { [weak self] in self?.extensionMenuItems() ?? [] }
        translator.webView = webView
        translator.onStateChange = { [weak self] in self?.syncTranslateItem() }
        downloads.webView = webView
        downloads.page = { [weak self] in self?.currentURL }
        configureDownloadsButton()
        bridge.onAuxiliaryMessage = { [weak self] kind, body, _ in
            self?.devTools?.handleAuxiliary(kind: kind, body: body)
        }

        finder.container = pageContainer
        finder.webView = webView
        permissions.webView = webView
        permissions.container = pageContainer
        permissions.anchor = { [weak self] in self?.securityButton }
        permissions.openInNewTab = { [weak self] url in self?.openInNewTab?(url, true) }
        permissions.onChange = { [weak self] in self?.syncCapture() }
        let profileID = profile.id.description
        if let privateSession {
            permissions.stored = { privateSession.permissions }
            permissions.store = { privateSession.permissions = $0 }
        } else {
            permissions.stored = { BrowserSettings.sitePermissions(profile: profileID) }
            permissions.store = { BrowserSettings.setSitePermissions($0, profile: profileID) }
        }
        reader.webView = webView
        reader.onStateChange = { [weak self] in self?.syncReader() }
        zoomButton.bezelStyle = .toolbar
        zoomButton.target = self
        zoomButton.action = #selector(zoomReset(_:))
        zoomButton.toolTip = "Back to actual size (⌘0)"
        if let privateSession {
            blocking.offSites = { privateSession.blockingOffSites }
            blocking.setOffSites = { privateSession.blockingOffSites = $0 }
        }
        blocking.currentURL = { [weak self] in self?.currentURL }
        blocking.reload = { [weak self] in self?.reload(nil) }
        blocking.openInNewTab = { [weak self] url in self?.openInNewTab?(url, true) }
        blocking.showSettings = { NSApp.sendAction(#selector(AppDelegate.showPrivacySettings(_:)), to: nil, from: nil) }

        passwordCoordinator.webView = webView
        autofill.webView = webView
        media.webView = webView
        media.onChange = { [weak self] in
            guard let self else { return }
            self.syncTabAccessory()
            self.pictureInPictureItem?.isHidden = !self.media.hasVideo
            self.onMediaChange?()
        }
        autofill.onManage = { NSApp.sendAction(#selector(AppDelegate.showAutofillSettings(_:)), to: nil, from: nil) }
        passwordCoordinator.anchorItem = { [weak self] in self?.passwordsItem }
        passwordCoordinator.onStateChange = { [weak self] in self?.syncPasswordsItem() }
        passwordCoordinator.onManage = {
            NSApp.sendAction(#selector(AppDelegate.showPasswords(_:)), to: nil, from: nil)
        }

        configureAddressField()
        configureNavigationButtons()
        configureStarButton()
        configureSecurityButton()
        observePage()
        configureProfileButton()
        configureTranslateButton()

        let toolbar = NSToolbar(identifier: "BrowserToolbar")
        browserToolbar = toolbar
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // F12 toggles DevTools, and ⌘1–⌘9 pick a tab, as in Chrome and
        // Safari. Menu key equivalents cover the rest.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.keyCode == 111 {
                self.toggleDevTools(nil)
                return nil
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                return self.selectTab(number: digit) ? nil : event
            }
            // ⇧⌘[ / ⇧⌘] (Safari) and ⌥⌘← / ⌥⌘→ (Chrome): the tab to the left or right.
            let key = event.charactersIgnoringModifiers ?? ""
            if modifiers == [.command, .shift], key == "{" || key == "[" || key == "}" || key == "]" {
                self.stepTab(by: key == "{" || key == "[" ? -1 : 1)
                return nil
            }
            if modifiers.contains([.command, .option]), event.keyCode == 123 || event.keyCode == 124,
               self.focusSplitSide(left: event.keyCode == 123) {
                return nil
            }
            if modifiers.contains([.command, .option]), !self.isEditingAddress, event.keyCode == 123 || event.keyCode == 124 {
                self.stepTab(by: event.keyCode == 123 ? -1 : 1)
                return nil
            }
            return event
        }

        // A pinch in on a page that is not zoomed shows every tab, as in Safari.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self.window, self.tabOverview == nil else { return event }
            if event.phase == .began { self.pinchTotal = 0 }
            guard self.webView.magnification <= 1.0, event.magnification < 0 else { return event }
            self.pinchTotal += event.magnification
            if self.pinchTotal < -0.4 {
                self.pinchTotal = 0
                self.toggleTabOverview(nil)
                return nil
            }
            return event
        }

        sidebarObserver = NotificationCenter.default.addObserver(forName: Self.sidebarDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSidebar() }
        }
        extensionButtons.spacing = 2
        if let extensions {
            extensionsObserver = NotificationCenter.default.addObserver(forName: ProfileExtensions.didChange, object: extensions, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncExtensionButtons() }
            }
        }

        if let error = passwordCoordinator.installError {
            recorder.record(.console(ConsoleEntry(level: .error, message: "Password manager is off for this window: \(error).")), tab: tab)
        }
        if let error = bridge.installError {
            recorder.record(.console(ConsoleEntry(
                level: .error,
                message: "Inspector agent failed to load: \(error). Console, network and DOM recording are off for this window."
            )), tab: tab)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    static func tabbingIdentifier(for profile: Profile) -> String { "SimpleBrowser.profile.\(profile.id)" }

    // MARK: - Tabs

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        acceptTabs()
    }

    /// From now on this window can hold tabs, take dropped ones and merge.
    /// The tab bar always shows, as in every browser, not only from two tabs.
    func acceptTabs() {
        guard let window else { return }
        window.tabbingMode = .automatic
        syncSidebar()
        observeSelection()
    }

    private var selectionObservation: NSKeyValueObservation?
    private var orderObservation: NSKeyValueObservation?
    private weak var observedGroup: NSWindowTabGroup?

    /// Wakes the tab the moment its group selects it: the one signal that is
    /// exact whether the app is in front or not. Re-attached when the tab
    /// moves to another window's group.
    private func observeSelection() {
        guard let group = window?.tabGroup, group !== observedGroup else { return }
        observedGroup = group
        selectionObservation = group.observe(\.selectedWindow, options: [.new]) { [weak self] group, _ in
            let selected = group.selectedWindow
            // One hop to the main actor: two would send `self` twice, which
            // Swift 6.2 (CI's compiler) refuses.
            DispatchQueue.main.async {
                guard let self else { return }
                guard selected === self.window else {
                    // Every tab of the group hears it: the one that was in front is left.
                    self.selectionChanged(selected: false)
                    return
                }
                self.lastActive = Date()
                self.wake()
                self.sidebar?.reloadIfStale()
                self.syncTabBar()
                self.extensions?.didActivate(self)
                self.selectionChanged(selected: true)
                self.organizer?.changed()
            }
        }
        // Tabs dragged in the strip: the sidebar follows, and groups stay together.
        orderObservation = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, let organizer = self.organizer else { return }
                organizer.arrange(besides: self)
                organizer.changed()
            }
        }
    }

    /// The tab bar's "+", and File → New Tab (⌘T) through the responder chain.
    override func newWindowForTab(_ sender: Any?) { onNewTab?() }

    /// ⌘1–⌘8 pick that tab, ⌘9 the last, as in every browser.
    @discardableResult
    func selectTab(number: Int) -> Bool {
        guard let window, let tabs = window.tabbedWindows, !tabs.isEmpty else { return false }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return true }
        tabs[index].makeKeyAndOrderFront(nil)
        return true
    }

    /// The next or previous tab, wrapping round.
    func stepTab(by step: Int) {
        guard let window, let tabs = window.tabbedWindows, tabs.count > 1,
              let index = tabs.firstIndex(of: window) else { return }
        tabs[(index + step + tabs.count) % tabs.count].makeKeyAndOrderFront(nil)
    }

    /// Called before ⇧⌘W closes the window, with every tab, for Reopen Last Closed Window.
    var onWindowClosing: ((BrowserWindowController) -> Void)?

    /// File → Close Window (⇧⌘W): every tab of this window.
    @objc func closeWindowAndTabs(_ sender: Any?) {
        onWindowClosing?(self)
        for tab in window?.tabbedWindows ?? [window].compactMap({ $0 }) { tab.performClose(sender) }
    }

    // MARK: - Split view

    /// On the tab whose window shows two pages: the split. On the tab shown
    /// beside it: the tab whose window it is in. See `SplitViewController`.
    var split: SplitViewController?
    weak var splitHost: BrowserWindowController?
    var isInSplit: Bool { split != nil || splitHost != nil }
    /// This tab's own toolbar, wherever it is shown.
    private(set) weak var browserToolbar: NSToolbar?

    /// Where the page is: for what is laid over it.
    var pageArea: NSView { pageContainer }

    /// The window this tab's page is on screen in: its own, or, beside
    /// another tab in a split, that tab's.
    var shownWindow: NSWindow? { pageContainer.window ?? window }

    /// Takes the page (and whatever is over it) out of this tab's window, for a split.
    func detachPage() -> NSView {
        splitView.removeArrangedSubview(pageContainer)
        pageContainer.removeFromSuperview()
        return pageContainer
    }

    /// Shows `view` where this tab's page was, with DevTools still beside it.
    func showInPlaceOfPage(_ view: NSView) {
        splitView.insertArrangedSubview(view, at: 0)
        if splitView.arrangedSubviews.count > 1 { splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0) }
    }

    /// Puts the page back where it was, replacing whatever stood in for it.
    func reattachPage(replacing stand: NSView? = nil) {
        if let stand, stand.superview === splitView {
            splitView.removeArrangedSubview(stand)
            stand.removeFromSuperview()
        }
        pageContainer.removeFromSuperview()
        splitView.insertArrangedSubview(pageContainer, at: 0)
        if splitView.arrangedSubviews.count > 1 { splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0) }
    }

    /// Brings this tab to the front: its window, or the split it is in, on its side.
    func show() {
        if let host = splitHost {
            host.window?.makeKeyAndOrderFront(nil)
            host.split?.focus(self)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// ⌘W with a split closes the side in front; the other stays, as a tab.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, let split else { return true }
        split.close(split.focused)
        return false
    }

    /// ⌥⌘← / ⌥⌘→ in a split: the side that way, if not there already.
    private func focusSplitSide(left: Bool) -> Bool {
        guard let split, !split.focused.isEditingAddress else { return false }
        guard let target = left ? split.host : split.guest, split.focused !== target else { return false }
        split.focus(target)
        return true
    }

    // MARK: - Sidebar

    /// The sidebar was shown or hidden, resized, or tabs moved to or from it.
    static let sidebarDidChange = Notification.Name("BrowserWindowController.sidebarDidChange")

    /// Shows or hides the sidebar as the settings say, and the tab bar with
    /// it: the bar is hidden only while the tabs are in the sidebar.
    func syncSidebar() {
        if BrowserSettings.sidebarShown {
            if sidebar == nil { sidebar = makeSidebar?() }
            if let view = sidebar?.view, view.superview !== sidebarSplit {
                sidebarSplit.insertArrangedSubview(view, at: 0)
                sidebarSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
                sidebarSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)
            }
            applySidebarWidth()
            sidebar?.reload()
        } else if let view = sidebar?.view, view.superview === sidebarSplit {
            sidebarSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        syncTabBar()
    }

    var isSidebarShown: Bool { sidebar?.view.superview === sidebarSplit }

    /// The tab bar shows unless the tabs are in the sidebar. macOS keeps a
    /// window's tab bar up while it has more than one tab, whatever
    /// `toggleTabBar` is told, so the bar's own title bar accessory is
    /// hidden instead: each tab window has one.
    func syncTabBar() {
        guard let window, window.tabbingMode != .disallowed else { return }
        let inSidebar = BrowserSettings.tabsInSidebar && BrowserSettings.sidebarShown
        // The bar of a window with one tab is shown by toggling, once for
        // the group: each tab toggling in turn would undo the other.
        if !inSidebar, let group = window.tabGroup, (group.selectedWindow ?? group.windows.first) === window, !group.isTabBarVisible {
            window.toggleTabBar(nil)
        }
        for accessory in window.titlebarAccessoryViewControllers where Self.isTabBar(accessory) && accessory.isHidden != inSidebar {
            accessory.isHidden = inSidebar
        }
    }

    /// Whether the tab bar is on screen above this tab.
    var isTabBarShown: Bool {
        guard window?.tabGroup?.isTabBarVisible == true else { return false }
        return window?.titlebarAccessoryViewControllers.contains { Self.isTabBar($0) && !$0.isHidden } ?? false
    }

    /// The favorites bar is the app's only accessory; any other is AppKit's,
    /// for the tabs. Not told by what it holds: hidden, it lets go of it.
    private static func isTabBar(_ accessory: NSTitlebarAccessoryViewController) -> Bool {
        !(accessory is FavoritesBarController)
    }

    private var applyingWidth = false

    private func applySidebarWidth() {
        guard isSidebarShown else { return }
        applyingWidth = true
        sidebarSplit.layoutSubtreeIfNeeded()
        sidebarSplit.setPosition(BrowserSettings.sidebarWidth, ofDividerAt: 0)
        applyingWidth = false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === sidebarSplit ? BrowserSettings.SidebarWidth.minimum : proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === sidebarSplit ? min(BrowserSettings.SidebarWidth.maximum, splitView.bounds.width - 300) : proposedMaximumPosition
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    /// The divider dragged: every window's sidebar takes the new width, so
    /// switching tabs does not move the page.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard (notification.object as? NSSplitView) === sidebarSplit, !applyingWidth, isSidebarShown,
              window?.isKeyWindow == true, let width = sidebar?.view.frame.width,
              width >= BrowserSettings.SidebarWidth.minimum, abs(width - BrowserSettings.sidebarWidth) > 0.5 else { return }
        BrowserSettings.sidebarWidth = width
        NotificationCenter.default.post(name: Self.sidebarDidChange, object: self)
    }

    /// View → Show Sidebar (⇧⌘S), and the toolbar button.
    @objc func toggleBrowserSidebar(_ sender: Any?) {
        BrowserSettings.sidebarShown.toggle()
        NotificationCenter.default.post(name: Self.sidebarDidChange, object: self)
    }

    /// File → Command Palette (⌘K).
    @objc func showCommandPalette(_ sender: Any?) { onCommandPalette?() }

    /// The group's colour, or a pin, on the tab in the strip.
    /// On the tab in the strip: a pin, or its group's colour, and a speaker
    /// while it plays sound, which mutes it when clicked.
    func syncTabAccessory() {
        guard let window else { return }
        let group = organizer?.group(groupID)
        let sound = media.isMuted ? "muted" : media.isAudible ? "sound" : ""
        let key = (isPinned ? "pin" : group.map { "group.\($0.color.rawValue)" } ?? "") + (sound.isEmpty ? "" : "+" + sound)
        guard key != tabAccessoryKey else { return }
        tabAccessoryKey = key
        var views: [NSView] = []
        if isPinned {
            let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") ?? NSImage())
            pin.symbolConfiguration = .init(pointSize: 9, weight: .regular)
            pin.contentTintColor = .secondaryLabelColor
            views.append(pin)
        } else if let group {
            // A layer, not an image: the tab bar draws images in its own grey.
            let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = group.color.nsColor.cgColor
            dot.layer?.cornerRadius = 4
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dot.setAccessibilityLabel("In group \(group.name)")
            views.append(dot)
        }
        if !sound.isEmpty {
            let speaker = NSButton(image: NSImage(systemSymbolName: sound == "muted" ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                                  accessibilityDescription: sound == "muted" ? "Unmute Tab" : "Mute Tab") ?? NSImage(),
                                   target: self, action: #selector(toggleMuteTab(_:)))
            speaker.isBordered = false
            speaker.symbolConfiguration = .init(pointSize: 10, weight: .regular)
            speaker.toolTip = sound == "muted" ? "Unmute this tab" : "Mute this tab"
            views.append(speaker)
        }
        if views.count > 1 {
            let stack = NSStackView(views: views)
            stack.spacing = 4
            window.tab.accessoryView = stack
        } else {
            window.tab.accessoryView = views.first
        }
    }

    /// For the self-test: what the tab in the strip carries.
    var tabAccessory: String { tabAccessoryKey }

    /// The page's icon, for the sidebar and ⌘K.
    private func loadFavicon() {
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        let webView = webView
        Task {
            let href = try? await webView.callAsyncJavaScript(
                "const link = document.querySelector('link[rel~=\"icon\" i]'); return link ? link.href : null",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? String
            Favicons.shared.load(href.flatMap(URL.init(string:)), for: url)
        }
    }

    // MARK: - Hibernation

    /// When this tab was last in front, for the memory saver.
    private(set) var lastActive = Date()
    private(set) var isHibernated = false
    private var hibernatedState: Any?
    private var hibernatedURL: URL?
    private(set) var hibernatedTitle = ""
    private let snapshotView = NSImageView()
    /// Where things go over the page: the overview, notices.
    var pageOverlayHost: NSView { pageContainer }
    /// The picture a sleeping tab shows.
    var hibernationImage: NSImage? { snapshotView.image }

    /// Whether this tab must stay live: on screen, making sound, using the
    /// camera or microphone, holding a form someone is filling in, or being
    /// inspected. Asked of the page, because only it knows.
    func mustStayLive() async -> Bool {
        if window?.isVisible == true && window?.tabGroup?.selectedWindow === window { return true }
        // A tab beside another in a split is on screen whenever that one is.
        if splitHost != nil { return true }
        if window?.tabGroup == nil && window?.isVisible == true { return true }
        if isDevToolsVisible { return true }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        if webView.url == nil || webView.isLoading { return true }
        let busy = try? await webView.callAsyncJavaScript("""
            const playing = Array.from(document.querySelectorAll('video, audio')).some(m => !m.paused && !m.muted);
            const editing = Array.from(document.querySelectorAll('input, textarea')).some(f =>
                !['hidden', 'submit', 'button', 'checkbox', 'radio'].includes(f.type) && f.value !== f.defaultValue);
            return playing || editing;
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        return busy ?? true
    }

    /// Frees the page: keeps its history, scroll position and form state and a
    /// picture of it, then unloads it so its web process can go.
    func hibernate() async {
        guard !isHibernated, let url = webView.url else { return }
        let state = webView.interactionState
        let image = try? await webView.takeSnapshot(configuration: nil)
        guard !isHibernated, webView.url == url else { return }   // navigated meanwhile
        isHibernated = true
        hibernatedState = state
        hibernatedURL = url
        hibernatedTitle = window?.title ?? ""
        if let image { showSnapshot(image) }
        replaceWebView()
        window?.tab.attributedTitle = NSAttributedString(string: hibernatedTitle, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        window?.tab.toolTip = "\(hibernatedTitle)\nSleeping to save memory. It wakes when you open it."
    }

    /// Back as it was, with the picture shown until the page has drawn.
    func wake() {
        guard isHibernated else { return }
        isHibernated = false
        window?.tab.attributedTitle = nil
        window?.tab.toolTip = nil
        if let state = hibernatedState { webView.interactionState = state } else if let url = hibernatedURL { webView.load(URLRequest(url: url)) }
        hibernatedState = nil
        hibernatedURL = nil
        // Should the page never finish, the picture must not stay forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.hideSnapshot() }
    }

    /// Swaps in a web view that has loaded nothing, and lets the old one go
    /// with its page and web process. Everything that talks to the page is
    /// pointed at the new one.
    private func replaceWebView() {
        let old = webView
        let fresh = BrowserWebView(frame: .zero, configuration: configuration)
        QuietMode.apply(to: fresh)
        fresh.navigationDelegate = self
        fresh.uiDelegate = self
        fresh.allowsBackForwardNavigationGestures = true
        fresh.allowsMagnification = true
        fresh.isInspectable = true
        fresh.customUserAgent = old.customUserAgent
        fresh.pageZoom = old.pageZoom
        fresh.appearance = old.appearance
        fresh.contextMenu = contextMenu
        fresh.translatesAutoresizingMaskIntoConstraints = false

        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        NSLayoutConstraint.deactivate(fillConstraints + deviceConstraints)
        deviceConstraints = []
        pageContainer.replaceSubview(old, with: fresh)
        webView = fresh
        fillConstraints = [
            fresh.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            fresh.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            fresh.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            fresh.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(fillConstraints)

        contextMenu.webView = fresh
        permissions.webView = fresh
        finder.webView = fresh
        reader.webView = fresh
        observePage()
        translator.webView = fresh
        downloads.webView = fresh
        passwordCoordinator.webView = fresh
        autofill.webView = fresh
        media.webView = fresh
        // The inspector and recording panel were bound to the old page.
        madeProtocolBridge = nil
        devTools?.tearDown()
        devTools = nil
        recorderPanel?.close()
        recorderPanel = nil
        emulation = nil
    }

    private func showSnapshot(_ image: NSImage) {
        snapshotView.image = image
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        if snapshotView.superview == nil {
            pageContainer.addSubview(snapshotView, positioned: .above, relativeTo: webView)
            NSLayoutConstraint.activate([
                snapshotView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                snapshotView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                snapshotView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                snapshotView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            ])
        }
    }

    private func hideSnapshot() {
        guard !isHibernated else { return }
        snapshotView.removeFromSuperview()
        snapshotView.image = nil
    }

    /// A tab brought back from the last session, asleep: nothing loads until
    /// it is shown, so a launch with fifty tabs is as quick as with one.
    func restoreAsleep(url: URL?, title: String, state: Data?) {
        isHibernated = true
        hibernatedState = state
        hibernatedURL = url
        hibernatedTitle = title
        window?.title = title.isEmpty ? (url?.host() ?? "New Tab") : title
        window?.tab.attributedTitle = NSAttributedString(string: window?.title ?? "", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        addressField.stringValue = url?.absoluteString ?? ""
    }

    /// This tab, as the session file keeps it.
    var sessionTab: SessionSnapshot.Tab {
        SessionSnapshot.Tab(url: currentURL, title: isHibernated ? hibernatedTitle : (window?.title ?? ""),
                            state: interactionState as? Data, groupID: groupID, isPinned: isPinned, besidePrevious: splitHost != nil)
    }

    /// A short message over the top of the page that goes away by itself.
    func showNotice(_ text: String, seconds: Double = 8) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        let box = NSVisualEffectView()
        box.material = .popover
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        pageContainer.addSubview(box, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            box.centerXAnchor.constraint(equalTo: pageContainer.centerXAnchor),
            box.topAnchor.constraint(equalTo: pageContainer.topAnchor, constant: 12),
        ])
        lastNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak box] in
            NSAnimationContext.runAnimationGroup({ _ in box?.animator().alphaValue = 0 }, completionHandler: { box?.removeFromSuperview() })
        }
    }

    /// For the self-test.
    private(set) var lastNotice: String?

    /// Back/forward list, scroll position and form state, for Reopen Closed Tab.
    var interactionState: Any? {
        get { isHibernated ? hibernatedState : webView.interactionState }
        set { webView.interactionState = newValue }
    }

    func showWindowAndFocusAddress() {
        showWindow(nil)
        focusAddressBar(nil)
    }

    func load(_ url: URL) {
        if isHibernated {
            isHibernated = false
            hibernatedState = nil
            window?.tab.attributedTitle = nil
            hideSnapshot()
        }
        webView.load(URLRequest(url: url))
    }

    // MARK: - Actions (reached via menu key equivalents and toolbar buttons)

    @objc func navigate(_ sender: Any?) {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let completed = completionURL.flatMap { text == typedAddress + completionText ? $0 : nil }
        guard let url = completed ?? BrowserSettings.destination(for: text) else { return }
        suggestionsPanel.hide()
        typedNavigation = true
        load(url)
        shownWindow?.makeFirstResponder(webView)
    }

    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func stopLoading(_ sender: Any?) { webView.stopLoading() }

    @objc func reload(_ sender: Any?) {
        if webView.url == nil {
            navigate(sender)
        } else {
            webView.reload()
        }
    }

    @objc func reloadFromOrigin(_ sender: Any?) {
        if webView.url == nil {
            navigate(sender)
        } else {
            webView.reloadFromOrigin()
        }
    }

    @objc func goHome(_ sender: Any?) {
        load(BrowserSettings.homepageURL)
        shownWindow?.makeFirstResponder(webView)
    }

    /// Developer aid: run a script in the page, as the page. The self-tests
    /// use it to act as the person at the keyboard.
    func evaluateInPage(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Developer aid: put keyboard focus in the page, as a click into it would.
    func focusPage() { shownWindow?.makeFirstResponder(webView) }

    /// Developer aid, for the self-test to read the key button's state.
    var passwordsToolbarItem: NSToolbarItem? { passwordsItem }

    // MARK: - Passwords

    @objc func showSitePasswords(_ sender: Any?) {
        passwordCoordinator.toggleFromKeyButton()
    }

    /// A filled key while this site has saved sign-ins; tinted while a
    /// "Save password?" is waiting for an answer.
    private func syncPasswordsItem() {
        guard let item = passwordsItem else { return }
        let waiting = passwordCoordinator.hasPrompt
        let saved = passwordCoordinator.siteCredentialCount
        let symbol = waiting || saved > 0 ? "key.fill" : "key"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Passwords")
        item.image = waiting ? image?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) : image
        item.toolTip = waiting ? "Save this password?"
            : saved == 0 ? "Passwords"
            : saved == 1 ? "1 password saved for this site" : "\(saved) passwords saved for this site"
    }

    /// The page currently showing, for "Set to Current Page" in Settings.
    var currentURL: URL? { isHibernated ? hibernatedURL : shownURL }

    /// The page showing. In Reader that is the article's own address: what
    /// the address bar says, what a bookmark keeps, what zoom goes by.
    private var shownURL: URL? { errorPageURL ?? ReaderPage.original(of: webView.url) ?? WarningPage.original(of: webView.url) ?? webView.url }
    /// The address whose load failed, kept in the bar while the error page shows.
    private var errorPageURL: URL?

    // MARK: - Certificates

    /// Certificates this profile's windows went on with, or for a private
    /// window, its private session's.
    private var certificateExceptions: CertificateExceptions {
        get { privateSession?.certificateExceptions ?? CertificateStore.shared.exceptions(for: profile.id.description) }
        set {
            if let privateSession { privateSession.certificateExceptions = newValue }
            else { CertificateStore.shared.setExceptions(newValue, for: profile.id.description) }
        }
    }

    /// Whether the page showing is a certificate warning.
    var isShowingCertificateWarning: Bool { WarningPage.isWarning(webView.url) }

    /// A server proving who it is. One whose certificate the person went
    /// on with is let through for that certificate; everything else is
    /// WebKit's to judge.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
        let fingerprint = CertificateStore.details(of: trust).fingerprint
        guard certificateExceptions.allows(host: space.host, port: space.port, fingerprint: fingerprint) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// The page shown in place of a site whose certificate did not verify.
    private func showCertificateWarning(for url: URL, error: NSError) -> Bool {
        guard CertificateProblem.Kind.isCertificateError(error.code), url.scheme == "https" else { return false }
        let trust = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey].map { $0 as! SecTrust }
        let details = CertificateStore.details(of: trust)
        let problem = CertificateProblem(url: url, kind: .init(errorCode: error.code), fingerprint: details.fingerprint,
                                         subject: details.subject, issuer: details.issuer, expires: details.expires)
        guard let address = WarningPage.url(token: CertificateStore.shared.add(problem), original: url) else { return false }
        webView.load(URLRequest(url: address))
        return true
    }

    /// "Go Back" and "Visit this website anyway" on a warning page.
    private func perform(_ action: WarningPage.Action) {
        switch action {
        case .back:
            // Back past the warning, to whatever was showing before it.
            if let item = webView.backForwardList.backList.last(where: { !WarningPage.isWarning($0.url) }) { webView.go(to: item) }
            else { load(StartPageSchemeHandler.url) }
        case .proceed(let token):
            guard WarningPage.token(of: webView.url) == token, let problem = CertificateStore.shared.problem(for: token) else { return }
            var exceptions = certificateExceptions
            exceptions.accept(problem)
            certificateExceptions = exceptions
            // In the warning's place in the tab's history, not after it:
            // Back from the site must not lead to a warning already answered.
            webView.callAsyncJavaScript("location.replace(address)", arguments: ["address": problem.url.absoluteString],
                                        in: nil, in: .defaultClient) { [weak self] result in
                MainActor.assumeIsolated {
                    if case .failure = result { self?.load(problem.url) }
                }
            }
        }
    }

    @objc func focusAddressBar(_ sender: Any?) {
        shownWindow?.makeFirstResponder(addressField)
        addressField.selectText(nil)
    }

    // MARK: - DevTools

    @objc func toggleDevTools(_ sender: Any?) {
        if isDevToolsVisible { hideDevTools() } else { showDevTools(panel: nil) }
    }

    @objc func showDevToolsConsole(_ sender: Any?) { showDevTools(panel: "console") }
    @objc func showDevToolsElements(_ sender: Any?) { showDevTools(panel: "elements") }
    @objc func showDevToolsNetwork(_ sender: Any?) { showDevTools(panel: "network") }
    @objc func showDevToolsSources(_ sender: Any?) { showDevTools(panel: "sources") }

    @objc func inspectElementMode(_ sender: Any?) {
        showDevTools(panel: "elements")
        devTools?.startInspectMode()
    }

    @objc func dockDevTools(_ sender: NSMenuItem) {
        guard let side = sender.representedObject as? String else { return }
        devTools?.dockSide = side
        applyDockSide(side)
    }

    func showDevTools(panel: String?) {
        let tools = devTools ?? makeDevTools()
        if !isDevToolsVisible {
            attach(tools, side: tools.dockSide)
            isDevToolsVisible = true
            tools.didShow()
        }
        if let panel { tools.showPanel(panel) }
        if devToolsWindow == nil { shownWindow?.makeFirstResponder(tools.view) }
    }

    private func hideDevTools() {
        guard let tools = devTools else { return }
        detach(tools)
        isDevToolsVisible = false
        tools.didHide()
        shownWindow?.makeFirstResponder(webView)
    }

    private func makeDevTools() -> DevToolsController {
        let tools = DevToolsController(page: webView, recorder: recorder, tab: tab, protocolBridge: protocolBridge)
        tools.onClose = { [weak self] in self?.hideDevTools() }
        tools.onDockSideChange = { [weak self] side in self?.applyDockSide(side) }
        tools.onNavigate = { [weak self] url in self?.load(url) }
        tools.onReload = { [weak self] in self?.reload(nil) }
        tools.onEmulation = { [weak self] device in self?.setDeviceEmulation(device) }
        tools.currentEmulation = { [weak self] in self?.emulation }
        devTools = tools
        return tools
    }

    private func applyDockSide(_ side: String) {
        guard let tools = devTools, isDevToolsVisible else { return }
        detach(tools)
        attach(tools, side: side)
    }

    private func attach(_ tools: DevToolsController, side: String) {
        if side == "undocked" {
            let toolsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            toolsWindow.title = "DevTools — \(window?.title ?? "SimpleBrowser")"
            toolsWindow.contentView = tools.view
            toolsWindow.isReleasedWhenClosed = false
            toolsWindow.delegate = self
            if !toolsWindow.setFrameUsingName("DevToolsWindow") { toolsWindow.center() }
            toolsWindow.setFrameAutosaveName("DevToolsWindow")
            toolsWindow.makeKeyAndOrderFront(nil)
            devToolsWindow = toolsWindow
            return
        }
        splitView.isVertical = side == "right"
        splitView.addArrangedSubview(tools.view)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        splitView.layoutSubtreeIfNeeded()
        let total = side == "right" ? splitView.bounds.width : splitView.bounds.height
        let saved = UserDefaults.standard.double(forKey: "devtools.size." + side)
        let size = saved > 100 && saved < total - 100 ? saved : total * (side == "right" ? 0.42 : 0.45)
        splitView.setPosition(total - size, ofDividerAt: 0)
    }

    private func detach(_ tools: DevToolsController) {
        if let toolsWindow = devToolsWindow {
            toolsWindow.delegate = nil
            toolsWindow.orderOut(nil)
            toolsWindow.contentView = nil
            devToolsWindow = nil
            return
        }
        let side = splitView.isVertical ? "right" : "bottom"
        let size = splitView.isVertical ? tools.view.frame.width : tools.view.frame.height
        if size > 0 { UserDefaults.standard.set(size, forKey: "devtools.size." + side) }
        splitView.removeArrangedSubview(tools.view)
        tools.view.removeFromSuperview()
    }

    // MARK: - Device mode

    /// Gives the page a device's viewport and user agent. Media queries,
    /// `innerWidth` and server-side UA sniffing all respond; touch events and
    /// device pixel ratio are not emulated.
    func setDeviceEmulation(_ device: [String: Any]?) {
        NSLayoutConstraint.deactivate(deviceConstraints)
        deviceConstraints = []
        let previousAgent = webView.customUserAgent

        guard let device, let width = (device["width"] as? NSNumber)?.doubleValue,
              let height = (device["height"] as? NSNumber)?.doubleValue, width > 0, height > 0 else {
            emulation = nil
            NSLayoutConstraint.activate(fillConstraints)
            pageContainer.layer?.backgroundColor = nil
            webView.customUserAgent = UserAgentPreset.all[userAgentIndex].value
            if previousAgent != webView.customUserAgent, webView.url != nil { webView.reload() }
            return
        }

        emulation = device
        NSLayoutConstraint.deactivate(fillConstraints)
        pageContainer.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        let exactWidth = webView.widthAnchor.constraint(equalToConstant: width)
        let exactHeight = webView.heightAnchor.constraint(equalToConstant: height)
        // The device size wins unless the window is smaller than the device.
        exactWidth.priority = .defaultHigh
        exactHeight.priority = .defaultHigh
        deviceConstraints = [
            exactWidth, exactHeight,
            webView.widthAnchor.constraint(lessThanOrEqualTo: pageContainer.widthAnchor),
            webView.heightAnchor.constraint(lessThanOrEqualTo: pageContainer.heightAnchor),
            webView.centerXAnchor.constraint(equalTo: pageContainer.centerXAnchor),
            webView.centerYAnchor.constraint(equalTo: pageContainer.centerYAnchor),
        ]
        NSLayoutConstraint.activate(deviceConstraints)
        webView.customUserAgent = (device["userAgent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? UserAgentPreset.all[userAgentIndex].value
        if previousAgent != webView.customUserAgent, webView.url != nil { webView.reload() }
    }

    // MARK: - Inspector protocol

    private var madeProtocolBridge: InspectorProtocolBridge?
    /// Made on first use, for the web view the tab has then.
    var protocolBridge: InspectorProtocolBridge {
        if let madeProtocolBridge { return madeProtocolBridge }
        let bridge = InspectorProtocolBridge(page: webView)
        madeProtocolBridge = bridge
        return bridge
    }

    /// Developer aid: exercises the protocol bridge and reports what it found.
    func protocolProbe() async -> [String: Any] {
        var report: [String: Any] = [
            "pageURLBefore": webView.url?.absoluteString ?? "nil",
            "pageLoadingBefore": webView.isLoading,
        ]
        var events: [String] = []
        protocolBridge.onEvent = { method, _ in if events.count < 200 { events.append(method) } }
        do {
            try await protocolBridge.attach()
            report["attached"] = true
            for (method, params) in [
                ("Runtime.evaluate", ["expression": "location.href + ' | ' + document.title + ' | ' + document.readyState + ' | children=' + (document.body ? document.body.children.length : -1)"] as [String: Any]),
                ("Debugger.enable", [:]),
                ("Network.enable", [:]),
                ("Page.getResourceTree", [:]),
                ("DOM.getDocument", [:]),
            ] {
                do {
                    let result = try await protocolBridge.send(method, params)
                    let data = try JSONSerialization.data(withJSONObject: result)
                    report[method] = String(String(decoding: data, as: UTF8.self).prefix(600))
                } catch {
                    report[method] = "ERROR: \(error.localizedDescription)"
                }
            }
        } catch {
            report["attached"] = false
            report["error"] = error.localizedDescription
        }
        // How does the frontend keep the scripts it already knows about?
        report["frontendScripts"] = await protocolBridge.evaluateInFrontend("""
        (function () {
          var out = { keys: [], scripts: [] };
          try {
            var dm = WI.debuggerManager;
            out.keys = Object.getOwnPropertyNames(dm).filter(function (k) { return /script|target/i.test(k); });
            var maps = [];
            if (dm._scriptIdMap) maps.push(dm._scriptIdMap);
            if (dm._targetDebuggerDataMap) dm._targetDebuggerDataMap.forEach(function (data) {
              out.dataKeys = Object.getOwnPropertyNames(data);
              if (data._scriptIdMap) maps.push(data._scriptIdMap);
              if (data.scriptIdMap) maps.push(data.scriptIdMap);
            });
            maps.forEach(function (m) { m.forEach(function (s) { out.scripts.push({ id: s.id, url: s.url, range: s.range ? [s.range.startLine, s.range.endLine] : null }); }); });
          } catch (e) { out.error = String(e); }
          return JSON.stringify(out);
        })()
        """) as? String ?? "nil"

        // Does a pause reach us, and does it pop WebKit's window open?
        events.removeAll()
        _ = try? await protocolBridge.send("Runtime.evaluate", ["expression": "setTimeout(function probePause() { var local = 41; debugger; local++; }, 0); 'scheduled'"])
        try? await Task.sleep(for: .milliseconds(1200))
        report["eventsAfterDebuggerStatement"] = events
        report["inspectorVisibleWhilePaused"] = WebInspectorSPI.isVisible(webView)
        report["resume"] = (try? await protocolBridge.send("Debugger.resume").description) ?? "failed"
        try? await Task.sleep(for: .milliseconds(500))
        report["events"] = events
        report["inspectorVisible"] = WebInspectorSPI.isVisible(webView)
        return report
    }

    // MARK: - Develop (other)

    @objc func showRecorder(_ sender: Any?) {
        let panel = recorderPanel ?? {
            let panel = InspectorPanelController(recorder: recorder, tab: tab, webView: webView)
            recorderPanel = panel
            return panel
        }()
        panel.update(title: window?.title ?? "SimpleBrowser")
        panel.showWindow(sender)
        panel.window?.makeKeyAndOrderFront(sender)
    }

    @objc func showWebKitInspector(_ sender: Any?) {
        if !WebInspectorSPI.show(webView) { explainDebugInSafari(sender) }
    }

    @objc func selectUserAgent(_ sender: NSMenuItem) {
        guard UserAgentPreset.all.indices.contains(sender.tag) else { return }
        userAgentIndex = sender.tag
        // Device mode owns the user agent while it is on.
        guard emulation?["userAgent"] as? String ?? "" == "" else { return }
        webView.customUserAgent = UserAgentPreset.all[sender.tag].value
        if webView.url != nil { webView.reload() }
    }

    @objc func explainDebugInSafari(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = WebInspectorSPI.isAvailable(for: webView)
            ? "Debug in Safari"
            : "WebKit's inspector is not available in this build"
        alert.informativeText = """
        This page is inspectable from Safari on this Mac or a Mac connected over the network.

        Safari → Develop → \(Host.current().localizedName ?? "this Mac") → SimpleBrowser → \(webView.title ?? webView.url?.absoluteString ?? "the page")

        If the Develop menu is hidden: Safari → Settings → Advanced → Show features for web developers.
        """
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Bookmarks

    private func configureStarButton() {
        starButton.bezelStyle = .toolbar
        starButton.target = self
        starButton.action = #selector(addBookmark(_:))
        starButton.setAccessibilityLabel("Bookmark this page")
        syncStar()
    }

    // MARK: - The downloads button

    private func configureDownloadsButton() {
        downloadsButton.bezelStyle = .toolbar
        downloadsButton.target = self
        downloadsButton.action = #selector(showDownloads(_:))
        downloadsButton.setAccessibilityLabel("Downloads")
        downloadsObserver = NotificationCenter.default.addObserver(forName: DownloadManager.didChange, object: downloads.manager, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDownloads() }
        }
        syncDownloads()
    }

    /// There from the first download of this launch: before that there is
    /// nothing it could show that the Downloads window does not.
    private func syncDownloads() {
        let manager = downloads.manager
        let active = manager.list.active
        downloadsButton.isBusy = !active.isEmpty
        downloadsButton.fraction = manager.list.fraction
        downloadsButton.image = NSImage(systemSymbolName: active.isEmpty ? "arrow.down.circle" : "arrow.down", accessibilityDescription: "Downloads")
        downloadsButton.toolTip = active.isEmpty ? "Downloads" : active.count == 1 ? "Downloading \(active[0].fileName)" : "Downloading \(active.count) files"
        let show = manager.startedThisLaunch > 0 || !active.isEmpty || manager.list.items.contains { $0.state == .paused }
        if downloadsItem?.isHidden == show {
            downloadsItem?.isHidden = !show
            fitAddressField()
        }
    }

    /// The button: the recent downloads, in a popover.
    @objc func showDownloads(_ sender: Any?) {
        if let downloadsPopover, downloadsPopover.isShown { downloadsPopover.close(); return }
        guard downloadsButton.window != nil, downloadsItem?.isHidden == false else { showAllDownloads?(); return }
        let list = DownloadsListController(manager: downloads.manager, limit: 6, showsPage: false,
                                           webView: { [weak self] in self?.webView }, window: { [weak self] in self?.window })
        list.showAll = { [weak self] in
            self?.downloadsPopover?.close()
            self?.showAllDownloads?()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = list
        popover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .maxY)
        downloadsPopover = popover
        downloadsList = list
    }

    // MARK: - Downloads a page starts by itself

    private var downloadsFromPage = 0
    private var lastActionWasUserInitiated = true

    /// A page may hand over one file unasked. A second, started by the page
    /// and not by a click, is asked about: that is how a page fills a disk.
    private func allowsDownload(userInitiated: Bool) async -> Bool {
        if userInitiated { return true }
        downloadsFromPage += 1
        if downloadsFromPage == 1 { return true }
        return await permissions.request([.downloads])
    }

    // MARK: - Camera and microphone

    /// The red camera beside the address, and in the tab, while in use.
    private func syncCapture() {
        captureItem?.isHidden = !permissions.isCapturing
        if permissions.isCapturing {
            let icon = NSImageView(image: NSImage(systemSymbolName: permissions.cameraInUse ? "video.fill" : "mic.fill",
                                                  accessibilityDescription: "Using the camera or microphone") ?? NSImage())
            icon.contentTintColor = .systemRed
            window?.tab.accessoryView = icon
        } else if window?.tab.accessoryView is NSImageView {
            window?.tab.accessoryView = nil
        }
        fitAddressField()
    }

    // MARK: - Reader

    /// View → Show Reader (⇧⌘R).
    @objc func toggleReader(_ sender: Any?) { reader.toggle(sender) }

    private func syncReader() {
        readerItem?.isHidden = !(reader.isAvailable || reader.isActive)
        readerAppearanceItem?.isHidden = !reader.isActive
        fitAddressField()
    }

    // MARK: - Find

    /// Edit → Find → Find… (⌘F). Text selected on the page is what it looks for.
    @objc func findInPage(_ sender: Any?) {
        Task { @MainActor in
            let selected = try? await webView.evaluateJavaScript("window.getSelection().toString()") as? String
            let text = selected.flatMap { $0.contains("\n") || $0.count > 200 ? nil : $0 }
            finder.show(with: text)
        }
    }

    @objc func findNextInPage(_ sender: Any?) { finder.findNext(sender) }
    @objc func findPreviousInPage(_ sender: Any?) { finder.findPrevious(sender) }

    /// ⌘E: the selection becomes what ⌘G looks for, without opening the bar.
    @objc func useSelectionForFind(_ sender: Any?) {
        Task { @MainActor in
            guard let selected = try? await webView.evaluateJavaScript("window.getSelection().toString()") as? String else { return }
            finder.useSelection(selected)
        }
    }

    // MARK: - Zoom

    /// The page's zoom, remembered for its site in this profile.
    var zoom: Double { webView.pageZoom }

    @objc func zoomIn(_ sender: Any?) { setZoom(PageZoom.larger(than: webView.pageZoom)) }
    @objc func zoomOut(_ sender: Any?) { setZoom(PageZoom.smaller(than: webView.pageZoom)) }
    @objc func zoomReset(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ level: Double) {
        webView.pageZoom = level
        if let key = PageZoom.key(for: currentURL) {
            zoomLevels = PageZoom.setting(level, for: key, in: zoomLevels)
            onZoomChanged?(key, level)
        }
        syncZoom()
    }

    /// Another tab of this profile changed the zoom of a site: if this tab
    /// shows that site, it follows, as tabs of one site do everywhere.
    func zoomChanged(for key: String, to level: Double) {
        guard PageZoom.key(for: currentURL) == key, !isHibernated, abs(webView.pageZoom - level) > 0.001 else { return }
        webView.pageZoom = level
        syncZoom()
    }

    var onZoomChanged: ((String, Double) -> Void)?

    /// By site: the profile's, remembered; a private window's, for as long
    /// as the private session lasts.
    private var zoomLevels: [String: Double] {
        get { privateSession?.zoomLevels ?? BrowserSettings.zoomLevels(profile: profile.id.description) }
        set {
            if let privateSession { privateSession.zoomLevels = newValue } else { BrowserSettings.setZoomLevels(newValue, profile: profile.id.description) }
        }
    }

    /// The site's own level as a page of it commits.
    private func applyZoomForPage() {
        let level = PageZoom.key(for: shownURL).flatMap { zoomLevels[$0] } ?? 1
        if abs(webView.pageZoom - level) > 0.001 { webView.pageZoom = level }
        syncZoom()
    }

    private func syncZoom() {
        let level = webView.pageZoom
        zoomButton.title = PageZoom.label(level)
        zoomButton.setAccessibilityLabel("Zoom \(PageZoom.label(level)). Click for actual size.")
        zoomItem?.isHidden = PageZoom.isDefault(level)
        fitAddressField()
    }

    /// Developer aid: what the zoom indicator shows; empty when it is hidden.
    var zoomIndicator: String { PageZoom.isDefault(webView.pageZoom) ? "" : zoomButton.title }

    // MARK: - Page security

    private func configureSecurityButton() {
        // Inside the address field, before the address, as in Safari and
        // Chrome: it is a statement about the address, not another button.
        securityButton.isBordered = false
        securityButton.imagePosition = .imageLeading
        securityButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        securityButton.setButtonType(.momentaryChange)
        securityButton.refusesFirstResponder = true
        securityButton.target = self
        securityButton.action = #selector(showPageSecurity(_:))
        syncSecurity()
    }

    /// A lock for https, "Not Secure" for plain http, nothing for the
    /// browser's own pages.
    private func syncSecurity() {
        // In Reader the article is a copy held by the browser: there is no
        // connection to describe, and the article's own lock would be a lie.
        // A warning is about the page it stands in for, which is not secure.
        let url = reader.isActive ? nil : (isHibernated ? hibernatedURL : shownURL)
        pageSecurity = PageSecurity.of(url, hasOnlySecureContent: webView.hasOnlySecureContent,
                                       certificateAccepted: isShowingCertificateWarning || certificateExceptions.covers(url))
        let trouble = pageSecurity.label != nil
        securityButton.image = pageSecurity.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [trouble ? .systemOrange : .secondaryLabelColor])))
        securityButton.contentTintColor = trouble ? .systemOrange : .secondaryLabelColor
        securityButton.attributedTitle = NSAttributedString(string: pageSecurity.label ?? "", attributes: [
            .foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
        ])
        let site = Self.displayAddress(url)
        let summary: String
        switch pageSecurity {
        case .secure: summary = "Connection is secure"
        case .mixed: summary = "Parts of this page are not encrypted"
        case .notSecure: summary = "Connection is not encrypted"
        case .untrusted: summary = isShowingCertificateWarning ? "This site's certificate could not be verified" : "Connection is not verified"
        case .local: summary = "This page is on this Mac"
        case .none: summary = ""
        }
        securityButton.toolTip = summary
        securityButton.setAccessibilityLabel(summary.isEmpty ? "Page security" : "\(summary): \(site)")
        securityButton.isHidden = pageSecurity == .none
        addressField.setLeadingAccessory(securityButton)
    }

    /// The lock: the connection, the certificate, what the site may do,
    /// what it has stored, what was blocked.
    @objc func showPageSecurity(_ sender: Any?) {
        guard pageSecurity != .none, securityButton.window != nil else { return }
        if let securityPopover, securityPopover.isShown { securityPopover.close(); return }
        let url = isHibernated ? hibernatedURL : shownURL
        let onWarning = isShowingCertificateWarning
        let site = onWarning ? nil : SitePermissions.site(of: url)
        var certificate: CertificateStore.Details?
        if url?.scheme == "https", !onWarning { certificate = CertificateStore.details(of: webView.serverTrust) }
        let content = PageInfoController.Content(
            site: site, name: Self.displayAddress(url), security: pageSecurity, summary: securityButton.toolTip ?? "",
            certificate: certificate, blocked: blocking.blockedCount, blockingOn: blocking.blocker?.isOn == true && !blocking.isOffForSite)
        let controller = PageInfoController(
            content: content,
            permissions: { [weak self] in self?.permissions.stored?() ?? SitePermissions() },
            setPermission: { [weak self] permission, choice in
                guard let self, let site else { return }
                var all = self.permissions.stored?() ?? SitePermissions()
                all.set(choice, for: permission, site: site)
                self.permissions.store?(all)
                NotificationCenter.default.post(name: PermissionsController.didChange, object: nil)
            },
            dataStore: webView.configuration.websiteDataStore,
            host: onWarning ? nil : url?.host(percentEncoded: false)?.lowercased(),
            onCleared: { [weak self] in self?.reload(nil) })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: securityButton.bounds, of: securityButton, preferredEdge: .maxY)
        securityPopover = popover
        pageInfo = controller
    }

    private(set) var pageInfo: PageInfoController?
    private(set) var securityPopover: NSPopover?
    /// Developer aid: what the indicator beside the address says.
    var securityLabel: String { securityButton.isHidden ? "" : (securityButton.toolTip ?? "") }
    var securityTitle: String { securityButton.isHidden ? "" : securityButton.title }
    /// Developer aid: where the address text starts and where the indicator ends, in the field.
    var addressTextStart: CGFloat { addressField.cell?.drawingRect(forBounds: addressField.bounds).minX ?? 0 }
    var securityIndicatorEnd: CGFloat { securityButton.isHidden ? 0 : securityButton.frame.maxX }

    /// Filled when this page is bookmarked.
    func syncStar() {
        let bookmarked = shownURL.flatMap { try? bookmarks?()?.bookmark(for: $0) } != nil
        starButton.image = NSImage(systemSymbolName: bookmarked ? "star.fill" : "star", accessibilityDescription: "Bookmark")?
            .withSymbolConfiguration(.init(paletteColors: [bookmarked ? .systemYellow : .labelColor]))
        starButton.toolTip = bookmarked ? "Edit bookmark (⌘D)" : "Bookmark this page (⌘D)"
        starButton.isEnabled = !(StartPageSchemeHandler.isStartPage(webView.url) || shownURL == nil)
    }

    /// Bookmarks → Add Bookmark… (⌘D), and the star.
    @objc func addBookmark(_ sender: Any?) {
        guard let url = currentURL, !StartPageSchemeHandler.isStartPage(url), let store = bookmarks?() else { return }
        let controller = AddBookmarkController(store: store, url: url, title: window?.title ?? "") { [weak self] in
            self?.onBookmarksChanged?()
        }
        lastBookmarkPopover = controller
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        if starButton.window != nil {
            popover.show(relativeTo: starButton.bounds, of: starButton, preferredEdge: .maxY)
        } else if let content = window?.contentView {
            popover.show(relativeTo: NSRect(x: content.bounds.midX, y: content.bounds.maxY - 4, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
    }
    /// For the self-test.
    private(set) weak var lastBookmarkPopover: AddBookmarkController?
    /// For the self-test.
    weak var lastGroupEditor: GroupEditorController?
    weak var splitDropZone: SplitDropZone?

    /// Bookmarks → Add to Reading List (⇧⌘D): saved with an offline copy.
    @objc func addToReadingList(_ sender: Any?) {
        guard let url = shownURL, url.scheme?.hasPrefix("http") == true, let store = bookmarks?() else { return }
        guard let id = try? store.addToReadingList(url: url, title: webView.title ?? ""),
              let item = try? store.readingList().first(where: { $0.id == id }), let file = readingListArchive?(item) else { return }
        onBookmarksChanged?()
        webView.createWebArchiveData { result in
            if case .success(let data) = result {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
        showNotice("Added to your Reading List, with a copy to read offline.", seconds: 3)
    }

    /// View → Show Favorites Bar (⇧⌘B): every window follows.
    @objc func toggleFavoritesBar(_ sender: Any?) {
        BrowserSettings.showFavoritesBar.toggle()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
    }

    /// Shows or hides the bar to match the setting, with current favorites.
    func syncFavoritesBar() {
        guard let window else { return }
        let attached = window.titlebarAccessoryViewControllers.contains(favoritesBar)
        if BrowserSettings.showFavoritesBar && !attached {
            window.addTitlebarAccessoryViewController(favoritesBar)
        } else if !BrowserSettings.showFavoritesBar, let index = window.titlebarAccessoryViewControllers.firstIndex(of: favoritesBar) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        favoritesBar.reload()
        syncStar()
    }

    // MARK: - History

    private var lastRecordedURL: URL?

    /// The page's title arriving late, and single-page sites that change the
    /// address without loading a page (pushState), both reach history.
    private func observePage() {
        pageObservations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let url = webView.url, title = webView.title ?? ""
                DispatchQueue.main.async {
                    guard let self, !self.isHibernated, let url, !title.isEmpty else { return }
                    self.onTitleChange?(url, title)
                    self.syncChrome()
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let url = webView.url, loading = webView.isLoading
                DispatchQueue.main.async {
                    guard let self, !self.isHibernated, let url, !loading, url != self.lastRecordedURL else { return }
                    self.lastRecordedURL = url
                    // Read now, not when the address changed: a single-page
                    // app sets its title after pushState, and WebKit may
                    // report the two in either order.
                    self.onVisit?(url, self.webView.title ?? "", false)
                    self.syncChrome()
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.syncNavigationButtons() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.syncNavigationButtons() }
            },
            // A page can pull in something unencrypted long after it loaded.
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.syncSecurity() }
            },
        ]
    }

    private func configureNavigationButtons() {
        for (button, symbol, label, action) in [(backButton, "chevron.left", "Back", #selector(goBack(_:))),
                                                (forwardButton, "chevron.right", "Forward", #selector(goForward(_:)))] {
            button.bezelStyle = .toolbar
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.target = self
            button.action = action
            button.toolTip = label + " (hold for history)"
            button.setAccessibilityLabel(label)
        }
        backButton.historyMenu = { [weak self] in self?.historyMenu(back: true) }
        forwardButton.historyMenu = { [weak self] in self?.historyMenu(back: false) }
        syncNavigationButtons()
    }

    private func syncNavigationButtons() {
        backButton.isEnabled = webView.canGoBack || (isHibernated && hibernatedState != nil)
        forwardButton.isEnabled = webView.canGoForward
    }

    /// The tab's own history in one direction, nearest first.
    func historyMenu(back: Bool) -> NSMenu {
        let menu = NSMenu()
        let list = webView.backForwardList
        let items = back ? Array(list.backList.reversed()) : list.forwardList
        for item in items.prefix(25) {
            let entry = NSMenuItem(title: item.title?.isEmpty == false ? item.title! : item.url.absoluteString,
                                   action: #selector(goToHistoryItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item
            entry.toolTip = item.url.absoluteString
            menu.addItem(entry)
        }
        if back {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Show All History", action: #selector(AppDelegate.showHistory(_:)), keyEquivalent: "")
        }
        return menu
    }

    @objc private func goToHistoryItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? WKBackForwardListItem else { return }
        webView.go(to: item)
    }

    // MARK: - Address field

    // MARK: - Address bar suggestions

    /// Not editing: the site, as Safari shows it. Editing: the full address.
    static func displayAddress(_ url: URL?) -> String {
        guard let url, !StartPageSchemeHandler.isStartPage(url) else { return "" }
        guard url.scheme == "http" || url.scheme == "https", let host = url.host() else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var completionText = ""

    private func addressFieldDidFocus() {
        guard !isHibernated || hibernatedURL != nil else { return }
        let url = currentURL
        addressField.stringValue = StartPageSchemeHandler.isStartPage(url) ? "" : url?.absoluteString ?? ""
        typedAddress = addressField.stringValue
        DispatchQueue.main.async { [weak self] in self?.addressField.currentEditor()?.selectAll(nil) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === addressField, let editor = addressField.currentEditor() as? NSTextView else { return }
        let text = editor.string
        // Deleting (⌫ removes the completion first) never completes again.
        let deleting = typedAddress.hasPrefix(text) && text.count < typedAddress.count
        typedAddress = text
        completionURL = nil
        completionText = ""
        let sources = addressSources?(text) ?? AddressSources()
        if !deleting, editor.selectedRange().location == (text as NSString).length,
           let completion = SuggestionRanker.completion(for: text, candidates: sources.history + sources.bookmarks) {
            let start = (text as NSString).length
            editor.replaceCharacters(in: NSRange(location: start, length: 0), with: completion.text)
            editor.setSelectedRange(NSRange(location: start, length: (completion.text as NSString).length))
            completionURL = completion.url
            completionText = completion.text
        }
        showSuggestions(for: text, sources: sources)
        fetchSearchSuggestions(for: text)
    }

    private func showSuggestions(for text: String, sources: AddressSources) {
        let items = SuggestionRanker.rank(query: text, tabs: sources.tabs.filter { $0.id != tab.description }, bookmarks: sources.bookmarks,
                                          history: sources.history, searches: searchSuggestions, engine: BrowserSettings.searchEngine)
        if text.trimmingCharacters(in: .whitespaces).isEmpty { suggestionsPanel.hide() } else { suggestionsPanel.show(items, below: addressField) }
    }

    /// The engine's suggestions, a moment after typing pauses. Never sent
    /// when switched off, and only for what was typed, not a completion.
    private func fetchSearchSuggestions(for text: String) {
        suggestTask?.cancel()
        searchSuggestions = []
        let query = text.trimmingCharacters(in: .whitespaces)
        guard let url = suggestionsURL(for: query) else { return }
        suggestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 3
            guard let (data, _) = try? await Self.suggestSession.data(for: request), !Task.isCancelled,
                  self.typedAddress == text else { return }
            self.searchSuggestions = Array(SearchEngine.parseSuggestions(data).prefix(4))
            if self.isEditingAddress { self.showSuggestions(for: text, sources: self.addressSources?(text) ?? AddressSources()) }
        }
    }

    /// Where the engine's suggestions for these words would be asked for;
    /// nil when they must not be: switched off, a private window, or what
    /// was typed is an address, which is nobody's business but the site's.
    func suggestionsURL(for query: String) -> URL? {
        guard BrowserSettings.searchSuggestions, !isPrivate, !query.isEmpty, AddressResolver.address(query) == nil || !query.contains(".") else { return nil }
        return BrowserSettings.searchEngine.suggestURL(for: query)
    }

    /// No cookies, no cache: suggestions are not tied to a sign-in.
    private static let suggestSession = URLSession(configuration: .ephemeral)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === addressField else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            suggestionsPanel.move(by: 1)
            return suggestionsPanel.isVisible
        case #selector(NSResponder.moveUp(_:)):
            suggestionsPanel.move(by: -1)
            return suggestionsPanel.isVisible
        case #selector(NSResponder.insertNewline(_:)):
            if let chosen = suggestionsPanel.selected { choose(chosen) } else { navigate(nil) }
            return true
        case #selector(NSResponder.insertTab(_:)):
            // ⇥ accepts the inline completion, as in Safari.
            let range = textView.selectedRange()
            guard range.length > 0, range.location + range.length == (textView.string as NSString).length else { return false }
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            typedAddress = textView.string
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if suggestionsPanel.isVisible {
                suggestionsPanel.hide()
                textView.string = typedAddress
                completionURL = nil
            } else {
                addressField.stringValue = Self.displayAddress(shownURL)
                shownWindow?.makeFirstResponder(webView)
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)) where NSApp.currentEvent?.modifierFlags.contains(.shift) == true:
            // ⇧⌫ on a history suggestion forgets it.
            guard let chosen = suggestionsPanel.selected, chosen.kind == .history else { return false }
            removeFromHistory?(chosen.url)
            showSuggestions(for: typedAddress, sources: addressSources?(typedAddress) ?? AddressSources())
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === addressField else { return }
        suggestionsPanel.hide()
        if !isHibernated { addressField.stringValue = Self.displayAddress(shownURL) }
    }

    private func choose(_ suggestion: AddressSuggestion) {
        suggestionsPanel.hide()
        switch suggestion.kind {
        case .switchToTab(let id):
            addressField.stringValue = Self.displayAddress(shownURL)
            shownWindow?.makeFirstResponder(webView)
            switchToTab?(id)
        case .search:
            load(suggestion.url)
            shownWindow?.makeFirstResponder(webView)
        case .bookmark, .history:
            typedNavigation = true
            load(suggestion.url)
            shownWindow?.makeFirstResponder(webView)
        }
    }

    /// The clipboard Paste and Go reads. The self-test swaps in its own, so
    /// a test run never touches what the person has copied.
    var pasteboard = NSPasteboard.general

    /// Edit → Paste and Go (⇧⌘V): the clipboard as an address, or a search.
    @objc func pasteAndGo(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string), let url = BrowserSettings.destination(for: text) else { return }
        typedNavigation = true
        load(url)
        shownWindow?.makeFirstResponder(webView)
    }

    /// Developer aid: types into the address bar as a person would, one
    /// edit notification per call, with the field focused.
    func typeInAddressBar(_ text: String) {
        shownWindow?.makeFirstResponder(addressField)
        guard let editor = addressField.currentEditor() as? NSTextView else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: addressField))
    }

    /// Developer aid, for the self-test.
    var suggestionTitles: [String] { suggestionsPanel.titles }
    var suggestionKinds: [AddressSuggestion.Kind] { suggestionsPanel.suggestions.map(\.kind) }
    var addressEditorText: String { (addressField.currentEditor() as? NSTextView)?.string ?? addressField.stringValue }
    /// Developer aid: ⇧⌫ on the selected suggestion.
    func removeSelectedSuggestionForTest() {
        guard let chosen = suggestionsPanel.selected, chosen.kind == .history else { return }
        removeFromHistory?(chosen.url)
        showSuggestions(for: typedAddress, sources: addressSources?(typedAddress) ?? AddressSources())
    }

    func pressInAddressBar(_ selector: Selector) {
        guard let editor = addressField.currentEditor() as? NSTextView else { return }
        _ = control(addressField, textView: editor, doCommandBy: selector)
    }

    private func configureAddressField() {
        addressField.delegate = self
        addressField.onFocus = { [weak self] in self?.addressFieldDidFocus() }
        suggestionsPanel.onChoose = { [weak self] suggestion in self?.choose(suggestion) }
        addressField.placeholderString = "Search or enter website name"
        addressField.usesSingleLineMode = true
        addressField.lineBreakMode = .byTruncatingTail
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: NSFont.systemFontSize)
        addressField.target = self
        addressField.action = #selector(navigate(_:))
        // Only navigate on Return, not when focus merely leaves the field.
        (addressField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false

        addressField.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = addressField.widthAnchor.constraint(equalToConstant: 720)
        preferredWidth.priority = .defaultLow
        addressWidth = preferredWidth
        NSLayoutConstraint.activate([
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 196),
            preferredWidth,
        ])
    }

    private var addressWidth: NSLayoutConstraint?

    /// The toolbar takes the address field's preferred width as the width
    /// it must have, and moves buttons into the overflow menu to make room.
    /// So the preferred width is what the other items leave, and it is the
    /// address that gives way when the window narrows or a button appears.
    func fitAddressField() {
        // Beside another tab in a split, the toolbar is in that tab's window.
        guard let window = addressField.window ?? window, let toolbar = window.toolbar, let addressWidth else { return }
        var others: CGFloat = 0
        for item in toolbar.items where item.itemIdentifier != .address && item.itemIdentifier != .flexibleSpace && !item.isHidden {
            // Buttons made from an image have no view; they are as wide as a toolbar button.
            others += (item.view.map { max($0.fittingSize.width, 28) } ?? 28) + 16
        }
        // The window's own buttons, and the margins at both ends.
        let available = window.frame.width - others - 110
        let width = max(196, min(860, available))
        if abs(addressWidth.constant - width) > 0.5 { addressWidth.constant = width }
    }

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        fitAddressField()
    }

    /// Developer aid: whether a toolbar item is hidden, by identifier.
    func toolbarItemIsHidden(_ identifier: String) -> Bool {
        window?.toolbar?.items.first { $0.itemIdentifier.rawValue == identifier }?.isHidden ?? true
    }

    /// Developer aid: toolbar buttons that did not fit and went to the overflow menu.
    var overflowingToolbarItems: [String] {
        guard let toolbar = window?.toolbar else { return [] }
        let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        return toolbar.items.filter { !$0.isHidden && !visible.contains($0.itemIdentifier) }.map(\.itemIdentifier.rawValue)
    }

    var isEditingAddress: Bool {
        guard let editor = addressField.currentEditor() else { return false }
        return shownWindow?.firstResponder === editor
    }

    private func syncChrome() {
        // A sleeping tab shows the page it will wake to, not the blank one.
        if isHibernated { return }
        updateHandoff()
        syncNavigationButtons()
        syncStar()
        syncSecurity()
        if !isEditingAddress {
            // The start page is the browser's own: the address bar stays
            // empty and ready for typing, as on a new tab everywhere.
            addressField.stringValue = Self.displayAddress(shownURL)
        }
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        let resolved = title ?? shownURL?.host() ?? (isPrivate ? "Private" : "SimpleBrowser")
        window?.title = resolved
        recorderPanel?.update(title: resolved)
        devToolsWindow?.title = "DevTools — \(resolved)"
        fitAddressField()
        window?.toolbar?.validateVisibleItems()
        let listed = resolved + (currentURL?.absoluteString ?? "")
        if listed != listedAs {
            listedAs = listed
            organizer?.changed()
            extensions?.didChange(self)
        }
    }

    // MARK: - Translate

    private func configureTranslateButton() {
        translateButton.bezelStyle = .toolbar
        translateButton.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Translate")
        translateButton.target = self
        translateButton.action = #selector(showTranslateMenu(_:))
        translateButton.setAccessibilityLabel("Translate")
        syncTranslateItem()
    }

    /// Tinted when there is something to do: the page is in another
    /// language, or it is showing a translation.
    private func syncTranslateItem() {
        let active = translator.isTranslated || translator.suggestsTranslation
        var color: NSColor? = active ? .controlAccentColor : nil
        if case .failed = translator.state { color = .systemOrange }
        // Coloured through the symbol: a toolbar button's tint does not
        // reliably reach a template image.
        let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: "Translate")
        translateButton.image = color.map { symbol?.withSymbolConfiguration(.init(paletteColors: [$0])) } ?? symbol
        translateButton.toolTip = TranslateMenu.statusLine(for: translator) ?? "Translate this page with Google Translate"
    }

    @objc func showTranslateMenu(_ sender: Any?) {
        let menu = buildTranslateMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: translateButton.bounds.height + 4), in: translateButton)
    }

    private func buildTranslateMenu() -> NSMenu {
        let menu = NSMenu(title: "Translate")
        for item in TranslateMenu.items(for: translator, target: self) { menu.addItem(item) }
        lastTranslateMenuTitles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        return menu
    }

    /// Developer aid: builds the menu the button shows, without the modal pop-up.
    func showTranslateMenuForTest() { _ = buildTranslateMenu() }

    /// Developer aid, for the self-tests.
    var pageView: BrowserWebView? { webView }

    /// Developer aid: what the address bar shows.
    var addressText: String { addressField.stringValue }
    /// Developer aid: whether the star says "bookmarked".
    var isStarFilled: Bool { starButton.toolTip?.hasPrefix("Edit") == true }

    /// Developer aid: types into the address bar and presses Return.
    func enterAddress(_ text: String) {
        addressField.stringValue = text
        navigate(nil)
    }
    /// For the self-test.
    private(set) var lastTranslateMenuTitles: [String] = []

    /// View → Translate to …, and the Translate menus' language items.
    @objc func translatePageTo(_ sender: Any?) {
        let code = (sender as? NSMenuItem)?.representedObject as? String
        let language = code.flatMap(TranslationLanguage.matching) ?? PageTranslator.target
        TranslateMenu.noteUsed(language)
        translator.translate(to: language)
    }

    @objc func showOriginalPage(_ sender: Any?) { translator.showOriginal() }

    @objc func toggleAlwaysTranslate(_ sender: Any?) {
        guard let code = (sender as? NSMenuItem)?.representedObject as? String else { return }
        TranslateActions.toggleAlwaysTranslate(code, translator: translator)
    }

    // MARK: - Profile

    private func configureProfileButton() {
        profileButton.bezelStyle = .toolbar
        profileButton.imagePosition = .imageLeading
        profileButton.target = self
        profileButton.action = #selector(showProfilesMenu(_:))
        profileButton.setContentHuggingPriority(.required, for: .horizontal)
        syncProfileItem()
    }

    private func syncProfileItem() {
        profileButton.title = profile.name
        profileButton.image = ProfileBadge.image(for: profile)
        profileButton.toolTip = "Browsing as “\(profile.name)”. Click to switch profile or add one."
        profileButton.setAccessibilityLabel("Profile: \(profile.name)")
    }

    @objc func showProfilesMenu(_ sender: Any?) {
        let menu = NSMenu(title: "Profiles")
        menu.delegate = profilesMenuFiller
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: profileButton.bounds.height + 4), in: profileButton)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        observeSelection()
        lastActive = Date()
        wake()
        onBecomeKey?()
        sidebar?.reloadIfStale()
    }

    /// A tab shown by any means (selected, merged, its window brought
    /// forward, even with the app in the background) wakes.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        observeSelection()
        guard window?.occlusionState.contains(.visible) == true else { return }
        lastActive = Date()
        wake()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        lastActive = Date()
        cacheSnapshot()
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === devToolsWindow {
            hideDevTools()
            return
        }
        onTabClosed?(currentURL, interactionState as? Data, isHibernated ? hibernatedTitle : window?.title ?? "")
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        magnifyMonitor = nil
        recorderPanel?.close()
        devToolsWindow?.close()
        devTools?.tearDown()
        passwordCoordinator.uninstall()
        autofill.uninstall()
        media.uninstall()
        if let mediaObserver { NotificationCenter.default.removeObserver(mediaObserver) }
        blocking.tearDown()
        if let downloadsObserver { NotificationCenter.default.removeObserver(downloadsObserver) }
        if let sidebarObserver { NotificationCenter.default.removeObserver(sidebarObserver) }
        if let extensionsObserver { NotificationCenter.default.removeObserver(extensionsObserver) }
        extensions?.didClose(self)
        organizer?.changed()
        downloadsPopover?.close()
        permissions.tearDown()
        reader.uninstall()
        translator.uninstall()
        contextMenu.uninstall()
        bridge.uninstall()
        onClose?()
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectUserAgent(_:)):
            menuItem.state = menuItem.tag == userAgentIndex ? .on : .off
        case #selector(toggleDevTools(_:)):
            menuItem.title = isDevToolsVisible ? "Hide Developer Tools" : "Show Developer Tools"
        case #selector(dockDevTools(_:)):
            let current = devTools?.dockSide ?? UserDefaults.standard.string(forKey: "devtools.dockSide") ?? "bottom"
            menuItem.state = (menuItem.representedObject as? String) == current ? .on : .off
        case #selector(translatePageTo(_:)) where menuItem.representedObject == nil:
            // View → Translate Page: names the language it will use.
            menuItem.title = "Translate to \(PageTranslator.target.name)"
            return !translator.optedOut && webView.url != nil
        case #selector(showOriginalPage(_:)):
            return translator.isTranslated
        case #selector(toggleReader(_:)):
            menuItem.title = reader.isActive ? "Hide Reader" : "Show Reader"
            return reader.isActive || reader.isAvailable
        case #selector(zoomIn(_:)):
            return webView.pageZoom < (PageZoom.steps.last ?? 5) - 0.001
        case #selector(zoomOut(_:)):
            return webView.pageZoom > (PageZoom.steps.first ?? 0.25) + 0.001
        case #selector(zoomReset(_:)):
            return !PageZoom.isDefault(webView.pageZoom)
        case #selector(findNextInPage(_:)), #selector(findPreviousInPage(_:)):
            return webView.url != nil
        case #selector(pasteAndGo(_:)):
            // Says what it will do with what is on the clipboard.
            let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            menuItem.title = text.isEmpty || AddressResolver.address(text) != nil ? "Paste and Go" : "Paste and Search"
            return !text.isEmpty
        case #selector(toggleFavoritesBar(_:)):
            menuItem.title = BrowserSettings.showFavoritesBar ? "Hide Favorites Bar" : "Show Favorites Bar"
        case #selector(toggleBrowserSidebar(_:)):
            menuItem.title = BrowserSettings.sidebarShown ? "Hide Sidebar" : "Show Sidebar"
        case #selector(openInSplitView(_:)):
            return !isInSplit
        case #selector(closeSplitView(_:)):
            return isInSplit
        case #selector(togglePinTab(_:)):
            menuItem.title = isPinned ? "Unpin Tab" : "Pin Tab"
        case #selector(removeTabFromGroup(_:)):
            return groupID != nil
        case #selector(toggleMuteTab(_:)):
            menuItem.title = media.isMuted ? "Unmute Tab" : "Mute Tab"
            return media.isAudible || media.isMuted
        case #selector(togglePictureInPicture(_:)):
            menuItem.title = media.isPictureInPicture ? "Exit Picture in Picture" : "Enter Picture in Picture"
            return media.hasVideo
        case #selector(addBookmark(_:)), #selector(addToReadingList(_:)):
            return currentURL.map { $0.scheme?.hasPrefix("http") == true } ?? false
        default:
            break
        }
        return true
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .back, .forward, .reload, .home, .address, .capture, .reader, .readerAppearance, .zoom, .shield, .star, .translate, .pictureInPicture, .extensions, .passwords, .downloads, .nowPlaying, .flexibleSpace, .devTools]
            + (isPrivate ? [.privateBadge] : []) + [.profile]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .pictureInPicture:
            let item = button(identifier, symbol: "pip.enter", label: "Picture in Picture", action: #selector(togglePictureInPicture(_:)))
            item.toolTip = "Play the video in a window of its own, over everything"
            item.isHidden = !media.hasVideo
            pictureInPictureItem = item
            return item
        case .nowPlaying:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = nowPlaying
            item.label = "Now Playing"
            nowPlayingItem = item
            item.isHidden = true
            return item
        case .extensions:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = extensionButtons
            item.label = "Extensions"
            extensionsItem = item
            syncExtensionButtons()
            return item
        case .sidebar:
            let item = button(identifier, symbol: "sidebar.left", label: "Sidebar", action: #selector(toggleBrowserSidebar(_:)))
            item.toolTip = "Show or hide the sidebar (⇧⌘S)"
            return item
        case .back:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = backButton
            item.label = "Back"
            return item
        case .forward:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = forwardButton
            item.label = "Forward"
            return item
        case .reload:
            return button(identifier, symbol: "arrow.clockwise", label: "Reload", action: #selector(reload(_:)))
        case .home:
            let item = button(identifier, symbol: "house", label: "Home", action: #selector(goHome(_:)))
            item.toolTip = "Go to your homepage (⇧⌘H). Change it in Settings (⌘,)."
            return item
        case .passwords:
            let item = button(identifier, symbol: "key", label: "Passwords", action: #selector(showSitePasswords(_:)))
            passwordsItem = item
            syncPasswordsItem()
            return item
        case .devTools:
            let item = button(identifier, symbol: "wrench.and.screwdriver", label: "Developer Tools",
                              action: #selector(toggleDevTools(_:)))
            item.toolTip = "Toggle Developer Tools (⌥⌘I)"
            return item
        case .privateBadge:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = PrivateBadge.view()
            item.label = "Private"
            item.visibilityPriority = .high
            privateItem = item
            return item
        case .profile:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = profileButton
            item.label = "Profile"
            item.visibilityPriority = .high
            return item
        case .downloads:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = downloadsButton
            item.label = "Downloads"
            item.isHidden = true
            downloadsItem = item
            syncDownloads()
            return item
        case .capture:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = permissions.captureButton
            item.label = "Camera and Microphone"
            item.visibilityPriority = .high
            captureItem = item
            syncCapture()
            return item
        case .reader:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = reader.button
            item.label = "Reader"
            readerItem = item
            syncReader()
            return item
        case .readerAppearance:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = reader.appearanceButton
            item.label = "Reader Appearance"
            readerAppearanceItem = item
            syncReader()
            return item
        case .zoom:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = zoomButton
            item.label = "Zoom"
            zoomItem = item
            syncZoom()
            return item
        case .shield:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = blocking.button
            item.label = "Content Blocking"
            return item
        case .star:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = starButton
            item.label = "Bookmark"
            return item
        case .translate:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = translateButton
            item.label = "Translate"
            return item
        case .address:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = addressField
            item.label = "Address"
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    // MARK: - NSToolbarItemValidation

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .back:    return webView.canGoBack
        case .forward: return webView.canGoForward
        default:       return true
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        recordNavigation(.started)
        syncChrome()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        recordNavigation(.redirected)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, url.absoluteString != "about:blank" { errorPageURL = nil }
        recordNavigation(.committed)
        media.didCommitNavigation()
        applyZoomForPage()
        downloadsFromPage = 0
        permissions.didCommitNavigation()
        reader.didCommitNavigation()
        finder.didCommitNavigation()
        blocking.didCommit()
        passwordCoordinator.didCommitNavigation()
        translator.didCommitNavigation()
        syncChrome()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageFinishedCount += 1
        if !isHibernated { hideSnapshot() }
        if !isHibernated, let url = webView.url {
            onVisit?(url, webView.title ?? "", typedNavigation)
            lastRecordedURL = url
        }
        typedNavigation = false
        recordNavigation(.finished)
        reader.didFinishNavigation()
        passwordCoordinator.didFinishNavigation()
        syncChrome()
        loadFavicon()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        handle(error)
    }

    /// The one place WebKit hands the app a real HTTP response: status and
    /// headers for the main document and for frames. Recorded as its own
    /// source; the network log merges it with the agent's timing entry.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, let url = http.url {
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            recorder.record(.network(NetworkEvent(
                source: .navigationDelegate,
                url: url,
                initiator: navigationResponse.isForMainFrame ? "navigation" : "iframe",
                statusCode: http.statusCode,
                responseHeaders: headers,
                bodyUnavailable: true
            )), tab: tab)
        }
        // A file the page hands over rather than shows goes to Downloads.
        var isDownload = navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType
        if let http = navigationResponse.response as? HTTPURLResponse,
           (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") {
            isDownload = true
        }
        guard isDownload else { return .allow }
        return await allowsDownload(userInitiated: lastActionWasUserInitiated) ? .download : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let userInitiated = navigationAction.responds(to: NSSelectorFromString("_isUserInitiated"))
            ? (navigationAction.value(forKey: "_isUserInitiated") as? Bool ?? true) : true
        lastActionWasUserInitiated = userInitiated
        // `<a download>`.
        if navigationAction.shouldPerformDownload {
            return await allowsDownload(userInitiated: userInitiated) ? .download : .cancel
        }
        // Whether this tab's requests are filtered goes by the site of the
        // page it shows, decided as that page starts to load.
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url {
            await blocking.blocker?.waitUntilLookedUp()
            blocking.willNavigate(to: url)
        }
        // The warning page's two buttons. Listened to on a warning page only.
        if let action = WarningPage.action(of: navigationAction.request.url) {
            if isShowingCertificateWarning, navigationAction.targetFrame?.isMainFrame == true {
                DispatchQueue.main.async { [weak self] in self?.perform(action) }
            }
            return .cancel
        }
        // The start page's search box: only the start page may use it, so a
        // web page cannot make the browser search or navigate through it.
        if let text = StartPageSchemeHandler.searchText(from: navigationAction.request.url) {
            // Judged by the page that is showing. Not by `sourceFrame`:
            // measured, after an app-initiated load its request and its
            // security origin still name the page that was showing before.
            if StartPageSchemeHandler.isStartPage(webView.url), navigationAction.sourceFrame.isMainFrame,
               navigationAction.targetFrame?.isMainFrame == true, let url = BrowserSettings.destination(for: text) {
                // Once this navigation is out of the way: a load started
                // while WebKit is still deciding it can be cancelled with it.
                DispatchQueue.main.async { [weak self] in
                    self?.typedNavigation = true
                    self?.load(url)
                }
            }
            return .cancel
        }
        // ⌘-click or a middle click on a link: a tab behind this one, or in
        // front with ⇧ as well, as in Safari and Chrome.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2 {
            openInNewTab?(url, navigationAction.modifierFlags.contains(.shift))
            return .cancel
        }
        return .allow
    }

    /// WebKit tells its navigation delegate what a content rule list did to
    /// a load. Private API, found by name: where it is missing nothing calls
    /// this, and the shield shows no count.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard webView === self.webView, action.responds(to: NSSelectorFromString("blockedLoad")),
              action.value(forKey: "blockedLoad") as? Bool == true else { return }
        blocking.didBlock(url)
        recorder.record(.network(NetworkEvent(
            source: .navigationDelegate, url: url, initiator: "blocked",
            bodyUnavailable: true, failure: "Blocked by content blocking"
        )), tab: tab)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.adopt(download)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recorder.record(.console(ConsoleEntry(
            level: .error, message: "Web content process terminated; reloading."
        )), tab: tab)
        webView.reload()
    }

    private func recordNavigation(_ phase: NavigationEvent.Phase, url: URL? = nil, detail: String? = nil) {
        guard let url = url ?? webView.url else { return }
        recorder.record(.navigation(NavigationEvent(url: url, phase: phase, detail: detail)), tab: tab)
    }

    private func handle(_ error: any Error) {
        let nsError = error as NSError
        // A user-initiated cancel or a superseding navigation is not a failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }

        let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
        recordNavigation(.failed, url: failedURL ?? webView.url, detail: error.localizedDescription)

        // Offline, a reading-list page opens from its saved copy.
        let offline = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                       NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorDNSLookupFailed]
        if nsError.domain == NSURLErrorDomain, offline.contains(nsError.code), let failedURL,
           let item = try? bookmarks?()?.readingItem(for: failedURL), let file = readingListArchive?(item),
           FileManager.default.fileExists(atPath: file.path) {
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            showNotice("You’re offline. This is the copy saved in your Reading List.")
            return
        }

        if let failedURL, showCertificateWarning(for: failedURL, error: nsError) { return }

        let failedURLString = failedURL?.absoluteString ?? ""
        let explanation = ErrorPage.explanation(domain: nsError.domain, code: nsError.code, host: failedURL?.host(percentEncoded: false))
        errorPageURL = failedURL
        webView.loadHTMLString(ErrorPage.html(explanation: explanation, url: failedURLString, detail: error.localizedDescription), baseURL: nil)
        syncChrome()
        if !isEditingAddress { addressField.stringValue = failedURLString }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - WKUIDelegate

    /// `target="_blank"` and `window.open`: a new tab, returned to WebKit
    /// so the page keeps `window.opener` and the pop-up can report back.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Whether the person did something to open it (a click, a key) is
        // WebKit's to know. Private, read by name; where it cannot be read,
        // nothing is held back.
        let userInitiated = navigationAction.responds(to: NSSelectorFromString("_isUserInitiated"))
            ? (navigationAction.value(forKey: "_isUserInitiated") as? Bool ?? true) : true
        guard permissions.allowsPopup(to: navigationAction.request.url, userInitiated: userInitiated) else { return nil }
        if let popup = onPopup?(configuration, navigationAction) { return popup }
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// A page asking for the camera, the microphone, or both.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        let wanted: [SitePermission]
        switch type {
        case .camera: wanted = [.camera]
        case .microphone: wanted = [.microphone]
        case .cameraAndMicrophone: wanted = [.camera, .microphone]
        @unknown default: wanted = [.camera, .microphone]
        }
        return await permissions.request(wanted, requester: origin) ? .grant : .deny
    }

    /// A page asking where the person is. Private API, found by name.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (Bool) -> Void) {
        permissions.request([.location], requester: origin, answer: decisionHandler)
    }

    /// A pop-up calling `window.close()`, as sign-in windows do when finished.
    func webViewDidClose(_ webView: WKWebView) {
        window?.performClose(nil)
    }

    /// For the pop-up path in the app delegate.
    var pageWebView: WKWebView { webView }
}

private extension NSToolbarItem.Identifier {
    static let back     = NSToolbarItem.Identifier("back")
    static let forward  = NSToolbarItem.Identifier("forward")
    static let reload   = NSToolbarItem.Identifier("reload")
    static let home     = NSToolbarItem.Identifier("home")
    static let address  = NSToolbarItem.Identifier("address")
    static let passwords = NSToolbarItem.Identifier("passwords")
    static let devTools = NSToolbarItem.Identifier("devtools")
    static let profile  = NSToolbarItem.Identifier("profile")
    static let translate = NSToolbarItem.Identifier("translate")
    static let star = NSToolbarItem.Identifier("star")
    static let shield = NSToolbarItem.Identifier("shield")
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let reader = NSToolbarItem.Identifier("reader")
    static let capture = NSToolbarItem.Identifier("capture")
    static let downloads = NSToolbarItem.Identifier("downloads")
    static let sidebar = NSToolbarItem.Identifier("sidebar")
    static let extensions = NSToolbarItem.Identifier("extensions")
    static let pictureInPicture = NSToolbarItem.Identifier("pictureInPicture")
    static let nowPlaying = NSToolbarItem.Identifier("nowPlaying")
    static let privateBadge = NSToolbarItem.Identifier("private")
    static let readerAppearance = NSToolbarItem.Identifier("readerAppearance")
}
