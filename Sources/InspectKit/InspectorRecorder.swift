import Foundation
import BrowserKit

/// One event as it landed in a recording: which tab, when, in what order.
public struct RecordedEvent: Sendable, Codable, Identifiable {
    public let id: UUID
    /// Monotonic within a recorder; the order events were observed in, which
    /// is not always the order of their own timestamps.
    public let sequence: Int
    public let tab: TabID
    public let recordedAt: Date
    public let event: InspectorEvent

    public init(id: UUID = UUID(), sequence: Int, tab: TabID, recordedAt: Date = .now, event: InspectorEvent) {
        self.id = id; self.sequence = sequence; self.tab = tab
        self.recordedAt = recordedAt; self.event = event
    }
}

/// The single sink every observation source fans into.
///
/// Records unconditionally from the moment a tab exists -- there is no
/// "open the dev tools first" -- and outlives individual documents, so a
/// recording spans reloads and navigations. Persistence to SQLite and
/// diffing come later; this is the in-memory form.
@MainActor
public final class InspectorRecorder {
    public enum Change: Sendable {
        case appended(RecordedEvent)
        case cleared
    }

    public private(set) var events: [RecordedEvent] = []
    /// Oldest events are dropped past this point so a chatty page cannot
    /// grow memory without bound.
    public var limit: Int

    private var nextSequence = 0
    private var observers: [UUID: @MainActor (Change) -> Void] = [:]

    public init(limit: Int = 50_000) {
        self.limit = limit
    }

    public func record(_ event: InspectorEvent, tab: TabID) {
        let recorded = RecordedEvent(sequence: nextSequence, tab: tab, event: event)
        nextSequence += 1
        events.append(recorded)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
        for observer in observers.values { observer(.appended(recorded)) }
    }

    public func record(_ events: [InspectorEvent], tab: TabID) {
        for event in events { record(event, tab: tab) }
    }

    public func clear() {
        events.removeAll()
        for observer in observers.values { observer(.cleared) }
    }

    @discardableResult
    public func observe(_ handler: @escaping @MainActor (Change) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    public func count(where predicate: (RecordedEvent) -> Bool) -> Int {
        events.reduce(0) { $0 + (predicate($1) ? 1 : 0) }
    }

    // MARK: - Export

    public struct Export: Codable, Sendable {
        public var version: Int
        public var exportedAt: Date
        public var events: [RecordedEvent]
    }

    /// The whole recording as JSON. Not yet a database, but already the thing
    /// Chrome does not give you: a recording that exists after the tab is gone.
    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Export(version: 1, exportedAt: .now, events: events))
    }
}
