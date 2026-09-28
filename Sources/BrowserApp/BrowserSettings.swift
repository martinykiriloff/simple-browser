import Foundation
import BrowserKit

/// User settings, persisted in `UserDefaults`. One place for the keys so the
/// Settings window and the rest of the app cannot disagree about them.
@MainActor
enum BrowserSettings {
    /// Where settings live. The UI self-test points this at a scratch suite,
    /// so a test that is killed half way cannot leave its values in the
    /// user's real settings.
    static var store: UserDefaults = .standard

    private static let homepageKey = "settings.homepage"
    private static let newWindowKey = "settings.newWindow"

    /// What the user typed for their homepage; empty means "use the default".
    static var homepage: String {
        get { store.string(forKey: homepageKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { store.removeObject(forKey: homepageKey) }
            else { store.set(trimmed, forKey: homepageKey) }
        }
    }

    /// Where the Home button goes right now.
    static var homepageURL: URL { HomePage.url(for: homepage) }

    /// What a new window (⌘N, launch, clicking the Dock icon) starts with.
    enum NewWindowContent: String, CaseIterable {
        case startPage, homepage, empty

        var title: String {
            switch self {
            case .startPage: return "Start Page"
            case .homepage: return "Homepage"
            case .empty:    return "Empty Page"
            }
        }
    }

    // MARK: Passwords

    private static let offerToSaveKey = "settings.passwords.offerToSave"
    private static let autofillKey = "settings.passwords.autofill"
    private static let neverSaveKey = "settings.passwords.neverSave"

    /// Ask "Save password?" after a sign-in. On unless switched off.
    static var offerToSavePasswords: Bool {
        get { store.object(forKey: offerToSaveKey) as? Bool ?? true }
        set { store.set(newValue, forKey: offerToSaveKey) }
    }

    /// Fill a saved sign-in when the page loads, without being asked. Off
    /// still leaves the list under the field and the key button.
    static var autofillPasswords: Bool {
        get { store.object(forKey: autofillKey) as? Bool ?? true }
        set { store.set(newValue, forKey: autofillKey) }
    }

    private static let checkLeaksKey = "settings.passwords.checkLeaks"

    /// Password Checkup also asks Have I Been Pwned about leaks. On unless
    /// switched off; only a 5-character hash prefix is ever sent.
    static var checkLeakedPasswords: Bool {
        get { store.object(forKey: checkLeaksKey) as? Bool ?? true }
        set { store.set(newValue, forKey: checkLeaksKey) }
    }

    /// Origins the user answered "Never" for. Not secret, so not in the vault.
    static var neverSavePasswordOrigins: [String] {
        get { store.stringArray(forKey: neverSaveKey) ?? [] }
        set {
            if newValue.isEmpty { store.removeObject(forKey: neverSaveKey) }
            else { store.set(Array(Set(newValue)).sorted(), forKey: neverSaveKey) }
        }
    }

    // MARK: Search

    private static let engineKey = "settings.search.engine"
    private static let customEngineKey = "settings.search.custom"
    private static let suggestionsKey = "settings.search.suggestions"

    /// The engine the address bar and "Search for …" use.
    static var searchEngine: SearchEngine {
        get {
            let id = store.string(forKey: engineKey) ?? SearchEngine.default.id
            if id == "custom", let custom = SearchEngine.custom(template: customSearchTemplate) { return custom }
            return SearchEngine.all.first { $0.id == id } ?? .default
        }
        set { store.set(newValue.id, forKey: engineKey) }
    }

    /// What typed text means: an address if it names one, otherwise a
    /// search with the chosen engine.
    static func destination(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AddressResolver.address(trimmed) ?? searchEngine.searchURL(for: trimmed)
    }

    static var customSearchTemplate: String {
        get { store.string(forKey: customEngineKey) ?? "" }
        set { store.set(newValue, forKey: customEngineKey) }
    }

    /// What is typed goes to the engine for suggestions. On unless switched off.
    static var searchSuggestions: Bool {
        get { store.object(forKey: suggestionsKey) as? Bool ?? true }
        set { store.set(newValue, forKey: suggestionsKey) }
    }

    // MARK: Content blocking

    private static let blockingKey = "settings.blocking.on"
    private static let filterListsKey = "settings.blocking.lists"
    private static let blockingOffKey = "settings.blocking.offSites."

    /// Block ads and trackers. On unless switched off.
    static var contentBlocking: Bool {
        get { store.object(forKey: blockingKey) as? Bool ?? true }
        set { store.set(newValue, forKey: blockingKey) }
    }

    /// The filter lists chosen, by id; nil until the person chooses, which
    /// means "the ones that are on by default".
    static var enabledFilterLists: [String]? {
        get { store.stringArray(forKey: filterListsKey) }
        set {
            if let newValue { store.set(newValue, forKey: filterListsKey) } else { store.removeObject(forKey: filterListsKey) }
        }
    }

    /// Sites blocking is switched off for, in one profile.
    static func blockingOffSites(profile: String) -> [String] {
        store.stringArray(forKey: blockingOffKey + profile) ?? []
    }

    static func setBlockingOffSites(_ sites: [String], profile: String) {
        if sites.isEmpty { store.removeObject(forKey: blockingOffKey + profile) }
        else { store.set(Array(Set(sites)).sorted(), forKey: blockingOffKey + profile) }
    }

    // MARK: Bookmarks

    private static let favoritesBarKey = "settings.favoritesBar"

    /// The favorites bar under the toolbar. On unless hidden (⇧⌘B).
    static var showFavoritesBar: Bool {
        get { store.object(forKey: favoritesBarKey) as? Bool ?? true }
        set { store.set(newValue, forKey: favoritesBarKey) }
    }

    // MARK: Startup

    private static let startupKey = "settings.startup"

    /// What a launch opens: the last session (the default) or a new window.
    /// After a crash or an update, the last session regardless.
    static var startup: StartupChoice {
        get { store.string(forKey: startupKey).flatMap(StartupChoice.init) ?? .lastSession }
        set { store.set(newValue.rawValue, forKey: startupKey) }
    }

    // MARK: Memory saver

    private static let memorySaverKey = "settings.memorySaver"
    private static let keepActiveKey = "settings.memorySaver.keepActive"

    /// Inactive tabs go to sleep. On unless switched off; critical memory
    /// pressure still puts tabs to sleep, as macOS would otherwise kill them.
    static var memorySaver: Bool {
        get { store.object(forKey: memorySaverKey) as? Bool ?? true }
        set { store.set(newValue, forKey: memorySaverKey) }
    }

    /// Hosts whose tabs never sleep ("Always keep these sites active").
    static var keepActiveSites: [String] {
        get { store.stringArray(forKey: keepActiveKey) ?? [] }
        set { store.set(Array(Set(newValue.map { $0.lowercased() })).sorted(), forKey: keepActiveKey) }
    }

    static func keepsTabsActive(for url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return keepActiveSites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: Translation

    private static let translateTargetKey = "settings.translate.target"
    private static let alwaysTranslateKey = "settings.translate.always"
    private static let recentTargetsKey = "settings.translate.recent"

    /// The language pages are translated into, as a Google code. Nil until
    /// one is chosen: the person's preferred language is used meanwhile.
    static var translateTarget: String? {
        get { store.string(forKey: translateTargetKey) }
        set { store.set(newValue, forKey: translateTargetKey) }
    }

    /// Source languages translated as soon as a page in them loads.
    static var alwaysTranslateLanguages: [String] {
        get { store.stringArray(forKey: alwaysTranslateKey) ?? [] }
        set {
            if newValue.isEmpty { store.removeObject(forKey: alwaysTranslateKey) }
            else { store.set(Array(Set(newValue)).sorted(), forKey: alwaysTranslateKey) }
        }
    }

    /// Targets chosen lately, most recent first, for the top of the list.
    static var recentTranslateTargets: [String] {
        get { store.stringArray(forKey: recentTargetsKey) ?? [] }
        set { store.set(newValue, forKey: recentTargetsKey) }
    }

    static var newWindowContent: NewWindowContent {
        get { store.string(forKey: newWindowKey).flatMap(NewWindowContent.init) ?? .startPage }
        set {
            // The default is stored as "nothing stored", like an empty homepage.
            if newValue == .startPage { store.removeObject(forKey: newWindowKey) }
            else { store.set(newValue.rawValue, forKey: newWindowKey) }
        }
    }
}
