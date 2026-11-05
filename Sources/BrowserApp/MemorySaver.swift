import AppKit
import BrowserKit

/// Chrome's Memory Saver: puts tabs to sleep when there are more than the
/// budget, when a tab has been unused for half an hour, and at once when
/// macOS reports memory pressure. `EvictionPolicy` decides which; each tab
/// decides whether it can (`mustStayLive`).
@MainActor
final class MemorySaver {
    private let tabs: () -> [BrowserWindowController]
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    var policy = EvictionPolicy(liveBudget: 12)
    /// Nil turns time-based sleeping off (the self-test sets its own).
    var inactivityLimit: TimeInterval? = 30 * 60

    init(tabs: @escaping () -> [BrowserWindowController]) {
        self.tabs = tabs
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.run(pressure: .normal) }
        }
        timer?.tolerance = 15   // a wide tolerance lets the system group wake-ups
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            MainActor.assumeIsolated { _ = self?.run(pressure: event.contains(.critical) ? .critical : .warning) }
        }
        source.resume()
        pressureSource = source
    }

    /// A sweep already under way. The tabs are asked one at a time and each
    /// answer comes from the page, so a sweep outlasting the timer must not
    /// have a second one started over it: two sweeps would each hold every
    /// tab's controller while they waited, and each would decide from state
    /// the other was changing.
    private var sweeping = false

    /// Returns once the chosen tabs are asleep.
    @discardableResult
    func run(pressure: EvictionPolicy.Pressure) -> Task<Void, Never> {
        Task { @MainActor in
            guard BrowserSettings.memorySaver || pressure == .critical else { return }
            guard !sweeping else { return }
            sweeping = true
            defer { sweeping = false }
            let live = tabs().filter { !$0.isHibernated }
            var protected: Set<TabID> = []
            for tab in live {
                // A site the person keeps active is never asked anything.
                if BrowserSettings.keepsTabsActive(for: tab.currentURL) {
                    protected.insert(tab.tab)
                    continue
                }
                if await mustStayLive(tab) { protected.insert(tab.tab) }
            }
            let states = live.map { TabState(id: $0.tab, url: $0.currentURL, lastActive: $0.lastActive) }
            let chosen = Set(policy.tabsToHibernate(live: states, protected: protected, pressure: pressure,
                                                    inactivityLimit: pressure == .normal ? inactivityLimit : nil))
            for tab in live where chosen.contains(tab.tab) {
                // Asked again, now: the answers above took a round trip to
                // each page, and a round trip is long enough for the person
                // to have switched to this tab, or for it to have started
                // loading something. Only what the tab can say by itself is
                // asked — the page has been asked once already.
                guard !tab.isHibernated, !tab.mustStayLiveNow,
                      !BrowserSettings.keepsTabsActive(for: tab.currentURL) else { continue }
                await tab.hibernate()
            }
        }
    }

    /// Whether the tab must stay live, with a deadline.
    ///
    /// A page that never answers the question would otherwise hold the
    /// sweep for as long as the app runs, and every tab's controller with
    /// it. Unanswered, the tab counts as busy and is left alone: the safe
    /// answer, since being wrong the other way unloads a page that is doing
    /// something. The question left out there is not waited for.
    private func mustStayLive(_ tab: BrowserWindowController, within seconds: Double = 2) async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            Task { @MainActor in answer.give(await tab.mustStayLive()) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                answer.give(true)
            }
        }
    }
}

/// Takes the first of two answers and lets the later one go.
@MainActor
private final class FirstAnswer {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func give(_ answer: Bool) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}
