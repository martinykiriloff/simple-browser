import AppKit
import WebKit
import BlockKit

/// Ad and tracker blocking for every tab: keeps the filter lists current,
/// compiles them into WebKit's content rule lists, and hands those to each
/// tab's web view.
///
/// WebKit does the blocking itself, in its network process, before a request
/// is made; nothing here sees a page's traffic. The lists are the same for
/// every profile. Which sites a person switched blocking off for is the
/// profile's own, and lives in its settings.
@MainActor
final class ContentBlocker {
    static let didChange = Notification.Name("Keel.contentBlockingDidChange")

    /// What is known about one downloaded list.
    struct ListState: Codable, Equatable {
        var etag: String?
        var lastModified: String?
        /// When the file was last downloaded, and when the server was last asked.
        var fetchedAt: Date?
        var checkedAt: Date?
        var bytes = 0
    }

    struct State: Codable, Equatable {
        var lists: [String: ListState] = [:]
        /// The compiled rule lists now in use, and what they were made from.
        var fingerprint: String?
        var identifiers: [String] = []
        var enabledLists: [String] = []
        var rules = 0
        var filters = 0
        var skipped = 0
        /// Rules WebKit refused; they were left out and the rest compiled.
        var rejected = 0
        /// Selectors WebKit's CSS parser refused, or that are plainly not CSS.
        var refusedSelectors: Int? = 0
        var compiledAt: Date?
    }

    enum Activity: Equatable {
        case idle
        case downloading(String)
        case compiling
        case failed(String)
    }

    /// What one update did, for the self-test and the probe.
    struct Report {
        var downloaded: [String] = []
        var notModified: [String] = []
        var failed: [String: String] = [:]
        var compiled = false
        var reused = false
        var rules = 0
        var lists = 0
        var rejected = 0
        var seconds: [String: Double] = [:]
    }

    let directory: URL
    /// The lists on offer. The self-test points these at its fixture site.
    var sources: [FilterList]
    private let store: WKContentRuleListStore
    private let session: URLSession
    private(set) var state = State()
    private(set) var activity = Activity.idle { didSet { if activity != oldValue { changed() } } }
    private(set) var ruleLists: [WKContentRuleList] = []

    private var tabs = NSHashTable<WKUserContentController>.weakObjects()
    /// Tabs showing a site blocking is switched off for.
    private var suspended = NSHashTable<WKUserContentController>.weakObjects()
    private var updating: Task<Report, Never>?
    private var timer: Timer?

    /// How often the lists' servers are asked for something newer.
    static let updateInterval: TimeInterval = 24 * 60 * 60

    init(directory: URL, sources: [FilterList] = FilterList.all, session: URLSession? = nil) {
        self.directory = directory
        self.sources = sources
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory.appendingPathComponent("Compiled", isDirectory: true)) ?? .default()
        if let session {
            self.session = session
        } else {
            // No cookies, no cache of its own: the lists' servers learn an
            // address and a time, and nothing to tie them together.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
    }

    static func standard() -> ContentBlocker {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ContentBlocker(directory: support.appendingPathComponent("Keel/ContentBlocking", isDirectory: true))
    }

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private func fileURL(_ list: FilterList) -> URL { directory.appendingPathComponent(list.id + ".txt") }

    var enabledSources: [FilterList] {
        let chosen = BrowserSettings.enabledFilterLists
        return sources.filter { chosen?.contains($0.id) ?? $0.onByDefault }
    }

    var isOn: Bool { BrowserSettings.contentBlocking }
    var isReady: Bool { !ruleLists.isEmpty }

    // MARK: - Launch

    /// The rule lists compiled last time are looked up and in place before
    /// the first page loads; asking the servers for newer ones comes after.
    func start() {
        isLookingUp = true
        Task { @MainActor in
            await loadCompiled()
            isLookingUp = false
            waiting.forEach { $0.resume() }
            waiting = []
            if isOn, needsUpdate { _ = await update() }
        }
        // Hourly, when the Mac has a quiet moment, never while it naps the app.
        IdleWork.repeating("filter-lists", every: 60 * 60) { [weak self] in
            guard let self, self.isOn, self.needsUpdate else { return }
            Task { @MainActor in _ = await self.update() }
        }
    }

