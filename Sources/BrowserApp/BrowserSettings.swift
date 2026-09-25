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

    /// Origins the user answered "Never" for. Not secret, so not in the vault.
    static var neverSavePasswordOrigins: [String] {
        get { store.stringArray(forKey: neverSaveKey) ?? [] }
        set {
            if newValue.isEmpty { store.removeObject(forKey: neverSaveKey) }
            else { store.set(Array(Set(newValue)).sorted(), forKey: neverSaveKey) }
        }
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
