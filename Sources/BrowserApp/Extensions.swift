import AppKit
import WebKit
import BrowserKit

/// An extension installed in the app, and what each profile lets it do.
/// Its files are copied in when it is added, so it does not depend on
/// where it came from staying where it was.
struct InstalledExtension: Codable, Equatable {
    struct InProfile: Codable, Equatable {
        var enabled = true
        var access = ExtensionSiteAccess.allRequested
        /// What was agreed to when it was added: its permissions, by name.
        var permissions: [String] = []
    }
    let id: String
    var name: String
    var version: String
    var folder: String
    var profiles: [String: InProfile] = [:]

    func isEnabled(in profile: Profile) -> Bool { profiles[profile.id.description]?.enabled == true }
}

/// Every installed extension, in a folder of their own with a list beside them.
@MainActor
final class ExtensionStore {
    static let didChange = Notification.Name("ExtensionStore.didChange")

    let directory: URL
    private(set) var installed: [InstalledExtension] = []
    /// Asks the person, in plain words, before an extension is added.
    var confirmInstall: (_ name: String, _ lines: [String]) async -> Bool = ExtensionStore.askToInstall

    enum InstallError: LocalizedError {
        case notAnExtension(String)
        case declined
        var errorDescription: String? {
            switch self {
            case .notAnExtension(let why): return "That is not an extension Keel can use: \(why)"
            case .declined: return "Not added."
            }
        }
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listFile) { installed = (try? JSONDecoder().decode([InstalledExtension].self, from: data)) ?? [] }
    }

    private var listFile: URL { directory.appendingPathComponent("Extensions.json") }

    func folder(of item: InstalledExtension) -> URL { directory.appendingPathComponent(item.folder, isDirectory: true) }

    private func save() {
        if let data = try? JSONEncoder().encode(installed) { try? data.write(to: listFile, options: .atomic) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Adds an extension from a folder, a .zip or a .crx, for `profile`,
    /// once the person has agreed to what it asks for.
    @discardableResult
    func install(from source: URL, for profile: Profile) async throws -> InstalledExtension {
        let id = UUID().uuidString
        let target = directory.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        do {
            if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fm.copyItem(at: source, to: target)
            } else {
                guard let zip = CRXPackage.zip(from: try Data(contentsOf: source)) else { throw InstallError.notAnExtension("not a folder, .zip or .crx") }
                let archive = directory.appendingPathComponent(id + ".zip")
                try zip.write(to: archive)
                defer { try? fm.removeItem(at: archive) }
                try Self.unzip(archive, into: target)
            }
            // A zip made of a folder has the extension one level down.
            if !fm.fileExists(atPath: target.appendingPathComponent("manifest.json").path),
               let inner = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).first(where: {
                   fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) {
                let lifted = directory.appendingPathComponent(id + "-lifted", isDirectory: true)
                try fm.moveItem(at: inner, to: lifted)
                try fm.removeItem(at: target)
                try fm.moveItem(at: lifted, to: target)
            }
            let webExtension: WKWebExtension
            do { webExtension = try await WKWebExtension(resourceBaseURL: target) } catch { throw InstallError.notAnExtension(error.localizedDescription) }
            let name = webExtension.displayName ?? source.deletingPathExtension().lastPathComponent
            let permissions = Set(webExtension.requestedPermissions.map(\.rawValue))
            let patterns = Set(webExtension.allRequestedMatchPatterns.map(\.string))
            guard await confirmInstall(name, ExtensionPermissionWording.describe(permissions: permissions, matchPatterns: patterns)) else {
                throw InstallError.declined
            }
            var item = InstalledExtension(id: id, name: name, version: webExtension.displayVersion ?? webExtension.version ?? "", folder: id)
            item.profiles[profile.id.description] = .init(enabled: true, access: .allRequested, permissions: permissions.sorted())
            installed.append(item)
            save()
            return item
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    func remove(_ id: String) {
        guard let item = installed.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: folder(of: item))
        installed.removeAll { $0.id == id }
        save()
    }

    /// On or off for a profile. Turned on in a profile it was never agreed
    /// to, it gets what it was agreed to in the first.
    func setEnabled(_ id: String, _ enabled: Bool, in profile: Profile) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let key = profile.id.description
        var settings = installed[index].profiles[key] ?? installed[index].profiles.values.first ?? .init()
        settings.enabled = enabled
        installed[index].profiles[key] = settings
        save()
    }

    func setAccess(_ id: String, _ access: ExtensionSiteAccess, in profile: Profile) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].profiles[profile.id.description, default: .init()].access = access
        save()
    }

    /// Agreed to later, when the extension asked while running.
    func addPermissions(_ names: [String], to id: String, in profile: Profile) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let key = profile.id.description
        installed[index].profiles[key, default: .init()].permissions = Array(Set(installed[index].profiles[key]?.permissions ?? []).union(names)).sorted()
        save()
    }

    func settings(_ id: String, in profile: Profile) -> InstalledExtension.InProfile? {
        installed.first { $0.id == id }?.profiles[profile.id.description]
    }

    static func unzip(_ archive: URL, into folder: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw InstallError.notAnExtension("the archive could not be opened") }
    }

    static func askToInstall(name: String, lines: [String]) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(name)”?"
        alert.informativeText = lines.isEmpty ? "It asks for nothing beyond its own button."
            : "It will be able to:\n" + lines.map { "•  " + $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// One profile's extensions, running: WebKit's controller, one context per
/// extension turned on in the profile, and the answers to what extensions
/// ask of the browser (its windows and tabs, permissions, popups).
@MainActor
final class ProfileExtensions: NSObject, WKWebExtensionControllerDelegate {
    static let didChange = Notification.Name("ProfileExtensions.didChange")

    let profile: Profile
    let store: ExtensionStore
    let controller: WKWebExtensionController
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private(set) var loadErrors: [String: String] = [:]

    /// The profile's open tabs, not private ones.
    var tabs: () -> [BrowserWindowController] = { [] }
    var organizer: TabOrganizer?
    /// Opens a tab beside another, or in a new window when there is none.
    var openTab: ((URL?, BrowserWindowController?, Bool) -> BrowserWindowController?)?
    var openWindow: ((URL?) -> BrowserWindowController?)?
    /// What the person answers when an extension asks for more.
    var answerPrompt: (_ name: String, _ lines: [String], _ window: NSWindow?) async -> Bool = ProfileExtensions.ask

    init(profile: Profile, store: ExtensionStore, dataStore: WKWebsiteDataStore, persistent: Bool) {
        self.profile = profile
        self.store = store
        let configuration: WKWebExtensionController.Configuration = persistent
            ? .init(identifier: profile.dataStoreIdentifier) : .nonPersistent()
        configuration.defaultWebsiteDataStore = dataStore
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    var loaded: [(item: InstalledExtension, context: WKWebExtensionContext)] {
        store.installed.compactMap { item in contexts[item.id].map { (item, $0) } }
    }

    /// Loads what is turned on in this profile and unloads what is not.
    func sync() async {
        for item in store.installed where item.isEnabled(in: profile) && contexts[item.id] == nil {
            do {
                let webExtension = try await WKWebExtension(resourceBaseURL: store.folder(of: item))
                let context = WKWebExtensionContext(for: webExtension)
                context.uniqueIdentifier = item.id
                context.isInspectable = true
                apply(store.settings(item.id, in: profile) ?? .init(), to: context)
                try controller.load(context)
                contexts[item.id] = context
                loadErrors[item.id] = nil
                announceTabs(to: context)
            } catch {
                loadErrors[item.id] = error.localizedDescription
            }
        }
        for (id, context) in contexts where !(store.installed.first { $0.id == id }?.isEnabled(in: profile) ?? false) {
            try? controller.unload(context)
            contexts[id] = nil
        }
        for (id, context) in contexts {
            if let settings = store.settings(id, in: profile) { apply(settings, to: context) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// What was agreed to, and the sites chosen.
    private func apply(_ settings: InstalledExtension.InProfile, to context: WKWebExtensionContext) {
        for name in settings.permissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name))
        }
        let requested = Set(context.webExtension.allRequestedMatchPatterns.map(\.string))
        let granted = settings.access.granted(from: requested)
        for pattern in context.webExtension.allRequestedMatchPatterns where !granted.contains(pattern.string) {
            context.setPermissionStatus(.deniedExplicitly, for: pattern)
        }
        for text in granted {
            if let pattern = try? WKWebExtension.MatchPattern(string: text) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        }
    }

    /// The tabs already open, for an extension loaded after them.
    private func announceTabs(to context: WKWebExtensionContext) {
        for tab in tabs() { context.didOpenTab(tab) }
        if let front = tabs().first(where: { $0.window?.isKeyWindow == true }) { context.didActivateTab(front) }
    }

    // MARK: - Tabs and windows, as they change

    func didOpen(_ tab: BrowserWindowController) { controller.didOpenTab(tab) }
    func didClose(_ tab: BrowserWindowController) { controller.didCloseTab(tab) }
    func didActivate(_ tab: BrowserWindowController) { controller.didActivateTab(tab) }
    func didChange(_ tab: BrowserWindowController) { controller.didChangeTabProperties([.title, .URL, .loading], for: tab) }

    private var windows: [ObjectIdentifier: ExtensionWindow] = [:]

    /// The window a tab is in, as extensions see it: one per tab bar.
    func window(of tab: BrowserWindowController) -> ExtensionWindow {
        let key: ObjectIdentifier = tab.window?.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(tab)
        if let window = windows[key], window.contains(tab) { return window }
        let window = ExtensionWindow(representative: tab, extensions: self)
        windows[key] = window
        return window
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        var seen: Set<ObjectIdentifier> = []
        let ordered = NSApp.orderedWindows.compactMap { window in tabs().first { $0.window === window } }
        return (ordered + tabs()).compactMap { tab in
            let window = self.window(of: tab)
            return seen.insert(ObjectIdentifier(window)).inserted ? window : nil
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        let front = NSApp.orderedWindows.lazy.compactMap { window in self.tabs().first { $0.window === window } }.first
        return front.map(window(of:))
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let beside = (configuration.window as? ExtensionWindow)?.activeTab ?? tabs().first { $0.window?.isKeyWindow == true } ?? tabs().first
        let tab = openTab?(configuration.url, beside, configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard let tab = openWindow?(configuration.tabURLs.first) else { return completionHandler(nil, nil) }
        for url in configuration.tabURLs.dropFirst() { _ = openTab?(url, tab, false) }
        completionHandler(window(of: tab), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        let beside = tabs().first { $0.window?.isKeyWindow == true } ?? tabs().first
        _ = openTab?(extensionContext.optionsPageURL, beside, true)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let lines = ExtensionPermissionWording.describe(permissions: Set(permissions.map(\.rawValue)), matchPatterns: [])
        Task { @MainActor in
            let yes = await answerPrompt(name(of: extensionContext), lines, (tab as? BrowserWindowController)?.shownWindow)
            if yes, let id = id(of: extensionContext) { store.addPermissions(permissions.map(\.rawValue), to: id, in: profile) }
            completionHandler(yes ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let line = ExtensionPermissionWording.describeSites(Set(matchPatterns.map(\.string))).map { [$0] } ?? []
        Task { @MainActor in
            let yes = await answerPrompt(name(of: extensionContext), line, (tab as? BrowserWindowController)?.shownWindow)
            completionHandler(yes ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap { $0.host() }.map { "*://\($0)/*" })
        let line = ExtensionPermissionWording.describeSites(hosts).map { [$0] } ?? []
        Task { @MainActor in
            let yes = await answerPrompt(name(of: extensionContext), line, (tab as? BrowserWindowController)?.shownWindow)
            completionHandler(yes ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A popup, from the extension's button in the tab's window.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else { return completionHandler(nil) }
        let tab = (action.associatedTab as? BrowserWindowController) ?? tabs().first { $0.window?.isKeyWindow == true } ?? tabs().first
        if let tab, let id = id(of: context), let button = tab.extensionButton(for: id), button.window != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = tab?.shownWindow?.contentView {
            popover.show(relativeTo: NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 4, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
        lastPopup = action
        completionHandler(nil)
    }

    /// For the self-test.
    private(set) weak var lastPopup: WKWebExtension.Action?

    func id(of context: WKWebExtensionContext) -> String? { contexts.first { $0.value === context }?.key }
    func name(of context: WKWebExtensionContext) -> String { context.webExtension.displayName ?? "The extension" }

    static func ask(name: String, lines: [String], window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(name)” would like to:"
        alert.informativeText = lines.map { "•  " + $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        if let window {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// A browser window as extensions see it: the tabs of one tab bar.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private weak var representative: BrowserWindowController?
    private weak var extensions: ProfileExtensions?

    init(representative: BrowserWindowController, extensions: ProfileExtensions) {
        self.representative = representative
        self.extensions = extensions
    }

    private var members: [BrowserWindowController] {
        guard let representative else { return [] }
        return extensions?.organizer?.tabs(besides: representative) ?? [representative]
    }

    func contains(_ tab: BrowserWindowController) -> Bool { members.contains { $0 === tab } }

    var activeTab: BrowserWindowController? {
        let selected = representative?.window?.tabGroup?.selectedWindow ?? representative?.window
        return members.first { $0.window === selected }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { members }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = representative?.window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        return window.isZoomed ? .maximized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { representative?.isPrivate ?? false }
    func frame(for context: WKWebExtensionContext) -> CGRect { representative?.window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { representative?.window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        activeTab?.show()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        representative?.closeWindowAndTabs(nil)
        completionHandler(nil)
    }
}