    private var isLookingUp = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Returns once the rule lists compiled last time are in place. A tab
    /// waits for this before its first page is allowed to load, so a session
    /// restored at launch is filtered from its first request. It takes
    /// milliseconds: the lists are already compiled, only looked up.
    func waitUntilLookedUp() async {
        guard isLookingUp else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private var needsUpdate: Bool {
        let enabled = enabledSources
        if state.enabledLists != enabled.map(\.id) || ruleLists.isEmpty && !enabled.isEmpty { return true }
        return enabled.contains { list in
            guard let checked = state.lists[list.id]?.checkedAt else { return true }
            return Date().timeIntervalSince(checked) > Self.updateInterval
        }
    }

    private func loadCompiled() async {
        var found: [WKContentRuleList] = []
        for identifier in state.identifiers {
            guard let list = try? await store.contentRuleList(forIdentifier: identifier) else {
                // One is missing: the set is not the set any more.
                found = []
                state.fingerprint = nil
                break
            }
            found.append(list)
        }
        ruleLists = found
        applyToAll()
        changed()
    }

    // MARK: - Tabs

    /// Rule lists that belong to a tab rather than to blocking, such as
    /// DevTools' request blocking: they survive blocking being re-applied.
    private static let pinned = NSMapTable<WKUserContentController, NSArray>.weakToStrongObjects()

    static func pinnedLists(for controller: WKUserContentController) -> [WKContentRuleList] {
        pinned.object(forKey: controller) as? [WKContentRuleList] ?? []
    }

    /// Replaces the tab's pinned lists, and installs them now.
    static func setPinnedLists(_ lists: [WKContentRuleList], for controller: WKUserContentController) {
        pinnedLists(for: controller).forEach(controller.remove)
        if lists.isEmpty { pinned.removeObject(forKey: controller) } else { pinned.setObject(lists as NSArray, forKey: controller) }
        lists.forEach(controller.add)
    }

    /// Called for every tab as it is made, before its web view exists.
    func register(_ controller: WKUserContentController) {
        tabs.add(controller)
        apply(to: controller)
    }

    /// Whether the tab's page is on a site blocking is switched off for.
    /// Set as a page starts to load, so it holds for that page's requests.
    func setSuspended(_ off: Bool, for controller: WKUserContentController) {
        guard suspended.contains(controller) != off else { return }
        if off { suspended.add(controller) } else { suspended.remove(controller) }
        apply(to: controller)
    }

    func isSuspended(_ controller: WKUserContentController) -> Bool { suspended.contains(controller) }

    private func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        Self.pinnedLists(for: controller).forEach(controller.add)
        guard isOn, !suspended.contains(controller) else { return }
        ruleLists.forEach(controller.add)
    }

    private func applyToAll() {
        tabs.allObjects.forEach(apply)
    }

