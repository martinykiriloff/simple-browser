import Foundation

/// Whose cookies an agent session acts with.
public enum SessionMode: Sendable, Equatable {
    /// A fresh, in-memory profile: nothing of the person's. The default.
    case sandbox
    /// The person's profile, limited to named origins until `expires`.
    case borrowed(origins: [String], expires: Date?)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sandbox, borrowed
    }

    public var kind: Kind {
        switch self {
        case .sandbox: return .sandbox
        case .borrowed: return .borrowed
        }
    }

    public var origins: [String] {
        if case .borrowed(let origins, _) = self { return origins }
        return []
    }

    public var expires: Date? {
        if case .borrowed(_, let expires) = self { return expires }
        return nil
    }
}

/// When a consequential action needs the person's OK.
public enum ApprovalPolicy: String, Codable, Sendable, CaseIterable {
    /// Every payment, send, delete and upload shows an approval card.
    case askEveryTime
    /// One approval per kind of action and origin, for the rest of the session.
    case askOncePerOrigin
    /// No prompts in a sandbox session, where nothing is the person's.
    /// Borrowed sessions still ask every time.
    case allowWithinSandbox

    public var label: String {
        switch self {
        case .askEveryTime: return "Ask every time"
        case .askOncePerOrigin: return "Ask once per origin"
        case .allowWithinSandbox: return "Allow within sandbox"
        }
    }
}

/// Limits on one session (T6): a runaway agent stops on its own.
public struct Budgets: Codable, Sendable, Equatable {
    /// Tool calls that act on a page (reads are free).
    public var maxActions: Int
    public var navigationsPerMinute: Int
    /// The default size cap of a snapshot, in estimated tokens.
    public var snapshotTokens: Int
    /// Wall-clock life of a session, in minutes.
    public var timeLimitMinutes: Int
    /// Tabs a session may have open at once.
    public var maxTabs: Int

    public static let `default` = Budgets(maxActions: 200, navigationsPerMinute: 30, snapshotTokens: 8_000, timeLimitMinutes: 60, maxTabs: 10)

    public init(maxActions: Int, navigationsPerMinute: Int, snapshotTokens: Int, timeLimitMinutes: Int, maxTabs: Int) {
        self.maxActions = maxActions; self.navigationsPerMinute = navigationsPerMinute
        self.snapshotTokens = snapshotTokens; self.timeLimitMinutes = timeLimitMinutes; self.maxTabs = maxTabs
    }
}

