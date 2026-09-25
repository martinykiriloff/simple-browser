import Foundation
import BrowserKit

/// Persists the default profile so its `dataStoreIdentifier` is stable across
/// launches. Without this every launch would get a fresh, empty data store.
///
/// Placeholder for `ProfileKit`; a single profile in `UserDefaults` is enough
/// for the app shell.
enum ProfileStore {
    private static let key = "profiles.default"

    static func defaultProfile() -> Profile {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let profile = try? JSONDecoder().decode(Profile.self, from: data) {
            return profile
        }
        let profile = Profile(name: "Default")
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: key)
        }
        return profile
    }
}
