import Foundation
import WebKit
import BrowserKit

/// Persists the profile roster in `UserDefaults`, and deletes what a removed
/// profile leaves behind.
///
/// Each profile's `dataStoreIdentifier` must be stable across launches: a new
/// one is a new, empty cookie jar, which signs the user out of everything.
@MainActor
final class ProfileStore {
    static let didChange = Notification.Name("Keel.profilesDidChange")

    private static let rosterKey = "profiles.roster"
    /// Where the single-profile shell kept its profile. Read once, so the
    /// existing Default keeps its data store and nobody is signed out.
    private static let legacyKey = "profiles.default"

    private let defaults: UserDefaults
    private(set) var roster: ProfileRoster

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.rosterKey),
           let roster = try? JSONDecoder().decode(ProfileRoster.self, from: data) {
            self.roster = roster
        } else if let data = defaults.data(forKey: Self.legacyKey),
                  let legacy = try? JSONDecoder().decode(Profile.self, from: data) {
            self.roster = ProfileRoster(profiles: [legacy])
        } else {
            self.roster = ProfileRoster(profiles: [])
        }
        save()
    }

    var profiles: [Profile] { roster.profiles }
    var lastUsed: Profile { roster.lastUsed }
    func profile(_ id: ProfileID) -> Profile? { roster.profile(id) }

    func add(name: String) -> Profile {
        let profile = roster.add(name: name)
        save()
        return profile
    }

    func rename(_ id: ProfileID, to name: String) {
        guard roster.rename(id, to: name) else { return }
        save()
    }

    func markUsed(_ id: ProfileID) {
        guard roster.lastUsedID != id else { return }
        roster.markUsed(id)
        save(notify: false)
    }

    /// Removes the profile, then its cookies, storage and cache, and its
    /// saved passwords with their Keychain key. Its windows must already be
    /// closed: WebKit will not remove a data store that a web view is using.
    func remove(_ id: ProfileID) async {
        guard let removed = roster.remove(id) else { return }
        save()
        try? await WKWebsiteDataStore.remove(forIdentifier: removed.dataStoreIdentifier)
        PasswordService.deleteVault(of: removed)
    }

    private func save(notify: Bool = true) {
        if let data = try? JSONEncoder().encode(roster) {
            defaults.set(data, forKey: Self.rosterKey)
        }
        if notify { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}
