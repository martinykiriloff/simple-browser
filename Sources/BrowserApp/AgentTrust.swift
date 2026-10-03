import AppKit
import WebKit
import AgentKit
import BrowserKit

extension Notification.Name {
    /// Paired clients, sessions, approvals or settings changed.
    static let agentTrustDidChange = Notification.Name("Keel.agentTrustDidChange")
}

/// The trust layer, as the app runs it: who is paired, which sessions are
/// live, what is waiting for the person, and the kill switch. AgentKit holds
/// the rules; this holds the state and the files.
@MainActor
final class AgentTrust {

    // MARK: Settings

    struct Settings: Codable, Equatable {
        var defaultMode: SessionMode.Kind = .sandbox
        var policy: ApprovalPolicy = .askEveryTime
        var budgets: Budgets = .default
        /// No answer within this: the agent hears "denied" and the tab stays paused.
        var approvalTimeoutSeconds: Int = 120
        /// Ask for any action that a page's text, not the person, seems to have asked for.
        var pageInstructionsAlwaysAsk = true
        /// WebMCP: pages may offer tools (AR-9). Off by default while the draft changes.
        var webMCP = false
        var logRetentionDays = 30
    }

    /// Scripted runs (`--agent-approve all|deny`): answer approvals without asking.
    var autoAnswer: String?

    // MARK: Live sessions

    /// One connected client's session, and what the app keeps for it.
    @MainActor
    final class Live {
        var session: AgentSession
        var log = AuditLog()
        /// The tabs this session opened or was handed, in order.
        var tabs: [Weak<BrowserWindowController>] = []
        /// The in-memory data store of a sandbox session.
        var sandbox: PrivateSession?
        weak var currentTab: BrowserWindowController?
        /// The tab group the session's tabs share, named after it.
        var groupID: TabGroupID?
        /// MCP session ids (one per `initialize`) that map to this session.
        var transportIDs: Set<String> = []
        var lastActivity = Date()

        init(session: AgentSession) { self.session = session }

        var openTabs: [BrowserWindowController] {
            tabs.removeAll { $0.value == nil || $0.value?.window == nil }
            return tabs.compactMap(\.value)
        }

        func owns(_ tab: BrowserWindowController) -> Bool { openTabs.contains { $0 === tab } }

        func adopt(_ tab: BrowserWindowController) {
            guard !owns(tab) else { return }
            tabs.append(Weak(tab))
            tab.agentSessionID = session.id
        }
    }

    /// An action waiting for the person's OK.
    @MainActor
    final class PendingApproval: Identifiable {
        let id = UUID()
        let sessionID: String
        let clientName: String
        let tool: String
        let risk: ActionRisk
        let origin: String?
        /// "click e14 “Place order · €84.00”".
        let target: String
        let ref: String?
        weak var tab: BrowserWindowController?
        /// Text found on the page that reads like an instruction to an agent.
        let pageInstruction: String?
        let created = Date()
        let actionsUsed: Int
        let actionsBudget: Int
        fileprivate var continuation: CheckedContinuation<AgentSession.Decision, Never>?

        init(sessionID: String, clientName: String, tool: String, risk: ActionRisk, origin: String?, target: String, ref: String?,
             tab: BrowserWindowController?, pageInstruction: String?, actionsUsed: Int, actionsBudget: Int) {
            self.sessionID = sessionID; self.clientName = clientName; self.tool = tool; self.risk = risk; self.origin = origin
            self.target = target; self.ref = ref; self.tab = tab; self.pageInstruction = pageInstruction
            self.actionsUsed = actionsUsed; self.actionsBudget = actionsBudget
        }
    }

    /// A pairing a client asked for over `/pair`, waiting for the person.
    @MainActor
    final class PendingPairing {
        let request: PairingRequest
        let remote: String
        fileprivate var continuation: CheckedContinuation<(client: PairedClient, token: String)?, Never>?
        init(request: PairingRequest, remote: String) { self.request = request; self.remote = remote }
    }

