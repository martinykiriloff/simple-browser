import Foundation
import BrowserKit

// Unit checks for BrowserKit, as a plain executable: `swift run BrowserKitChecks`.
// Same arrangement as PasswordKitChecks, for the same reason: no XCTest on a
// Command Line Tools-only Mac.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    if ok { passed += 1 } else { failures += 1; print("✘ \(name)" + (detail.map { ": \($0)" } ?? "")) }
}

// MARK: Profile roster

do {
    let empty = ProfileRoster(profiles: [])
    check("a roster is never empty", empty.profiles.count == 1 && empty.profiles[0].name == "Default")
    check("the only profile is the last used", empty.lastUsedID == empty.profiles[0].id)
}

do {
    let a = Profile(name: "Work")
    let roster = ProfileRoster(profiles: [a], lastUsedID: ProfileID())
    check("an unknown last-used id falls back to the first profile", roster.lastUsedID == a.id)
}

do {
    var roster = ProfileRoster(profiles: [Profile(name: "Default")])
    let second = roster.add()
    check("a blank name becomes Profile N", second.name == "Profile 2", second.name)
    check("each profile has its own data store", second.dataStoreIdentifier != roster.profiles[0].dataStoreIdentifier)
    check("a new profile takes an unused colour", second.accent != roster.profiles[0].accent, second.accent)

    let work = roster.add(name: "  Work ")
    check("names are trimmed", work.name == "Work", work.name)
    let work2 = roster.add(name: "work")
    check("a taken name, in any case, gets a number", work2.name == "work 2", work2.name)

    let store = work.dataStoreIdentifier
    check("rename succeeds", roster.rename(work.id, to: "Client"))
    check("rename changes the name", roster.profile(work.id)?.name == "Client")
    check("rename keeps the data store, so sessions survive", roster.profile(work.id)?.dataStoreIdentifier == store)
    check("rename to an existing name is numbered", roster.rename(work2.id, to: "Client") && roster.profile(work2.id)?.name == "Client 2", roster.profile(work2.id)?.name)
    check("rename to its own name leaves it alone", roster.rename(work.id, to: "Client") && roster.profile(work.id)?.name == "Client")
    check("rename of an unknown profile fails", !roster.rename(ProfileID(), to: "x"))

    roster.markUsed(work.id)
    check("markUsed moves last used", roster.lastUsedID == work.id)
    roster.markUsed(ProfileID())
    check("markUsed ignores an unknown id", roster.lastUsedID == work.id)

    check("removing returns the profile", roster.remove(work.id)?.id == work.id)
    check("removing the last-used profile moves last used", roster.lastUsedID == roster.profiles[0].id)
    check("removing an unknown profile does nothing", roster.remove(ProfileID()) == nil && roster.profiles.count == 3)
}

do {
    var roster = ProfileRoster(profiles: [Profile(name: "Only")])
    check("the last profile cannot be removed", roster.remove(roster.profiles[0].id) == nil && roster.profiles.count == 1)
}

do {
    var roster = ProfileRoster(profiles: [Profile(name: "Default")])
    roster.add(name: "Work")
    let data = try JSONEncoder().encode(roster)
    let decoded = try JSONDecoder().decode(ProfileRoster.self, from: data)
    check("the roster round-trips through JSON", decoded == roster)
} catch {
    check("the roster round-trips through JSON", false, error)
}

print(failures == 0 ? "✔ \(passed) checks passed" : "\(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
