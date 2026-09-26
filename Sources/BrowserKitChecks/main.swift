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

// MARK: Eviction

do {
    let now = Date()
    func tab(_ minutesAgo: Double, pinned: Bool = false) -> TabState {
        TabState(isPinned: pinned, lastActive: now.addingTimeInterval(-minutesAgo * 60))
    }
    let tabs = (0..<6).map { tab(Double($0)) }          // tabs[0] used most recently
    let policy = EvictionPolicy(liveBudget: 4)
    let shown: Set<TabID> = [tabs[0].id, tabs[5].id]
    let chosen = policy.tabsToHibernate(live: tabs, protected: shown, pressure: .normal, now: now, inactivityLimit: nil)
    check("over budget: the least recently used go first", chosen == [tabs[4].id, tabs[3].id], chosen.count)
    check("tabs on screen are never chosen, however old", !chosen.contains(tabs[5].id))
    let critical = policy.tabsToHibernate(live: tabs, protected: shown, pressure: .critical, now: now, inactivityLimit: nil)
    check("critical pressure keeps only what is on screen", Set(critical) == Set(tabs.map(\.id)).subtracting(shown), critical.count)
    let idle = [tab(0), tab(45), tab(10)]
    let byTime = EvictionPolicy(liveBudget: 10).tabsToHibernate(live: idle, protected: [idle[0].id], pressure: .normal, now: now)
    check("under budget, a tab idle past the limit still sleeps", byTime == [idle[1].id], byTime.count)
    let pinned = [tab(0), tab(90, pinned: true)]
    check("pinned tabs never sleep", EvictionPolicy(liveBudget: 1).tabsToHibernate(live: pinned, protected: [pinned[0].id], pressure: .critical, now: now).isEmpty)
}

// MARK: Session

do {
    let work = ProfileID(), gone = ProfileID()
    let page = SessionSnapshot.Tab(url: URL(string: "https://example.com/a"), title: "A", state: Data([1, 2, 3]))
    let blank = SessionSnapshot.Tab(url: nil, title: "New Tab", state: nil)
    let session = SessionSnapshot(windows: [
        .init(profileID: work, frame: .init(x: 10, y: 20, width: 800, height: 600), tabs: [blank, page, page], selected: 9),
        .init(profileID: gone, frame: .init(x: 0, y: 0, width: 1, height: 1), tabs: [page], selected: 0),
        .init(profileID: work, frame: .init(x: 0, y: 0, width: 1, height: 1), tabs: [blank], selected: 0),
    ])
    let data = try JSONEncoder().encode(session)
    check("a session round-trips through JSON", try JSONDecoder().decode(SessionSnapshot.self, from: data) == session)
    let windows = session.restorable(profiles: [work])
    check("a deleted profile's windows are not restored", windows.count == 1, windows.count)
    check("empty tabs are dropped, the rest keep their order", windows.first?.tabs == [page, page])
    check("a selection past the end is clamped", windows.first?.selected == 1)
    check("a session of blank tabs is empty", SessionSnapshot(windows: [.init(profileID: work, frame: .init(x: 0, y: 0, width: 1, height: 1), tabs: [blank], selected: 0)]).isEmpty)
    check("restore when asked", StartupChoice.shouldRestore(choice: .lastSession, uncleanExit: false, restartForUpdate: false, hasSession: true))
    check("a new window when asked", !StartupChoice.shouldRestore(choice: .newWindow, uncleanExit: false, restartForUpdate: false, hasSession: true))
    check("always restore after a crash", StartupChoice.shouldRestore(choice: .newWindow, uncleanExit: true, restartForUpdate: false, hasSession: true))
    check("always restore after an update", StartupChoice.shouldRestore(choice: .newWindow, uncleanExit: false, restartForUpdate: true, hasSession: true))
    check("nothing to restore, nothing restored", !StartupChoice.shouldRestore(choice: .lastSession, uncleanExit: true, restartForUpdate: true, hasSession: false))
} catch {
    check("session checks", false, error)
}

print(failures == 0 ? "✔ \(passed) checks passed" : "\(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