/// One connected agent's session: its identity, its budgets, what it has
/// been allowed, and whether it may run at all.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case running
        /// The person paused it; calls are refused as retryable until resumed.
        case paused
        /// The agent handed over to the person (login, CAPTCHA, payment).
        case needsHuman(reason: String)
        case stopped
    }

    /// Four hex characters ("session a91f").
    public var id: String
    public var clientID: String
    public var clientName: String
    public var mode: SessionMode
    public var policy: ApprovalPolicy
    public var budgets: Budgets
    /// Strict mode (T3): navigation only to these origins. Empty: anywhere
    /// (a borrowed session is always limited to its origins).
    public var allowedOrigins: [String]
    public var started: Date
    public var state: State = .running
    public private(set) var actions = 0
    public private(set) var navigations: [Date] = []
    /// "kind@origin" → until when it is allowed without asking.
    public private(set) var standingApprovals: [String: Date] = [:]
    public private(set) var denied = 0
    public private(set) var approved = 0

    public init(id: String = AgentSession.makeID(), clientID: String, clientName: String, mode: SessionMode = .sandbox,
                policy: ApprovalPolicy = .askEveryTime, budgets: Budgets = .default, allowedOrigins: [String] = [], started: Date = Date()) {
        self.id = id; self.clientID = clientID; self.clientName = clientName; self.mode = mode
        self.policy = policy; self.budgets = budgets; self.allowedOrigins = allowedOrigins; self.started = started
    }

    public static func makeID() -> String { String(format: "%04x", UInt16.random(in: .min ... .max)) }

    public var expires: Date {
        let limit = started.addingTimeInterval(Double(budgets.timeLimitMinutes) * 60)
        if let borrowed = mode.expires { return min(limit, borrowed) }
        return limit
    }

    public var actionsLeft: Int { max(0, budgets.maxActions - actions) }

    // MARK: Admission

    /// What a tool call is about to do, as far as the trust layer cares.
    public struct Call: Sendable, Equatable {
        public var tool: String
        public var readOnly: Bool
        /// The page the call acts on, if any.
        public var pageURL: URL?
        /// Where a navigation goes, for `navigate` and `new_tab`.
        public var destination: URL?

        public init(tool: String, readOnly: Bool, pageURL: URL? = nil, destination: URL? = nil) {
            self.tool = tool; self.readOnly = readOnly; self.pageURL = pageURL; self.destination = destination
        }
    }

    /// Whether the call may run now. Counts it against the budgets when it may.
    /// Approval of consequential actions is decided separately, by `needsApproval`,
    /// once the target element is known.
    public mutating func admit(_ call: Call, now: Date = Date()) -> AgentError? {
        switch state {
        case .stopped: return AgentError(.sessionStopped, "This agent session was stopped by the person. Pair again to continue.")
        case .paused: return AgentError(.sessionPaused, "The person paused this agent. Wait, then try again.")
        case .needsHuman(let reason): return AgentError(.needsHuman, "Waiting for the person: \(reason). Try again once they hand control back.")
        case .running: break
        }
        if now >= expires {
            state = .stopped
            return AgentError(.sessionExpired, mode.expires.map { $0 <= now } == true
                              ? "The borrowed session ended. Ask the person to lend the origin again."
                              : "The session reached its \(budgets.timeLimitMinutes)-minute limit.")
        }
        if let destination = call.destination, let problem = originProblem(destination) { return problem }
        if let page = call.pageURL, page.scheme?.hasPrefix("http") == true, mode.kind == .borrowed, !Origin.matches(page, any: mode.origins) {
            return AgentError(.originBlocked, "\(Origin.of(page) ?? page.absoluteString) is not one of the origins lent to this session.")
        }
        if call.readOnly { return nil }
        guard actions < budgets.maxActions else {
            return AgentError(.budgetExhausted, "This session used all \(budgets.maxActions) actions. Ask the person to raise the budget or start a new session.")
        }
        if call.destination != nil {
            navigations.removeAll { now.timeIntervalSince($0) > 60 }
            guard navigations.count < budgets.navigationsPerMinute else {
                return AgentError(.rateLimited, "More than \(budgets.navigationsPerMinute) navigations in a minute. Slow down and retry.", retryAfterMs: 5_000)
            }
            navigations.append(now)
        }
        actions += 1
        return nil
    }

    /// Navigation to a destination this session may not reach.
    public func originProblem(_ destination: URL) -> AgentError? {
        guard let scheme = destination.scheme?.lowercased() else { return nil }
        if scheme == "about" || scheme == "data" || scheme == "blob" { return nil }
        if scheme == "file" { return AgentError(.originBlocked, "Agents may not open files from this Mac.") }
        if scheme == "javascript" { return AgentError(.originBlocked, "javascript: URLs are refused; use evaluate.") }
        if mode.kind == .borrowed, !Origin.matches(destination, any: mode.origins) {
            return AgentError(.originBlocked, "\(Origin.of(destination) ?? destination.absoluteString) is outside the origins lent to this session: \(mode.origins.joined(separator: ", ")).")
        }
        if !allowedOrigins.isEmpty, !Origin.matches(destination, any: allowedOrigins) {
            return AgentError(.originBlocked, "\(Origin.of(destination) ?? destination.absoluteString) is not on this agent's allowlist. Navigation was blocked and logged.")
        }
        return nil
    }

    // MARK: Approval

    /// Whether an action of this risk needs the person's OK now.
    public func needsApproval(_ risk: ActionRisk, origin: String?, rules: OriginRules = OriginRules(), now: Date = Date()) -> Bool {
        guard case .consequential(let kind, _) = risk else { return false }
        if kind == .crossProfile { return true }
        if let origin, let rule = rules.rule(for: origin, now: now) {
            switch rule {
            case .never: return true   // `refusal` refuses it before it gets here
            case .allow: return kind == .payment || kind == .credential   // money and passwords always ask
            case .ask: break
            }
        }
        if let origin, let until = standingApprovals[Self.key(kind, origin)], until > now { return false }
        switch policy {
        case .askEveryTime, .askOncePerOrigin: return true
        case .allowWithinSandbox: return mode.kind != .sandbox
        }
    }

    /// An origin rule of "never": refused without asking.
    public func refusal(_ risk: ActionRisk, origin: String?, rules: OriginRules, now: Date = Date()) -> AgentError? {
        guard case .consequential(let kind, _) = risk, let origin, rules.rule(for: origin, now: now) == .never else { return nil }
        return AgentError(.approvalDenied, "The person never allows \(kind.label) on \(origin).")
    }

    public enum Decision: Sendable, Equatable {
        case allowOnce
        /// Allowed for this kind of action on this origin, until the date.
        case allowOnOrigin(until: Date)
        case deny
        case timedOut
        /// Stop & revoke.
        case stop
    }

    public mutating func record(_ decision: Decision, for risk: ActionRisk, origin: String?, now: Date = Date()) {
        guard case .consequential(let kind, _) = risk else { return }
        switch decision {
        case .allowOnce:
            approved += 1
            if policy == .askOncePerOrigin, let origin { standingApprovals[Self.key(kind, origin)] = expires }
        case .allowOnOrigin(let until):
            approved += 1
            if let origin { standingApprovals[Self.key(kind, origin)] = until }
        case .deny, .timedOut:
            denied += 1
        case .stop:
            denied += 1
            state = .stopped
        }
    }

    static func key(_ kind: ActionRisk.Kind, _ origin: String) -> String { "\(kind.rawValue)@\(origin)" }
}

/// Origins as the trust layer compares them: scheme-less host[:port],
/// lowercased, so "https://Shop.acme.test/x" and "shop.acme.test" match.
public enum Origin {
    public static func of(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil
        if let port = url.port, port != defaultPort { return "\(host):\(port)" }
        return host
    }

    /// "https://Shop.acme.test/" → "shop.acme.test"; "localhost:3000" stays.
    public static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if value.hasSuffix(":443") || value.hasSuffix(":80") { value = String(value[..<value.lastIndex(of: ":")!]) }
        return value
    }

    /// Exact origin match, or a "*.example.com" pattern for its subdomains.
    public static func matches(_ url: URL, any patterns: [String]) -> Bool {
        guard let origin = of(url) else { return false }
        return patterns.contains { matches(origin, pattern: $0) }
    }

    public static func matches(_ origin: String, pattern: String) -> Bool {
        let pattern = normalize(pattern)
        if pattern.hasPrefix("*.") {
            let base = String(pattern.dropFirst(2))
            return origin == base || origin.hasSuffix("." + base)
        }
        return origin == pattern
    }
}
