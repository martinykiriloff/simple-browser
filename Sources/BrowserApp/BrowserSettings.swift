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
        case homepage, empty

        var title: String {
            switch self {
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
        get { store.string(forKey: newWindowKey).flatMap(NewWindowContent.init) ?? .homepage }
        set {
            // The default is stored as "nothing stored", like an empty homepage.
            if newValue == .homepage { store.removeObject(forKey: newWindowKey) }
            else { store.set(newValue.rawValue, forKey: newWindowKey) }
        }
    }
}
