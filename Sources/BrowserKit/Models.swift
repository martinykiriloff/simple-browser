import Foundation

/// Reference to a blob on disk (favicon, tab snapshot), stored per profile.
public struct AssetRef: Hashable, Sendable, Codable {
    public let sha256: String
    public let fileExtension: String
    public init(sha256: String, fileExtension: String) {
        self.sha256 = sha256
        self.fileExtension = fileExtension
    }
}

/// Serializable state of a tab.
///
/// - Important: No WebKit type appears here. `interactionState` is opaque
///   `Data` from `WKWebView.interactionState`, which carries the back-forward
///   list, scroll position and form state. Keeping WebKit out of the model is
///   what makes it `Codable`, `Sendable` and testable off-device.
public struct TabState: Identifiable, Hashable, Sendable, Codable {
    public let id: TabID
    public var url: URL?
    public var title: String
    public var faviconRef: AssetRef?
    public var interactionState: Data?
    public var snapshotRef: AssetRef?
    public var groupID: TabGroupID?
    public var isPinned: Bool
    public var lastActive: Date

    public init(
        id: TabID = TabID(),
        url: URL? = nil,
        title: String = "",
        faviconRef: AssetRef? = nil,
        interactionState: Data? = nil,
        snapshotRef: AssetRef? = nil,
        groupID: TabGroupID? = nil,
        isPinned: Bool = false,
        lastActive: Date = .now
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconRef = faviconRef
        self.interactionState = interactionState
        self.snapshotRef = snapshotRef
        self.groupID = groupID
        self.isPinned = isPinned
        self.lastActive = lastActive
    }

    /// A hibernated tab can be restored losslessly; one without state cannot.
    public var isRestorable: Bool { interactionState != nil || url != nil }
}

public struct TabGroup: Identifiable, Hashable, Sendable, Codable {
    public let id: TabGroupID
    public var name: String
    public var color: GroupColor
    public var tabOrder: [TabID]
    public var isCollapsed: Bool

    public init(
        id: TabGroupID = TabGroupID(),
        name: String,
        color: GroupColor = .graphite,
        tabOrder: [TabID] = [],
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.tabOrder = tabOrder
        self.isCollapsed = isCollapsed
    }
}

public enum GroupColor: String, Sendable, Codable, CaseIterable {
    case graphite, red, orange, yellow, green, teal, blue, purple, pink
}

/// A window belongs to exactly one profile. This is a deliberate constraint:
/// it keeps "which identity am I browsing as" answerable at a glance.
public struct WindowState: Identifiable, Hashable, Sendable, Codable {
    public let id: WindowID
    public let profileID: ProfileID
    public var groupOrder: [TabGroupID]
    public var ungroupedTabs: [TabID]
    public var activeTab: TabID?
    public var frame: CodableRect

    public init(
        id: WindowID = WindowID(),
        profileID: ProfileID,
        groupOrder: [TabGroupID] = [],
        ungroupedTabs: [TabID] = [],
        activeTab: TabID? = nil,
        frame: CodableRect = .init(x: 0, y: 0, width: 1280, height: 800)
    ) {
        self.id = id
        self.profileID = profileID
        self.groupOrder = groupOrder
        self.ungroupedTabs = ungroupedTabs
        self.activeTab = activeTab
        self.frame = frame
    }
}

/// CoreGraphics-free rect so the model target stays platform-independent.
public struct CodableRect: Hashable, Sendable, Codable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Whether a tab currently owns a live web view.
///
/// A live `WKWebView` costs several processes and 60-150 MB. Fifty live tabs
/// will not fit on any machine, so residency is an explicit, testable concept
/// rather than an emergent one.
public enum TabResidency: Sendable, Equatable {
    case live
    case hibernated
}

public struct Profile: Identifiable, Hashable, Sendable, Codable {
    public let id: ProfileID
    public var name: String
    public var accent: GroupColor
    /// Passed to `WKWebsiteDataStore(forIdentifier:)`. Distinct per profile,
    /// which is what actually isolates cookies, localStorage, IndexedDB,
    /// service workers and cache at the WebKit level.
    public let dataStoreIdentifier: UUID
    public var enabledExtensionIDs: [String]

    public init(
        id: ProfileID = ProfileID(),
        name: String,
        accent: GroupColor = .blue,
        dataStoreIdentifier: UUID = UUID(),
        enabledExtensionIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.accent = accent
        self.dataStoreIdentifier = dataStoreIdentifier
        self.enabledExtensionIDs = enabledExtensionIDs
    }
}
