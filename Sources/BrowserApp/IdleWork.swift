import Foundation

/// Housekeeping that can wait for a quiet moment: filter-list updates, update
/// checks, history pruning. `NSBackgroundActivityScheduler` runs it when the
/// Mac is idle enough and never while it is napping the app, with a wide
/// tolerance so the system can group it with other apps' work.
@MainActor
enum IdleWork {
    nonisolated(unsafe) private static var schedulers: [String: NSBackgroundActivityScheduler] = [:]

    /// `work` runs about every `interval` seconds, first after `interval`,
    /// or sooner when the system finds a moment; `deferrable` work waits for
    /// an idle moment, the rest merely for tolerance.
    static func repeating(_ name: String, every interval: TimeInterval, tolerance: TimeInterval? = nil, _ work: @escaping @MainActor () -> Void) {
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.simplebrowser." + name)
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = tolerance ?? interval / 4
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
                completion(.finished)
            }
        }
        schedulers[name] = scheduler
    }

    /// Once, when the system next finds a quiet moment (within `within` seconds).
    static func once(_ name: String, within: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.simplebrowser." + name)
        scheduler.repeats = false
        scheduler.interval = within
        scheduler.tolerance = within / 2
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
                completion(.finished)
                Task { @MainActor in schedulers[name] = nil }
            }
        }
        schedulers[name] = scheduler
    }

    static func cancel(_ name: String) {
        schedulers[name]?.invalidate()
        schedulers[name] = nil
    }
}
