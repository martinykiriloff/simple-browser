import Foundation

/// Decides which tabs lose their live web view under memory pressure.
///
/// Pure function of state, so it is testable without WebKit or a running app.
public struct EvictionPolicy: Sendable {
    /// Tabs kept live regardless of pressure, beyond the active one.
    public var liveBudget: Int

    public init(liveBudget: Int = 12) {
        self.liveBudget = liveBudget
    }

    public enum Pressure: Sendable, Equatable {
        case normal, warning, critical

        var budgetMultiplier: Double {
            switch self {
            case .normal:   1.0
            case .warning:  0.5
            case .critical: 0.15
            }
        }
    }

    /// Returns the tabs that should be hibernated, least-recently-active first.
    ///
    /// The active tab and pinned tabs are never evicted.
    public func tabsToHibernate(
        live: [TabState],
        activeTab: TabID?,
        pressure: Pressure
    ) -> [TabID] {
        let budget = max(1, Int(Double(liveBudget) * pressure.budgetMultiplier))
        let evictable = live
            .filter { $0.id != activeTab && !$0.isPinned }
            .sorted { $0.lastActive < $1.lastActive }

        let protectedCount = live.count - evictable.count
        let overBudget = live.count - budget
        guard overBudget > 0 else { return [] }

        return Array(evictable.prefix(min(overBudget, live.count - protectedCount)))
            .map(\.id)
    }

    /// Chrome's Memory Saver, for a browser with several windows: every tab
    /// on screen is protected, not just one. Tabs over the budget go first,
    /// least recently used first; then, at normal pressure, any tab left
    /// unused for longer than `inactivityLimit`.
    ///
    /// - Parameters:
    ///   - protected: tabs that must stay live: on screen, playing media,
    ///     using the camera, holding an unsent form, being inspected.
    public func tabsToHibernate(
        live: [TabState],
        protected: Set<TabID>,
        pressure: Pressure,
        now: Date = .now,
        inactivityLimit: TimeInterval? = 30 * 60
    ) -> [TabID] {
        let budget = max(protected.count, Int(Double(liveBudget) * pressure.budgetMultiplier))
        let evictable = live
            .filter { !protected.contains($0.id) && !$0.isPinned }
            .sorted { $0.lastActive < $1.lastActive }
        var chosen = Array(evictable.prefix(max(0, live.count - budget)))
        if let inactivityLimit {
            let idle = evictable.dropFirst(chosen.count).filter { now.timeIntervalSince($0.lastActive) > inactivityLimit }
            chosen += idle
        }
        return chosen.map(\.id)
    }
}