    /// Settings changed: the switch, or which lists are on.
    func settingsChanged() {
        applyToAll()
        changed()
        if isOn, needsUpdate { Task { @MainActor in _ = await update() } }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Updating

    /// Asks each list's server for something newer than what is here, and
    /// compiles if anything changed. One at a time: a second call while one
    /// is running gets the first one's result.
    @discardableResult
    func update(force: Bool = false) async -> Report {
        if let updating { return await updating.value }
        let task = Task { @MainActor in await self.runUpdate(force: force) }
        updating = task
        let report = await task.value
        updating = nil
        return report
    }

    private func runUpdate(force: Bool) async -> Report {
        var report = Report()
        let enabled = enabledSources
        let clock = ContinuousClock()
        var started = clock.now
        func lap(_ name: String) {
            let elapsed = clock.now - started
            report.seconds[name] = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            started = clock.now
        }

        for list in enabled {
            activity = .downloading(list.name)
            var request = URLRequest(url: list.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let known = state.lists[list.id]
            let haveFile = FileManager.default.fileExists(atPath: fileURL(list).path)
            if haveFile, !force {
                if let etag = known?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let modified = known?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                var entry = known ?? ListState()
                entry.checkedAt = Date()
                if http.statusCode == 304 {
                    report.notModified.append(list.id)
                } else if http.statusCode == 200, let text = String(data: data, encoding: .utf8), RuleSetBuilder.looksLikeFilterList(text) {
                    try data.write(to: fileURL(list), options: .atomic)
                    entry.etag = http.value(forHTTPHeaderField: "ETag")
                    entry.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                    entry.fetchedAt = Date()
                    entry.bytes = data.count
                    report.downloaded.append(list.id)
                } else {
                    // Keep the list that works: what came back is not one.
                    report.failed[list.id] = http.statusCode == 200 ? "what the server sent is not a filter list" : "the server answered \(http.statusCode)"
                }
                state.lists[list.id] = entry
            } catch {
                report.failed[list.id] = error.localizedDescription
            }
        }
        lap("download")

        // Compile from whatever is on disk: a list that could not be
        // refreshed today is still the list from yesterday.
        let files = enabled.map(fileURL)
        let texts = await Task.detached { files.compactMap { try? String(contentsOf: $0, encoding: .utf8) } }.value
        guard !texts.isEmpty else {
            if enabled.isEmpty {
                await install([], fingerprint: nil, enabled: [], built: nil, rejected: 0)
                activity = .idle
            } else {
                activity = .failed(report.failed.values.first.map { "The filter lists could not be downloaded: \($0)." } ?? "The filter lists could not be downloaded.")
            }
            save()
            return report
        }

        let fingerprint = RuleSetBuilder.fingerprint(of: texts)
        if fingerprint == state.fingerprint, !ruleLists.isEmpty, state.enabledLists == enabled.map(\.id) {
            report.reused = true
            report.rules = state.rules
            report.lists = ruleLists.count
            activity = report.failed.isEmpty || !ruleLists.isEmpty ? .idle : .failed("The filter lists could not be downloaded.")
            save()
            return report
        }

        activity = .compiling
        // Selectors are checked by WebKit's CSS parser before any of them
        // share a rule; see SelectorValidator.
        let candidates = await Task.detached { RuleSetBuilder.selectors(in: texts) }.value
        let refused = await SelectorValidator().refused(among: candidates)
        lap("selectors")
        let built = await Task.detached { RuleSetBuilder.build(texts: texts, rejecting: refused) }.value
        lap("parse")
        var compiled: [WKContentRuleList] = []
        var rejected = 0
        // An exception WebKit will not take would fail every list it is
        // added to, so the exceptions are proven on their own first.
        let exceptions = await accepted(built.exceptions, name: "sb-\(fingerprint)-x", rejected: &rejected)
        for (index, start) in stride(from: 0, to: built.actions.count, by: RuleSetBuilder.actionsPerList).enumerated() {
            let actions = Array(built.actions[start ..< min(start + RuleSetBuilder.actionsPerList, built.actions.count)])
            compiled += await compile(actions, exceptions: exceptions, name: "sb-\(fingerprint)-\(index)", rejected: &rejected)
        }
        lap("compile")
        await install(compiled, fingerprint: fingerprint, enabled: enabled.map(\.id), built: built, rejected: rejected)
        report.compiled = true
        report.rules = state.rules
        report.lists = compiled.count
        report.rejected = rejected
        activity = compiled.isEmpty ? .failed("WebKit could not compile the filter lists.") : .idle
        save()
        return report
    }

    /// Compiles `actions` followed by `exceptions`. If WebKit refuses the
    /// list, it is halved until the rules it refuses are found and left out:
    /// one bad rule must not cost thirty thousand good ones.
    private func compile(_ actions: [ContentRule], exceptions: [ContentRule], name: String, rejected: inout Int, depth: Int = 0) async -> [WKContentRuleList] {
        guard !actions.isEmpty else { return [] }
        if let json = try? RuleSetBuilder.json(actions + exceptions),
           let list = try? await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: json) {
            return [list]
        }
        guard actions.count > 1, depth < 24 else {
            // Down to one rule. If it is a shared hiding rule, the trouble
            // is one of its selectors: take it apart and keep the others.
            if actions.count == 1, let separate = FilterParser.separated(actions[0]), depth < 24 {
                return await compile(separate, exceptions: exceptions, name: name + "s", rejected: &rejected, depth: depth + 1)
            }
            rejected += actions.count
            return []
        }
        let middle = actions.count / 2
        let first = await compile(Array(actions[..<middle]), exceptions: exceptions, name: name + "a", rejected: &rejected, depth: depth + 1)
        let second = await compile(Array(actions[middle...]), exceptions: exceptions, name: name + "b", rejected: &rejected, depth: depth + 1)
        return first + second
    }

    /// The exceptions WebKit accepts, found the same way. The lists made
    /// while looking are removed again; only the rules are wanted.
    private func accepted(_ exceptions: [ContentRule], name: String, rejected: inout Int) async -> [ContentRule] {
        guard !exceptions.isEmpty else { return [] }
        // A list of nothing but ignore-previous-rules compiles like any other.
        if let json = try? RuleSetBuilder.json(exceptions),
           (try? await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: json)) != nil {
            try? await store.removeContentRuleList(forIdentifier: name)
            return exceptions
        }
        guard exceptions.count > 1 else {
            rejected += 1
            return []
        }
        let middle = exceptions.count / 2
        let first = await accepted(Array(exceptions[..<middle]), name: name + "a", rejected: &rejected)
        let second = await accepted(Array(exceptions[middle...]), name: name + "b", rejected: &rejected)
        return first + second
    }

