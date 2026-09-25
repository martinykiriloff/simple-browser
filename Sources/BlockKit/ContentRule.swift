import Foundation

/// A WebKit content-blocker rule, as consumed by `WKContentRuleListStore`.
///
/// Mirrors the JSON schema documented at
/// <https://webkit.org/blog/3476/content-blockers-first-look/>.
public struct ContentRule: Codable, Sendable, Equatable {
    public var trigger: Trigger
    public var action: Action

    public init(trigger: Trigger, action: Action) {
        self.trigger = trigger
        self.action = action
    }

    public struct Trigger: Codable, Sendable, Equatable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
        }

        public init(
            urlFilter: String,
            urlFilterIsCaseSensitive: Bool? = nil,
            ifDomain: [String]? = nil,
            unlessDomain: [String]? = nil,
            resourceType: [String]? = nil,
            loadType: [String]? = nil
        ) {
            self.urlFilter = urlFilter
            self.urlFilterIsCaseSensitive = urlFilterIsCaseSensitive
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
            self.resourceType = resourceType
            self.loadType = loadType
        }
    }

    public struct Action: Codable, Sendable, Equatable {
        public var type: ActionType
        public var selector: String?

        enum CodingKeys: String, CodingKey { case type, selector }

        public init(type: ActionType, selector: String? = nil) {
            self.type = type
            self.selector = selector
        }
    }

    public enum ActionType: String, Codable, Sendable, Equatable {
        case block
        case blockCookies        = "block-cookies"
        case cssDisplayNone      = "css-display-none"
        case ignorePreviousRules = "ignore-previous-rules"
        case makeHTTPS           = "make-https"
    }

    /// Exceptions are the rules that must be replicated across every partition.
    public var isException: Bool { action.type == .ignorePreviousRules }
}
