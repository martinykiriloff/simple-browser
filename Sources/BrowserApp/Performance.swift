import AppKit
import Darwin
import WebKit
import BrowserKit

/// What a process costs: its memory footprint and the processor time it
/// has used, as Activity Monitor counts them.
struct ProcessCost {
    var footprintBytes: UInt64
    var cpuSeconds: Double

    static func of(_ pid: pid_t) -> ProcessCost? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let nanoseconds = ticks * Double(timebase.numer) / Double(timebase.denom)
        return ProcessCost(footprintBytes: info.ri_phys_footprint, cpuSeconds: nanoseconds / 1e9)
    }

    /// When this process was started, from the kernel.
    static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }
}

/// `--performance <report.json>`: measures launch, new tabs, memory with
/// many tabs and the processor while idle, writes the numbers and quits.
/// `scripts/test-performance.sh` checks them against the budget.
@MainActor
enum PerformanceRun {
    /// Marks the app records as it starts, in seconds since the process began.
    nonisolated(unsafe) static var launchMarks: [String: Double] = [:]
    static let start = ProcessCost.processStart

    static func mark(_ name: String) {
        guard launchMarks[name] == nil else { return }
        launchMarks[name] = Date().timeIntervalSince(start)
    }

    static func run(app: AppDelegate, browser: BrowserWindowController, output: String, tabCounts: [Int], idleSeconds: Double) {
        Task { @MainActor in
            let site = "http://127.0.0.1:8767"
            func log(_ line: String) { FileHandle.standardError.write(Data("[performance] \(line)\n".utf8)) }

            // The start page, as a person sees it at launch.
            _ = await waitForPage(browser, within: 30)
            mark("page")
            log("launch: window \(launchMarks["window"] ?? -1)s page \(launchMarks["page"] ?? -1)s")

            /// Everything the app costs: itself and the web, network and GPU processes of its tabs.
            @MainActor func cost() -> (memoryMB: Double, cpuSeconds: Double, byProcess: [String: Double]) {
                var pids: [pid_t: String] = [getpid(): "app"]
                for tab in app.browserControllers {
                    for (key, kind) in [("_webProcessIdentifier", "web"), ("_gpuProcessIdentifier", "gpu")] where tab.pageWebView.responds(to: NSSelectorFromString(key)) {
                        if let pid = (tab.pageWebView.value(forKey: key) as? NSNumber)?.int32Value, pid > 0 { pids[pid] = kind }
                    }
                    let store = tab.pageWebView.configuration.websiteDataStore
                    if store.responds(to: NSSelectorFromString("_networkProcessIdentifier")),
                       let pid = (store.value(forKey: "_networkProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 { pids[pid] = "network" }
                }
                var memory: UInt64 = 0
                var cpu = 0.0
                var byProcess: [String: Double] = [:]
                for (pid, kind) in pids {
                    guard let cost = ProcessCost.of(pid) else { continue }
                    memory += cost.footprintBytes
                    cpu += cost.cpuSeconds
                    byProcess[kind, default: 0] += cost.cpuSeconds
                }
                return (Double(memory) / 1_048_576, cpu, byProcess)
            }

            // New tabs, one after another, each timed to its page finished.
            var durations: [Double] = []
            var memoryAt: [Int: Double] = [:]
            var opened = 0
            var previous = browser
            for target in tabCounts.sorted() {
                while opened < target - 1 {
                    let began = Date()
                    let tab = app.newTab(beside: previous, url: URL(string: site + "/page?title=Tab%20\(opened + 2)")!, inFront: false)
                    previous = tab
                    _ = await waitForPage(tab, within: 20)
                    durations.append(Date().timeIntervalSince(began))
                    opened += 1
                }
                try? await Task.sleep(for: .seconds(1))
                memoryAt[target] = cost().memoryMB
                log("\(target) tabs: \(Int(memoryAt[target]!)) MB")
            }
            durations.sort()
            let median = durations.isEmpty ? 0 : durations[durations.count / 2]
            let worst = durations.last ?? 0

            // Memory Saver puts the surplus to sleep.
            await app.memorySaver.run(pressure: .normal).value
            try? await Task.sleep(for: .seconds(2))
            let afterSaver = cost().memoryMB
            log("after Memory Saver: \(Int(afterSaver)) MB, \(app.browserControllers.filter(\.isHibernated).count) asleep")

            // Ten busy pages in the background, and the front tab still: what idling costs.
            for tab in app.browserControllers where tab !== browser { tab.window?.performClose(nil) }
            try? await Task.sleep(for: .seconds(1))
            previous = browser
            for index in 0..<10 {
                let tab = app.newTab(beside: previous, url: URL(string: site + "/busy?n=\(index)")!, inFront: false)
                previous = tab
                _ = await waitForPage(tab, within: 20)
            }
            try? await Task.sleep(for: .seconds(3))
            let before = cost()
            let began = Date()
            try? await Task.sleep(for: .seconds(idleSeconds))
            let after = cost()
            let elapsed = Date().timeIntervalSince(began)
            let percent = (after.cpuSeconds - before.cpuSeconds) / elapsed * 100
            let breakdown = after.byProcess.keys.sorted().map { kind in
                "\(kind) \(String(format: "%.1f", (after.byProcess[kind]! - (before.byProcess[kind] ?? 0)) / elapsed * 100))%"
            }.joined(separator: ", ")
            log("idle \(Int(elapsed))s: \(String(format: "%.1f", percent))% of a core (\(breakdown))")

            let measure = PerformanceMeasure(
                launchToWindow: launchMarks["window"] ?? 0, launchToPage: launchMarks["page"] ?? 0,
                newTabMedian: median, newTabWorst: worst,
                memory20Tabs: memoryAt[20] ?? memoryAt[tabCounts.min() ?? 0] ?? 0, memory50Tabs: memoryAt[50] ?? memoryAt[tabCounts.max() ?? 0] ?? 0,
                memory50TabsAfterSaver: afterSaver, idleCPUPercent: percent, idleSeconds: elapsed,
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "debug")
            if let data = try? JSONEncoder().encode(measure) { try? data.write(to: URL(fileURLWithPath: output), options: .atomic) }
            RunLoop.main.perform { NSApp.terminate(nil) }
        }
    }

    /// Waits for the tab's page to finish, or the time to pass.
    private static func waitForPage(_ tab: BrowserWindowController, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if tab.pageFinishedCount > 0, !tab.pageWebView.isLoading { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
