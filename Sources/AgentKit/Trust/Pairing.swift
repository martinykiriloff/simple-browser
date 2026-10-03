import Foundation
import CryptoKit

/// Which tools a paired client may see and call.
public enum ToolScope: String, Codable, Sendable, CaseIterable {
    /// Every tool in the catalog.
    case all
    /// Only tools that read: no navigation, no input, no change to the page.
    case readOnly

    public var label: String {
        switch self {
        case .all: return "all tools"
        case .readOnly: return "read-only tools"
        }
    }
}

/// One MCP client the person has paired: its own token, its own grants, and
/// revocable on its own. The token itself is never kept here, only its hash;
/// the app keeps the token in the Keychain.
public struct PairedClient: Codable, Sendable, Equatable, Identifiable {
    /// Four hex characters, as the person sees it ("pairing 7c2e").
    public var id: String
    public var name: String
    /// SHA-256 of the token, hex.
    public var tokenHash: String
    /// The token's last four characters, to tell tokens apart ("sb_…c4e1").
    public var tokenHint: String
    public var pairedAt: Date
    public var lastUsed: Date?
    public var revokedAt: Date?
    /// Paused clients authenticate but every call is refused as `session_paused`.
    public var paused: Bool
    public var scope: ToolScope
    /// The identity a new session of this client starts with.
    public var defaultMode: SessionMode.Kind
    public var approvalPolicy: ApprovalPolicy
    public var budgets: Budgets
    /// Navigation outside these origins is blocked (strict mode, T3). Empty: no allowlist.
    public var allowedOrigins: [String]

    public var isActive: Bool { revokedAt == nil }

    public init(id: String, name: String, tokenHash: String, tokenHint: String, pairedAt: Date,
                scope: ToolScope = .all, defaultMode: SessionMode.Kind = .sandbox,
                approvalPolicy: ApprovalPolicy = .askEveryTime, budgets: Budgets = .default, allowedOrigins: [String] = []) {
        self.id = id; self.name = name; self.tokenHash = tokenHash; self.tokenHint = tokenHint; self.pairedAt = pairedAt
        self.paused = false; self.scope = scope; self.defaultMode = defaultMode
        self.approvalPolicy = approvalPolicy; self.budgets = budgets; self.allowedOrigins = allowedOrigins
    }
}

/// The paired clients, persisted by the app as JSON.
public struct ClientRegistry: Codable, Sendable, Equatable {
    public static let tokenPrefix = "keel_"

    public private(set) var clients: [PairedClient] = []

    public init(clients: [PairedClient] = []) { self.clients = clients }

    public var active: [PairedClient] { clients.filter(\.isActive) }

    public func client(id: String) -> PairedClient? { clients.first { $0.id == id } }

    /// Pairs a new client and returns its token. The token is shown to the
    /// client once; only its hash is kept.
    public mutating func pair(name: String, scope: ToolScope = .all, now: Date = Date(),
                              token: String = ClientRegistry.makeToken()) -> (client: PairedClient, token: String) {
        var id = Self.makeID()
        while clients.contains(where: { $0.id == id }) { id = Self.makeID() }
        let client = PairedClient(id: id, name: name, tokenHash: Self.hash(token), tokenHint: String(token.suffix(4)),
                                  pairedAt: now, scope: scope)
        clients.append(client)
        return (client, token)
    }

    /// Adopts a token made before pairing existed (the old shared token), so
    /// clients set up with it keep working until the person revokes it.
    public mutating func adoptLegacy(token: String, now: Date = Date()) {
        guard !token.isEmpty, authenticate(token) == nil, !clients.contains(where: { $0.tokenHash == Self.hash(token) }) else { return }
        _ = pair(name: "Shared token (before pairing)", now: now, token: token)
    }

    /// The active client that holds this token, or nil. Comparison is
    /// constant-time over the hashes.
    public func authenticate(_ token: String) -> PairedClient? {
        let presented = Self.hash(token)
        var found: PairedClient?
        for client in clients where client.isActive {
            if AgentAccessPolicy.constantTimeEquals(presented, client.tokenHash) { found = client }
        }
        return found
    }

    public mutating func update(_ id: String, _ change: (inout PairedClient) -> Void) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        change(&clients[index])
    }

    public mutating func touch(_ id: String, now: Date = Date()) {
        update(id) { $0.lastUsed = now }
    }

    public mutating func revoke(_ id: String, now: Date = Date()) {
        update(id) { if $0.revokedAt == nil { $0.revokedAt = now } }
    }

    /// Stop & revoke all: every active client loses its token.
    public mutating func revokeAll(now: Date = Date()) {
        for index in clients.indices where clients[index].revokedAt == nil { clients[index].revokedAt = now }
    }

    /// Forgets revoked clients older than `days`.
    public mutating func prune(olderThan days: Int, now: Date = Date()) {
        clients.removeAll { client in
            guard let revoked = client.revokedAt else { return false }
            return now.timeIntervalSince(revoked) > Double(days) * 86_400
        }
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func makeToken() -> String { tokenPrefix + AgentAccessPolicy.makeToken() }

    static func makeID() -> String {
        String(format: "%04x", UInt16.random(in: .min ... .max))
    }
}

/// A pairing a client asked for and the person has not answered yet: the
/// client shows the same code, so the person can tell it is the one asking.
public struct PairingRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var clientName: String
    public var clientVersion: String?
    public var processID: Int?
    public var code: String
    public var created: Date
    public var expires: Date

    public static let lifetime: TimeInterval = 5 * 60

    public init(clientName: String, clientVersion: String? = nil, processID: Int? = nil, now: Date = Date(),
                code: String = PairingRequest.makeCode()) {
        self.id = UUID().uuidString
        self.clientName = clientName; self.clientVersion = clientVersion; self.processID = processID
        self.code = code; self.created = now; self.expires = now.addingTimeInterval(Self.lifetime)
    }

    public func isExpired(at now: Date = Date()) -> Bool { now >= expires }

    /// "481 – 207", as both sides show it.
    public var displayCode: String {
        let digits = Array(code)
        guard digits.count == 6 else { return code }
        return String(digits[0..<3]) + " – " + String(digits[3..<6])
    }

    public static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