    /// What Stop & revoke did, for the summary the person sees (G2-06).
    struct StopSummary {
        var time = Date()
        var clients: [String] = []
        var tokens: [String] = []
        var sessions: [(id: String, tabs: Int, sandbox: Bool)] = []
        var actions = 0
        var completed = 0
        var denied = 0
        var cancelledApprovals = 0
        var viaShortcut = false
    }

    // MARK: State

    private(set) var registry = ClientRegistry()
    var rules = OriginRules() { didSet { saveRules(); changed() } }
    var settings = Settings() { didSet { saveSettings(); changed() } }
    private(set) var sessions: [String: Live] = [:]
    private(set) var approvals: [PendingApproval] = []
    private(set) var pairings: [PendingPairing] = []
    /// Ended sessions, newest first, for the new-tab page and the log window.
    private(set) var history: [SessionRecord] = []
    var webMCP = WebMCPRegistry()

    struct SessionRecord: Codable, Equatable {
        var id: String
        var client: String
        var mode: String
        var started: Date
        var ended: Date?
        var actions: Int
        var lastSummary: String
        var outcome: String   // running | waiting | done | failed | stopped
        var logFile: String
    }

    // MARK: Hooks the app sets

    /// Opens a tab for a session: in its sandbox window, or a borrowed window.
    var openTab: ((_ live: Live, _ url: URL?, _ inFront: Bool) -> BrowserWindowController?)?
    /// Shows a pairing request to the person (G2-01).
    var presentPairing: ((PendingPairing) -> Void)?
    /// Shows what Stop & revoke did (G2-06).
    var presentStopSummary: ((StopSummary) -> Void)?
    /// Closes the tabs and windows of a session.
    var closeTabs: (([BrowserWindowController]) -> Void)?
    /// Scripted runs (`--agent-hand-tab`): the tab handed to the command-line
    /// client's session when it connects, as Hand Tab to Agent… would.
    var handOnConnect: (() -> BrowserWindowController?)?

