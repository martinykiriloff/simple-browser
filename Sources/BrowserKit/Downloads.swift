import Foundation

/// One download, as the list shows it and as it is kept between launches.
public struct DownloadItem: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case downloading, paused, finished, failed, cancelled
    }

    public let id: UUID
    /// What was downloaded, and the page it was downloaded from.
    public var url: URL
    public var page: URL?
    /// Where it is being saved.
    public var path: String
    public var state: State
    public var received: Int64
    /// Nil while the server has not said how much there is.
    public var total: Int64?
    public var startedAt: Date
    public var finishedAt: Date?
    public var failure: String?
    /// Whether it can go on from where it stopped, rather than start again.
    public var canResume: Bool
    /// A kind of file that can run. It is not opened from the list until
    /// the person has said to keep it.
    public var needsConfirmation: Bool

    public init(id: UUID = UUID(), url: URL, page: URL? = nil, path: String, state: State = .downloading, received: Int64 = 0,
                total: Int64? = nil, startedAt: Date = Date(), finishedAt: Date? = nil, failure: String? = nil,
                canResume: Bool = false, needsConfirmation: Bool = false) {
        self.id = id
        self.url = url
        self.page = page
        self.path = path
        self.state = state
        self.received = received
        self.total = total
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failure = failure
        self.canResume = canResume
        self.needsConfirmation = needsConfirmation
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var isActive: Bool { state == .downloading }
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }

    /// The site of the page it came from, else of the file: "from example.com".
    public var source: String {
        let host = (page ?? url).host(percentEncoded: false) ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Files that run, or install, or script the Mac when opened.
public enum DownloadRisk {
    static let dangerous: Set<String> = [
        "app", "dmg", "pkg", "mpkg", "command", "tool", "sh", "bash", "zsh", "csh", "scpt", "scptd", "applescript", "workflow", "action",
        "terminal", "jar", "py", "rb", "pl", "php", "js", "jse", "vbs", "exe", "msi", "bat", "cmd", "scr", "com", "prefpane", "saver",
        "kext", "plugin", "bundle", "osax", "mobileconfig", "configprofile", "webloc", "inetloc", "fileloc", "iso", "img", "xip",
    ]

    public static func isDangerous(fileName: String) -> Bool {
        var name = fileName.lowercased()
        // "installer.dmg.download", "report.pdf.app": the last extension is what opens it.
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        let ext = (name as NSString).pathExtension
        return dangerous.contains(ext)
    }
}

/// How fast a download is going, from its recent progress, and so how long
/// is left. Recent, because a download that was fast a minute ago and is
/// slow now will take long.
public struct DownloadMeter: Sendable {
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    /// How far back "recent" goes.
    public var window: TimeInterval = 5

    public init() {}

    public mutating func record(bytes: Int64, at time: TimeInterval) {
        // Resumed from further back, or restarted: what came before says nothing.
        if let last = samples.last, bytes < last.bytes { samples = [] }
        samples.append((time, bytes))
        samples.removeAll { time - $0.time > window }
    }

    /// Bytes a second; nil until there is something to go by.
    public var speed: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 0.5 else { return nil }
        return max(0, Double(last.bytes - first.bytes) / (last.time - first.time))
    }

    public func secondsLeft(total: Int64?) -> TimeInterval? {
        guard let total, let speed, speed > 0, let last = samples.last, total > last.bytes else { return nil }
        return Double(total - last.bytes) / speed
    }
}

public enum DownloadFormat {
    /// "3.2 MB", in the units Finder uses.
    public static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        return bytes < 1000 ? "\(bytes) bytes" : formatter.string(fromByteCount: bytes)
    }

    /// "5 seconds", "2 minutes", "1 hour 10 minutes": rounded the way a
    /// person would say it, never "0 seconds".
    public static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(1, Int(seconds.rounded(.up)))
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        if seconds < 60 { return unit(seconds < 10 ? seconds : Int((Double(seconds) / 5).rounded(.up)) * 5, "second") }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return unit(minutes, "minute") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? unit(hours, "hour") : "\(unit(hours, "hour")) \(unit(rest, "minute"))"
    }

    /// The line under a download's name.
    public static func status(_ item: DownloadItem, speed: Double? = nil, secondsLeft: TimeInterval? = nil) -> String {
        let progress = item.total.map { "\(size(item.received)) of \(size($0))" } ?? size(item.received)
        switch item.state {
        case .downloading:
            var parts = [progress]
            if let speed, speed > 0 { parts.append(size(Int64(speed)) + "/s") }
            if let secondsLeft { parts.append(duration(secondsLeft) + " left") }
            return parts.joined(separator: " · ")
        case .paused:
            return "Paused · " + progress
        case .finished:
            return [size(item.total ?? item.received), item.source].filter { !$0.isEmpty }.joined(separator: " · ")
        case .failed:
            return "Failed" + (item.failure.map { ": " + $0 } ?? "")
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// The downloads of a profile, newest first.
public struct DownloadList: Codable, Equatable, Sendable {
    public private(set) var items: [DownloadItem] = []
    /// How many are kept once they are over.
    public static let limit = 200

    public init() {}

    public subscript(id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    public mutating func add(_ item: DownloadItem) {
        items.insert(item, at: 0)
        // The oldest that are over go first; one in progress is never dropped.
        while items.count > Self.limit, let index = items.lastIndex(where: { !$0.isActive && $0.state != .paused }) { items.remove(at: index) }
    }

    public mutating func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Removes what is over; what is under way or paused stays.
    public mutating func clearFinished() { items.removeAll { $0.state == .finished || $0.state == .failed || $0.state == .cancelled } }

    public var active: [DownloadItem] { items.filter(\.isActive) }

    /// Overall progress of what is under way, for the toolbar button; nil
    /// when nothing is, or when no server said how much there is.
    public var fraction: Double? {
        let known = active.filter { $0.total != nil }
        guard !known.isEmpty else { return nil }
        let total = known.reduce(Int64(0)) { $0 + ($1.total ?? 0) }
        return total > 0 ? Double(known.reduce(Int64(0)) { $0 + $1.received }) / Double(total) : nil
    }

    /// As read at launch. Whatever was under way when the app last ran is
    /// not under way now: it can be taken up again if it left the means,
    /// and failed if it did not.
    public mutating func markInterrupted(hasResumeData: (UUID) -> Bool) {
        for index in items.indices where items[index].state == .downloading {
            if hasResumeData(items[index].id) {
                items[index].state = .paused
                items[index].canResume = true
            } else {
                items[index].state = .failed
                items[index].failure = "SimpleBrowser quit while it was downloading"
                items[index].canResume = false
            }
        }
    }
}
