import Foundation

/// What was open: every window, its profile, its tabs in order and which one
/// was in front. Written continuously while the browser runs, read at launch.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public struct Tab: Codable, Equatable, Sendable {
        public var url: URL?
        public var title: String
        /// `WKWebView.interactionState`: back/forward list, scroll, form state.
        public var state: Data?
        /// The window's group this tab is in, if any: one of `Window.groups`.
        public var groupID: TabGroupID?
        public var isPinned: Bool
        /// Shown in split view beside the tab before it.
        public var besidePrevious: Bool
        public init(url: URL?, title: String, state: Data?, groupID: TabGroupID? = nil, isPinned: Bool = false, besidePrevious: Bool = false) {
            self.url = url
            self.title = title
            self.state = state
            self.groupID = groupID
            self.isPinned = isPinned
            self.besidePrevious = besidePrevious
        }

        // Sessions written before groups and pins still read.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decodeIfPresent(URL.self, forKey: .url)
            title = try container.decode(String.self, forKey: .title)
            state = try container.decodeIfPresent(Data.self, forKey: .state)
            groupID = try container.decodeIfPresent(TabGroupID.self, forKey: .groupID)
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            besidePrevious = try container.decodeIfPresent(Bool.self, forKey: .besidePrevious) ?? false
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var profileID: ProfileID
        public var frame: CodableRect
        public var tabs: [Tab]
        public var selected: Int
        /// Names, colours and whether each is collapsed, for the tabs' `groupID`s.
        public var groups: [TabGroup]
        public init(profileID: ProfileID, frame: CodableRect, tabs: [Tab], selected: Int, groups: [TabGroup] = []) {
            self.profileID = profileID
            self.frame = frame
            self.tabs = tabs
            self.selected = selected
            self.groups = groups
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profileID = try container.decode(ProfileID.self, forKey: .profileID)
            frame = try container.decode(CodableRect.self, forKey: .frame)
            tabs = try container.decode([Tab].self, forKey: .tabs)
            selected = try container.decode(Int.self, forKey: .selected)
            groups = try container.decodeIfPresent([TabGroup].self, forKey: .groups) ?? []
        }
    }

    public var windows: [Window]
    public var savedAt: Date

    public init(windows: [Window], savedAt: Date = .now) {
        self.windows = windows
        self.savedAt = savedAt
    }

    /// Nothing worth bringing back: no window with a tab that shows something.
    public var isEmpty: Bool {
        !windows.contains { $0.tabs.contains { $0.url != nil || $0.state != nil } }
    }

    /// Windows whose profile still exists, with tabs that show something,
    /// and a selection that points at one of them.
    public func restorable(profiles: Set<ProfileID>) -> [Window] {
        windows.compactMap { window in
            guard profiles.contains(window.profileID) else { return nil }
            var copy = window
            copy.tabs = window.tabs.filter { $0.url != nil || $0.state != nil }
            guard !copy.tabs.isEmpty else { return nil }
            copy.selected = min(max(0, window.selected), copy.tabs.count - 1)
            return copy
        }
    }
}

/// What a launch opens with.
public enum StartupChoice: String, CaseIterable, Sendable {
    case newWindow
    case lastSession

    /// Always the last session after a crash or an update relaunch: losing
    /// tabs to either is the one thing a browser must never do. Otherwise
    /// the person's choice.
    public static func shouldRestore(choice: StartupChoice, uncleanExit: Bool, restartForUpdate: Bool, hasSession: Bool) -> Bool {
        guard hasSession else { return false }
        return uncleanExit || restartForUpdate || choice == .lastSession
    }
}