    private func install(_ lists: [WKContentRuleList], fingerprint: String?, enabled: [String], built: RuleSetBuilder.Built?, rejected: Int) async {
        let old = Set(state.identifiers).subtracting(lists.map(\.identifier))
        ruleLists = lists
        state.identifiers = lists.map(\.identifier)
        state.fingerprint = lists.isEmpty ? nil : fingerprint
        state.enabledLists = enabled
        state.rules = max(0, (built?.ruleCount ?? 0) - rejected)
        state.refusedSelectors = built?.skipped[.invalidSelector] ?? 0
        state.filters = (built?.networkFilters ?? 0) + (built?.cosmeticFilters ?? 0) + (built?.exceptionFilters ?? 0)
        state.skipped = built?.skippedTotal ?? 0
        state.rejected = rejected
        state.compiledAt = lists.isEmpty ? nil : Date()
        applyToAll()
        for identifier in old { try? await store.removeContentRuleList(forIdentifier: identifier) }
        changed()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// For the self-test: the compiled lists in the store, in use or not.
    func compiledOnDisk() async -> [String] {
        ((await store.availableIdentifiers()) ?? []).sorted()
    }

    // MARK: - For Settings

    /// "Updated today at 14:02 · 93,412 rules", or what is happening now.
    var statusLine: String {
        switch activity {
        case .downloading(let name): return "Downloading \(name)…"
        case .compiling: return "Preparing the rules…"
        case .failed(let reason): return reason
        case .idle: break
        }
        guard let compiled = state.compiledAt, !ruleLists.isEmpty else {
            return isOn ? "The filter lists have not been downloaded yet." : "Content blocking is off."
        }
        let checked = state.lists.values.compactMap(\.checkedAt).max() ?? compiled
        let when = DateFormatter()
        when.doesRelativeDateFormatting = true
        when.dateStyle = .medium
        when.timeStyle = .short
        let count = NumberFormatter.localizedString(from: NSNumber(value: state.rules), number: .decimal)
        return "Updated \(when.string(from: checked).lowercased()) · \(count) rules"
    }

    var isBusy: Bool {
        switch activity {
        case .downloading, .compiling: return true
        case .idle, .failed: return false
        }
    }
}
