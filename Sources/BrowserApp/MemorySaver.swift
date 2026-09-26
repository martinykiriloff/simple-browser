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
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            MainActor.assumeIsolated { _ = self?.run(pressure: event.contains(.critical) ? .critical : .warning) }
        }
        source.resume()
        pressureSource = source
    }

    /// Returns once the chosen tabs are asleep.
    @discardableResult
    func run(pressure: EvictionPolicy.Pressure) -> Task<Void, Never> {
        Task { @MainActor in
            guard BrowserSettings.memorySaver || pressure == .critical else { return }
            let live = tabs().filter { !$0.isHibernated }
            var protected: Set<TabID> = []
            for tab in live where await tab.mustStayLive() || BrowserSettings.keepsTabsActive(for: tab.currentURL) {
                protected.insert(tab.tab)
            }
            let states = live.map { TabState(id: $0.tab, url: $0.currentURL, lastActive: $0.lastActive) }
            let chosen = Set(policy.tabsToHibernate(live: states, protected: protected, pressure: pressure,
                                                    inactivityLimit: pressure == .normal ? inactivityLimit : nil))
            for tab in live where chosen.contains(tab.tab) { await tab.hibernate() }
        }
    }
}
