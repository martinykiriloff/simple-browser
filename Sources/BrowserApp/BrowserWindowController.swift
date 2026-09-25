import AppKit
import WebKit
import BrowserKit
import InspectKit

/// One window, one profile, one live web view. Tabs, groups and hibernation
/// come later; this is the smallest shell that makes the package a runnable app.
@MainActor
final class BrowserWindowController: NSWindowController,
                                     NSWindowDelegate,
                                     NSToolbarDelegate,
                                     NSToolbarItemValidation,
                                     NSMenuItemValidation,
                                     WKNavigationDelegate,
                                     WKUIDelegate {

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

    private let webView: BrowserWebView
    private let addressField = NSTextField()
    private let splitView = NSSplitView()
    private let pageContainer = NSView()
    private var fillConstraints: [NSLayoutConstraint] = []
    private var deviceConstraints: [NSLayoutConstraint] = []
    /// Device-mode state as the DevTools UI sent it; nil when off.
    private(set) var emulation: [String: Any]?

    // Dev tools. The recorder starts with the tab, not with the panel.
    private let tab = TabID()
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
    private weak var passwordsItem: NSToolbarItem?

    init(profile: Profile, recorder: InspectorRecorder, passwords: PasswordService) {
        self.profile = profile
        self.recorder = recorder
        self.bridge = InspectorBridge(recorder: recorder, tab: tab)
        self.passwordCoordinator = PasswordCoordinator(service: passwords)

        let configuration = WKWebViewConfiguration()
        // Per-profile isolation at the WebKit level. Never `.default()`.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.dataStoreIdentifier)
        // Keeps the `_inspector` object alive for the WebKit-inspector menu item.
        WebInspectorSPI.enableDeveloperExtras(on: configuration)
        WebInspectorSPI.keepDebuggableWhenHidden(configuration)
        // Agent scripts and message handlers must exist before the first document.
        bridge.install(into: configuration)
        passwordCoordinator.install(into: configuration)
        webView = BrowserWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "SimpleBrowser"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
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
        window.contentView = splitView

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Always shippable per ARCHITECTURE.md: "Debug in Safari" is the escape hatch.
        webView.isInspectable = true
        webView.onInspectElement = { [weak self] point in
            guard let self else { return }
            self.showDevTools(panel: "elements")
            self.devTools?.inspectElement(atPagePoint: point)
        }
        bridge.onAuxiliaryMessage = { [weak self] kind, body, _ in
            self?.devTools?.handleAuxiliary(kind: kind, body: body)
        }

        passwordCoordinator.webView = webView
        passwordCoordinator.anchorItem = { [weak self] in self?.passwordsItem }
        passwordCoordinator.onStateChange = { [weak self] in self?.syncPasswordsItem() }
        passwordCoordinator.onManage = {
            NSApp.sendAction(#selector(AppDelegate.showPasswords(_:)), to: nil, from: nil)
        }

        configureAddressField()
        configureProfileButton()

        let toolbar = NSToolbar(identifier: "BrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // F12 toggles DevTools, as in Chrome. Menu key equivalents cover the rest.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 111 else { return event }
            self.toggleDevTools(nil)
            return nil
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

    func showWindowAndFocusAddress() {
        showWindow(nil)
        focusAddressBar(nil)
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    // MARK: - Actions (reached via menu key equivalents and toolbar buttons)

    @objc func navigate(_ sender: Any?) {
        guard let url = AddressResolver.resolve(addressField.stringValue) else { return }
        load(url)
        window?.makeFirstResponder(webView)
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
        window?.makeFirstResponder(webView)
    }

    /// Developer aid: run a script in the page, as the page. The self-tests
    /// use it to act as the person at the keyboard.
    func evaluateInPage(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Developer aid: put keyboard focus in the page, as a click into it would.
    func focusPage() { window?.makeFirstResponder(webView) }

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
    var currentURL: URL? { webView.url }

    @objc func focusAddressBar(_ sender: Any?) {
        window?.makeFirstResponder(addressField)
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
        if devToolsWindow == nil { window?.makeFirstResponder(tools.view) }
    }

    private func hideDevTools() {
        guard let tools = devTools else { return }
        detach(tools)
        isDevToolsVisible = false
        tools.didHide()
        window?.makeFirstResponder(webView)
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

    private(set) lazy var protocolBridge = InspectorProtocolBridge(page: webView)

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

    // MARK: - Address field

    private func configureAddressField() {
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
        NSLayoutConstraint.activate([
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            preferredWidth,
        ])
    }

    private var isEditingAddress: Bool {
        guard let editor = addressField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    private func syncChrome() {
        if !isEditingAddress {
            addressField.stringValue = webView.url?.absoluteString ?? ""
        }
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        let resolved = title ?? webView.url?.host() ?? "SimpleBrowser"
        window?.title = resolved
        recorderPanel?.update(title: resolved)
        devToolsWindow?.title = "DevTools — \(resolved)"
        window?.toolbar?.validateVisibleItems()
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
        if (notification.object as? NSWindow) === window { onBecomeKey?() }
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === devToolsWindow {
            hideDevTools()
            return
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recorderPanel?.close()
        devToolsWindow?.close()
        devTools?.tearDown()
        passwordCoordinator.uninstall()
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
        default:
            break
        }
        return true
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .reload, .home, .address, .passwords, .flexibleSpace, .devTools, .profile]
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
        case .back:
            return button(identifier, symbol: "chevron.left", label: "Back", action: #selector(goBack(_:)))
        case .forward:
            return button(identifier, symbol: "chevron.right", label: "Forward", action: #selector(goForward(_:)))
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
        case .profile:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = profileButton
            item.label = "Profile"
            item.visibilityPriority = .high
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
        recordNavigation(.committed)
        passwordCoordinator.didCommitNavigation()
        syncChrome()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordNavigation(.finished)
        passwordCoordinator.didFinishNavigation()
        syncChrome()
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
        return .allow
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

        let failedURLString = failedURL?.absoluteString ?? ""
        let html = """
        <!doctype html><meta charset="utf-8">
        <style>body{font:15px -apple-system,system-ui;color:#333;margin:15vh auto;max-width:36em;padding:0 1em}
        h1{font-size:1.3em}code{word-break:break-all}</style>
        <h1>This page could not be loaded</h1>
        <p>\(Self.escape(error.localizedDescription))</p>
        <p><code>\(Self.escape(failedURLString))</code></p>
        """
        webView.loadHTMLString(html, baseURL: nil)
        syncChrome()
        if !isEditingAddress { addressField.stringValue = failedURLString }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - WKUIDelegate

    /// `target="_blank"` and `window.open` land in the same web view for now.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
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
}