    private let directory: URL
    private var expiryTimer: Timer?

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Scripted runs keep their sessions and logs out of the person's folder.
        let scripted = ProcessInfo.processInfo.environment["KEEL_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? scripted ?? support.appendingPathComponent("Keel/Agents", isDirectory: true)
        load()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .agentTrustDidChange, object: self)
    }

    // MARK: - Files

    private var clientsFile: URL { directory.appendingPathComponent("clients.json") }
    private var rulesFile: URL { directory.appendingPathComponent("rules.json") }
    private var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    private var historyFile: URL { directory.appendingPathComponent("sessions.json") }
    var logsDirectory: URL { directory.appendingPathComponent("Logs", isDirectory: true) }

    private func load() {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let decoder = AuditLog.decoder
        if let data = try? Data(contentsOf: clientsFile), let saved = try? decoder.decode(ClientRegistry.self, from: data) { registry = saved }
        if let data = try? Data(contentsOf: rulesFile), let saved = try? decoder.decode(OriginRules.self, from: data) { rules = saved }
        if let data = try? Data(contentsOf: settingsFile), let saved = try? decoder.decode(Settings.self, from: data) { settings = saved }
        if let data = try? Data(contentsOf: historyFile), let saved = try? decoder.decode([SessionRecord].self, from: data) { history = saved }
        // The token from before pairing keeps working, as a client of its own.
        if let legacy = UserDefaults.standard.string(forKey: "agent.token"), legacy.count >= 32, !UserDefaults.standard.bool(forKey: "agent.tokenAdopted") {
            registry.adoptLegacy(token: legacy)
            UserDefaults.standard.set(true, forKey: "agent.tokenAdopted")
            saveClients()
        }
        pruneLogs()
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? AuditLog.encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
        // The folder holds who may drive the browser: the person's eyes only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func saveClients() { write(registry, to: clientsFile) }
    private func saveRules() { write(rules, to: rulesFile) }
    private func saveSettings() { write(settings, to: settingsFile) }
    private func saveHistory() { write(Array(history.prefix(200)), to: historyFile) }

    private func pruneLogs() {
        registry.prune(olderThan: settings.logRetentionDays)
        let cutoff = Date().addingTimeInterval(-Double(settings.logRetentionDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
        history.removeAll { ($0.ended ?? .distantFuture) < cutoff }
    }

    // MARK: - Clients

    var clients: [PairedClient] { registry.clients }

    /// The client a bearer token belongs to.
    func authenticate(_ token: String) -> PairedClient? { registry.authenticate(token) }

    /// Pairs a client the person set up from the app, and returns its token.
    @discardableResult
    func pair(name: String, scope: ToolScope = .all) -> (client: PairedClient, token: String) {
        let paired = registry.pair(name: name, scope: scope)
        registry.update(paired.client.id) {
            $0.defaultMode = settings.defaultMode
            $0.approvalPolicy = settings.policy
            $0.budgets = settings.budgets
        }
        AgentTokenKeychain.set(paired.token, for: paired.client.id)
        saveClients()
        changed()
        return (registry.client(id: paired.client.id)!, paired.token)
    }

    func updateClient(_ id: String, _ change: (inout PairedClient) -> Void) {
        registry.update(id, change)
        saveClients()
        if let client = registry.client(id: id) {
            for live in sessions.values where live.session.clientID == id {
                live.session.policy = client.approvalPolicy
                live.session.budgets = client.budgets
                live.session.allowedOrigins = client.allowedOrigins
                if client.paused, live.session.state == .running { live.session.state = .paused }
                if !client.paused, live.session.state == .paused { live.session.state = .running }
            }
        }
        changed()
    }

    func touch(_ id: String) {
        registry.touch(id)
        saveClients()
    }

    /// The token, for showing the set-up command again.
    func token(for id: String) -> String? { AgentTokenKeychain.token(for: id) }

    func revoke(_ id: String) {
        registry.revoke(id)
        AgentTokenKeychain.remove(id)
        for live in sessions.values where live.session.clientID == id { end(live, outcome: "stopped") }
        saveClients()
        changed()
    }

    // MARK: - Pairing over HTTP

    /// A client asked to pair (`keel pair`, or `POST /pair`): wait for the person.
    func requestPairing(clientName: String, version: String?, processID: Int?, remote: String) async -> (client: PairedClient, token: String)? {
        let pending = PendingPairing(request: PairingRequest(clientName: clientName, clientVersion: version, processID: processID), remote: remote)
        pairings.append(pending)
        changed()
        presentPairing?(pending)
        let answer = await withCheckedContinuation { continuation in
            pending.continuation = continuation
            Task { @MainActor [weak self, weak pending] in
                try? await Task.sleep(for: .seconds(PairingRequest.lifetime))
                if let pending { self?.answer(pending, approve: false) }
            }
        }
        return answer
    }

    /// The person's answer to a pairing request.
    func answer(_ pending: PendingPairing, approve: Bool, name: String? = nil, scope: ToolScope = .all) {
        guard let continuation = pending.continuation else { return }
        pending.continuation = nil
        pairings.removeAll { $0 === pending }
        if approve, !pending.request.isExpired() {
            continuation.resume(returning: pair(name: name ?? pending.request.clientName, scope: scope))
        } else {
            continuation.resume(returning: nil)
        }
        changed()
    }

    // MARK: - Sessions

    /// The live session of a client, begun on its first call.
    func session(for client: PairedClient, transport: String?) -> Live {
        if let transport, let live = sessions.values.first(where: { $0.transportIDs.contains(transport) }),
           live.session.state != .stopped {
            return live
        }
        if let live = sessions.values.first(where: { $0.session.clientID == client.id && $0.session.state != .stopped }) {
            if let transport { live.transportIDs.insert(transport) }
            return live
        }
        var session = AgentSession(clientID: client.id, clientName: AgentServer.friendlyName(client.name), mode: .sandbox,
                                   policy: client.approvalPolicy, budgets: client.budgets, allowedOrigins: client.allowedOrigins)
        while sessions[session.id] != nil { session.id = AgentSession.makeID() }
        if client.paused { session.state = .paused }
        let live = Live(session: session)
        if let transport { live.transportIDs.insert(transport) }
        sessions[session.id] = live
        if client.id == "cli0", let tab = handOnConnect?(), let origin = tab.currentURL.flatMap(Origin.of) {
            live.session.mode = .borrowed(origins: [origin], expires: nil)
            live.adopt(tab)
        }
        history.insert(SessionRecord(id: session.id, client: session.clientName, mode: "sandbox", started: session.started, ended: nil,
                                     actions: 0, lastSummary: "Connected", outcome: "running", logFile: logFile(for: session).lastPathComponent), at: 0)
        saveHistory()
        changed()
        return live
    }

    func live(_ id: String?) -> Live? { id.flatMap { sessions[$0] } }

    /// The session a tab belongs to, if an agent owns it.
    func live(for tab: BrowserWindowController) -> Live? {
        tab.agentSessionID.flatMap { sessions[$0] }
    }

    var runningCount: Int { sessions.values.filter { $0.session.state != .stopped }.count }

    func logFile(for session: AgentSession) -> URL {
        let day = ISO8601DateFormatter.string(from: session.started, timeZone: .current, formatOptions: [.withFullDate])
        return logsDirectory.appendingPathComponent("\(day)-\(session.id).jsonl")
    }

    /// Appends to the session's log and its file, which only ever grows.
    @discardableResult
    func audit(_ live: Live, tool: String, arguments: JSONValue, url: URL?, outcome: AuditEntry.Outcome, errorCode: String? = nil,
               summary: String? = nil, milliseconds: Int = 0, resultTokens: Int = 0) -> AuditEntry {
        let entry = live.log.append(sessionID: live.session.id, clientName: live.session.clientName, tool: tool, arguments: Self.redact(arguments),
                                    url: url?.absoluteString, outcome: outcome, errorCode: errorCode,
                                    summary: summary ?? AuditSummary.describe(tool: tool, arguments: arguments),
                                    milliseconds: milliseconds, resultTokens: resultTokens)
        let file = logFile(for: live.session)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(AuditLog.jsonLine(entry))
            try? handle.close()
        } else {
            try? AuditLog.jsonLine(entry).write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        live.lastActivity = Date()
        if let index = history.firstIndex(where: { $0.id == live.session.id }) {
            history[index].actions = live.session.actions
            history[index].lastSummary = entry.summary
            history[index].mode = live.session.mode.kind.rawValue
            history[index].outcome = live.session.state == .stopped ? history[index].outcome
                : approvals.contains { $0.sessionID == live.session.id } ? "waiting" : "running"
            saveHistory()
        }
        changed()
        return entry
    }

    /// Passwords and card numbers an agent typed are not written to disk.
    static func redact(_ arguments: JSONValue) -> JSONValue {
        guard var object = arguments.object else { return arguments }
        for key in ["value", "text"] {
            if let value = object[key]?.string, ActionClassifier.looksLikeSecret(value) { object[key] = "••••" }
        }
        if let fields = object["fields"]?.array {
            object["fields"] = .array(fields.map { redact($0) })
        }
        return .object(object)
    }

    /// Ends a session: its sandbox data is wiped and its tabs close.
    func end(_ live: Live, outcome: String) {
        live.session.state = .stopped
        for approval in approvals where approval.sessionID == live.session.id { resolve(approval, .stop) }
        let tabs = live.openTabs
        closeTabs?(tabs)
        if let sandbox = live.sandbox {
            sandbox.dataStore.removeData(ofTypes: WKWebsiteDataStoreTypes.all, modifiedSince: .distantPast) {}
            live.sandbox = nil
        }
        webMCP = tabs.reduce(into: webMCP) { $0.clear(tab: $1.tab.rawValue.uuidString) }
        sessions[live.session.id] = nil
        if let index = history.firstIndex(where: { $0.id == live.session.id }) {
            history[index].ended = Date()
            history[index].outcome = outcome
            history[index].actions = live.session.actions
            saveHistory()
        }
        changed()
    }

    // MARK: - Identity

    /// Lends origins of the person's profile to a session (G2-04). The
    /// session's sandbox tabs close; later tabs open in a borrowed window.
    func lend(_ live: Live, origins: [String], minutes: Int?) {
        let lendable = origins.map(Origin.normalize).filter { !NeverLendable.contains($0) && rules.rule(for: $0) != .never }
        guard !lendable.isEmpty else { return }
        let expires = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        let sandboxTabs = live.sandbox == nil ? [] : live.openTabs
        live.session.mode = .borrowed(origins: lendable, expires: expires)
        if !sandboxTabs.isEmpty {
            live.tabs.removeAll()
            closeTabs?(sandboxTabs)
        }
        audit(live, tool: "lend", arguments: ["origins": .array(lendable.map(JSONValue.string)), "minutes": minutes.map { .number(Double($0)) } ?? .null],
              url: nil, outcome: .approved, summary: "You lent \(lendable.joined(separator: ", "))" + (minutes.map { " for \($0) min" } ?? ""))
        changed()
    }

    /// Back to a sandbox: borrowed tabs close, nothing of the person's stays reachable.
    func endBorrowing(_ live: Live) {
        guard live.session.mode.kind == .borrowed else { return }
        let tabs = live.openTabs
        live.tabs.removeAll()
        closeTabs?(tabs)
        live.session.mode = .sandbox
        audit(live, tool: "lend", arguments: [:], url: nil, outcome: .ok, summary: "Borrowing ended")
        changed()
    }

    // MARK: - Approvals

    /// Asks the person, and waits. Never returns `allow` without them unless
    /// a scripted run said so on the command line.
    func requestApproval(_ live: Live, tool: String, risk: ActionRisk, origin: String?, target: String, ref: String?,
                         tab: BrowserWindowController?, pageInstruction: String?) async -> AgentSession.Decision {
        if let auto = autoAnswer {
            return auto == "all" ? .allowOnce : .deny
        }
        let pending = PendingApproval(sessionID: live.session.id, clientName: live.session.clientName, tool: tool, risk: risk, origin: origin,
                                      target: target, ref: ref, tab: tab, pageInstruction: pageInstruction,
                                      actionsUsed: live.session.actions, actionsBudget: live.session.budgets.maxActions)
        approvals.append(pending)
        audit(live, tool: tool, arguments: ["target": .string(target)], url: tab?.currentURL, outcome: .waiting, summary: "Waiting for approval")
        tab?.presentAgentApproval(pending, trust: self)
        if NSApp.isActive == false { NSApp.requestUserAttention(.criticalRequest) }
        changed()
        let timeout = settings.approvalTimeoutSeconds
        let decision = await withCheckedContinuation { continuation in
            pending.continuation = continuation
            Task { @MainActor [weak self, weak pending] in
                try? await Task.sleep(for: .seconds(timeout))
                if let pending { self?.resolve(pending, .timedOut) }
            }
        }
        live.session.record(decision, for: risk, origin: origin)
        return decision
    }

    /// The person answered (or the time ran out).
    func resolve(_ pending: PendingApproval, _ decision: AgentSession.Decision) {
        guard let continuation = pending.continuation else { return }
        pending.continuation = nil
        approvals.removeAll { $0 === pending }
        pending.tab?.dismissAgentApproval(pending)
        continuation.resume(returning: decision)
        if decision == .stop, let live = sessions[pending.sessionID] {
            let client = live.session.clientID
            Task { @MainActor in self.stopAndRevoke(clientIDs: [client]) }
        }
        changed()
    }

    func approvals(for tab: BrowserWindowController) -> [PendingApproval] { approvals.filter { $0.tab === tab } }

    // MARK: - Handing over (AR-7)

    private var handoffs: [String: CheckedContinuation<String, Never>] = [:]

    /// The agent asked the person to take over; waits until they hand back.
    func handOver(_ live: Live, reason: String, message: String, tab: BrowserWindowController?, timeout: Double) async -> String {
        live.session.state = .needsHuman(reason: message)
        tab?.showAgentHandoff(message: message, client: live.session.clientName) { [weak self, weak live] note in
            guard let self, let live else { return }
            self.handBack(live, note: note)
        }
        if let window = tab?.window { window.makeKeyAndOrderFront(nil); NSApp.activate() }
        changed()
        let id = live.session.id
        return await withCheckedContinuation { continuation in
            handoffs[id] = continuation
            Task { @MainActor [weak self, weak live] in
                try? await Task.sleep(for: .seconds(timeout))
                if let self, let live, self.handoffs[id] != nil { self.handBack(live, note: "timeout") }
            }
        }
    }

    func handBack(_ live: Live, note: String) {
        if case .needsHuman = live.session.state { live.session.state = .running }
        for tab in live.openTabs { tab.hideAgentHandoff() }
        handoffs.removeValue(forKey: live.session.id)?.resume(returning: note)
        changed()
    }

    // MARK: - Kill switch (T6)

    var isPausedAll: Bool { !sessions.isEmpty && sessions.values.allSatisfy { $0.session.state == .paused || $0.session.state == .stopped } }

    func pause(_ live: Live) {
        guard live.session.state == .running else { return }
        live.session.state = .paused
        audit(live, tool: "pause", arguments: [:], url: nil, outcome: .ok, summary: "You paused the agent")
    }

    func resume(_ live: Live) {
        guard live.session.state == .paused else { return }
        live.session.state = .running
        audit(live, tool: "resume", arguments: [:], url: nil, outcome: .ok, summary: "You resumed the agent")
    }

    /// Pause all agents (⇧⌘.), or resume them all when all are paused.
    func togglePauseAll() {
        if isPausedAll { sessions.values.forEach(resume) } else { sessions.values.forEach(pause) }
        changed()
    }

    /// Stop & revoke: tokens deleted, sessions ended, sandboxes wiped, and
    /// the person told what happened.
    func stopAndRevoke(clientIDs: [String]? = nil, viaShortcut: Bool = false) {
        let targets = clientIDs ?? registry.active.map(\.id)
        var summary = StopSummary()
        summary.viaShortcut = viaShortcut
        for live in sessions.values where targets.contains(live.session.clientID) {
            summary.sessions.append((live.session.id, live.openTabs.count, live.session.mode.kind == .sandbox))
            summary.actions += live.log.entries.count { $0.outcome != .waiting }
            summary.completed += live.log.entries.count { $0.outcome == .ok || $0.outcome == .approved }
            summary.denied += live.log.entries.count { $0.outcome == .denied || $0.outcome == .blocked }
            summary.cancelledApprovals += approvals.count { $0.sessionID == live.session.id }
            audit(live, tool: "stop", arguments: [:], url: nil, outcome: .blocked, summary: "You stopped the agent and revoked its token")
            end(live, outcome: "stopped")
        }
        for id in targets {
            guard let client = registry.client(id: id), client.isActive else { continue }
            summary.clients.append(AgentServer.friendlyName(client.name))
            summary.tokens.append("keel_…" + client.tokenHint)
            registry.revoke(id)
            AgentTokenKeychain.remove(id)
        }
        for pending in pairings { answer(pending, approve: false) }
        saveClients()
        changed()
        if !summary.clients.isEmpty || !summary.sessions.isEmpty { presentStopSummary?(summary) }
    }

    // MARK: - Expiry

    private func tick() {
        let now = Date()
        for live in sessions.values {
            if now >= live.session.expires {
                audit(live, tool: "expire", arguments: [:], url: nil, outcome: .blocked, errorCode: "session_expired",
                      summary: live.session.mode.kind == .borrowed ? "The borrowed session ended" : "The session reached its time limit")
                end(live, outcome: "done")
            } else if live.session.mode.kind == .borrowed {
                for tab in live.openTabs { tab.syncAgentChrome() }
            }
        }
    }
}

/// A weak reference that can sit in an array.
struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

enum WKWebsiteDataStoreTypes {
    @MainActor static var all: Set<String> { WKWebsiteDataStore.allWebsiteDataTypes() }
}

/// Paired clients' tokens, in the login Keychain: never in a file.
enum AgentTokenKeychain {
    private static let service = "Keel agent token"

    static func token(for id: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ token: String, for id: String) {
        remove(id)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: id, kSecValueData as String: Data(token.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove(_ id: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        SecItemDelete(query as CFDictionary)
    }
}
