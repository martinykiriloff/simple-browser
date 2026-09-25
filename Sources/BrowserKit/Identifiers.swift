import Foundation

/// Type-safe identifiers. Distinct types so a `TabID` can never be passed where
/// a `TabGroupID` is expected.
public struct TypedID<Phantom>: Hashable, Sendable, Codable,
                                CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = UUID(uuidString: value) ?? UUID() }
    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TabTag {}
public enum TabGroupTag {}
public enum WindowTag {}
public enum ProfileTag {}
public enum SessionTag {}

public typealias TabID      = TypedID<TabTag>
public typealias TabGroupID = TypedID<TabGroupTag>
public typealias WindowID   = TypedID<WindowTag>
public typealias ProfileID  = TypedID<ProfileTag>
public typealias SessionID  = TypedID<SessionTag>
