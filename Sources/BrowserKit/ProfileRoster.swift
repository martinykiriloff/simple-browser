import Foundation

/// Every profile the browser knows, and which one a new window opens in.
///
/// Pure value type: the rules (names, colours, the last profile cannot go)
/// are checkable without AppKit. Persisting it and tearing down a removed
/// profile's data store are the app's job.
public struct ProfileRoster: Hashable, Sendable, Codable {
    public private(set) var profiles: [Profile]
    /// Where ⌘N goes when no browser window is in front.
    public private(set) var lastUsedID: ProfileID

    /// A roster always has at least one profile, so "which profile" always has an answer.
    public init(profiles: [Profile], lastUsedID: ProfileID? = nil) {
        let list = profiles.isEmpty ? [Profile(name: "Default")] : profiles
        self.profiles = list
        self.lastUsedID = lastUsedID.flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list[0].id
    }

    public var lastUsed: Profile { profile(lastUsedID) ?? profiles[0] }

    public func profile(_ id: ProfileID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Adds a profile with its own, new data store. A blank name becomes
    /// "Profile N"; a taken one gets a number, so the menu never shows two
    /// entries that look alike.
    @discardableResult
    public mutating func add(name: String = "") -> Profile {
        let used = Set(profiles.map(\.accent))
        let accent = GroupColor.allCases.first { !used.contains($0) }
            ?? GroupColor.allCases[profiles.count % GroupColor.allCases.count]
        let profile = Profile(name: uniqueName(name), accent: accent)
        profiles.append(profile)
        return profile
    }

    /// False for an unknown id. The data store identifier never changes, so a
    /// rename keeps every cookie and saved password.
    @discardableResult
    public mutating func rename(_ id: ProfileID, to name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == profiles[index].name { return true }
        profiles[index].name = uniqueName(trimmed, ignoring: id)
        return true
    }

    /// Refuses to remove the last profile, and an unknown one. Returns the
    /// removed profile so the caller can delete its data.
    public mutating func remove(_ id: ProfileID) -> Profile? {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = profiles.remove(at: index)
        if lastUsedID == id { lastUsedID = profiles[0].id }
        return removed
    }

    public mutating func markUsed(_ id: ProfileID) {
        if profile(id) != nil { lastUsedID = id }
    }

    private func uniqueName(_ proposed: String, ignoring id: ProfileID? = nil) -> String {
        let taken = Set(profiles.filter { $0.id != id }.map { $0.name.lowercased() })
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            var n = profiles.count + (id == nil ? 1 : 0)
            while taken.contains("profile \(n)") { n += 1 }
            return "Profile \(n)"
        }
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
