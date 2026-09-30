import Foundation

/// What a performance run measures, in seconds, megabytes and percent of
/// one core.
public struct PerformanceMeasure: Codable, Equatable, Sendable {
    /// From the process starting to the first window on screen.
    public var launchToWindow: Double
    /// From the process starting to the start page finished.
    public var launchToPage: Double
    /// New tab to its page finished: the median and the slowest of the tabs opened.
    public var newTabMedian: Double
    public var newTabWorst: Double
    /// The app and its web processes together, with this many tabs open.
    public var memory20Tabs: Double
    public var memory50Tabs: Double
    /// …and after Memory Saver has put the surplus to sleep.
    public var memory50TabsAfterSaver: Double
    /// Processor time as a share of one core, with ten busy pages in the background.
    public var idleCPUPercent: Double
    public var idleSeconds: Double
    public var build: String

    public init(launchToWindow: Double, launchToPage: Double, newTabMedian: Double, newTabWorst: Double, memory20Tabs: Double, memory50Tabs: Double,
                memory50TabsAfterSaver: Double, idleCPUPercent: Double, idleSeconds: Double, build: String) {
        self.launchToWindow = launchToWindow; self.launchToPage = launchToPage; self.newTabMedian = newTabMedian; self.newTabWorst = newTabWorst
        self.memory20Tabs = memory20Tabs; self.memory50Tabs = memory50Tabs; self.memory50TabsAfterSaver = memory50TabsAfterSaver
        self.idleCPUPercent = idleCPUPercent; self.idleSeconds = idleSeconds; self.build = build
    }
}

/// The numbers the app must stay within, and the check of a run against them.
public enum PerformanceBudget {
    public struct Line: Equatable, Sendable {
        public var name: String
        public var value: Double
        public var limit: Double
        public var unit: String
        public var passed: Bool { value <= limit }
    }

    /// Measured on a debug build on an M-series Mac, 2026-10-01: window at
    /// 0.6–0.8 s, start page at 0.75–1.0 s, a new tab in 0.18 s (0.26 at
    /// worst), 705 MB with 20 tabs, 1440 MB with 50 and 860 MB once Memory
    /// Saver had put 38 to sleep, 2.4% of a core idling with ten busy
    /// background pages. The budget is that with about half again as
    /// headroom; a release build is faster.
    public static let launchToWindow = 1.2
    public static let launchToPage = 1.6
    public static let newTabMedian = 0.4
    public static let newTabWorst = 1.0
    public static let memory20Tabs = 1100.0
    public static let memory50Tabs = 2200.0
    public static let memory50TabsAfterSaver = 1300.0
    public static let idleCPUPercent = 5.0

    public static func lines(for measure: PerformanceMeasure) -> [Line] {
        [
            Line(name: "Cold launch to first window", value: measure.launchToWindow, limit: launchToWindow, unit: "s"),
            Line(name: "Cold launch to start page", value: measure.launchToPage, limit: launchToPage, unit: "s"),
            Line(name: "New tab to page loaded, median", value: measure.newTabMedian, limit: newTabMedian, unit: "s"),
            Line(name: "New tab to page loaded, slowest", value: measure.newTabWorst, limit: newTabWorst, unit: "s"),
            Line(name: "Memory with 20 tabs", value: measure.memory20Tabs, limit: memory20Tabs, unit: "MB"),
            Line(name: "Memory with 50 tabs", value: measure.memory50Tabs, limit: memory50Tabs, unit: "MB"),
            Line(name: "Memory with 50 tabs after Memory Saver", value: measure.memory50TabsAfterSaver, limit: memory50TabsAfterSaver, unit: "MB"),
            Line(name: "Processor, 10 busy background tabs idle", value: measure.idleCPUPercent, limit: idleCPUPercent, unit: "% of a core"),
        ]
    }

    public static func passes(_ measure: PerformanceMeasure) -> Bool { lines(for: measure).allSatisfy(\.passed) }

    static func format(_ value: Double, _ unit: String) -> String {
        unit == "MB" ? "\(Int(value.rounded())) MB" : String(format: "%.2f", value) + " " + unit
    }

    /// The run's numbers against the budget, one line each.
    public static func report(_ measure: PerformanceMeasure) -> String {
        lines(for: measure).map { "\($0.passed ? "✔" : "✘") \($0.name): \(format($0.value, $0.unit)) (budget \(format($0.limit, $0.unit)))" }.joined(separator: "\n")
    }

    /// The README's table of budgets, so the two cannot drift apart.
    public static func readmeTable() -> String {
        let blank = PerformanceMeasure(launchToWindow: 0, launchToPage: 0, newTabMedian: 0, newTabWorst: 0, memory20Tabs: 0, memory50Tabs: 0,
                                       memory50TabsAfterSaver: 0, idleCPUPercent: 0, idleSeconds: 0, build: "")
        var rows = ["| What | Budget |", "|---|---|"]
        for line in lines(for: blank) { rows.append("| \(line.name) | \(format(line.limit, line.unit)) |") }
        return rows.joined(separator: "\n")
    }
}
