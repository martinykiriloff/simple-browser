import AppKit
import WebKit
import BlockKit

/// One tab's view of content blocking: the shield beside the address bar,
/// the count of what was blocked on the page showing, and the switch that
/// turns blocking off for the site.
@MainActor
final class BlockingController: NSObject {
    let button = NSButton()
    var blocker: ContentBlocker?
    /// The tab's content controller, which the rule lists are added to.
    var contentController: WKUserContentController?
    var profileID = ""
    /// Where the sites blocking is off for are kept: the profile's settings,
    /// or for a private window, the private session.
    var offSites: (() -> [String])?
    var setOffSites: (([String]) -> Void)?

    private var sites: [String] {
        get { offSites?() ?? BrowserSettings.blockingOffSites(profile: profileID) }
        set {
            if let setOffSites { setOffSites(newValue) } else { BrowserSettings.setBlockingOffSites(newValue, profile: profileID) }
        }
    }
    /// The page showing, for the popover and the switch.
    var currentURL: (() -> URL?)?
    var reload: (() -> Void)?
    var openInNewTab: ((URL) -> Void)?
    var showSettings: (() -> Void)?
    var onChange: (() -> Void)?

    private(set) var blockedCount = 0
    private(set) var blockedHosts: [String: Int] = [:]
    private var blockedURLs: Set<String> = []
    private(set) var popover: NSPopover?
    private(set) var popoverController: BlockingPopoverController?
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        button.bezelStyle = .toolbar
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(showPopover(_:))
        observer = NotificationCenter.default.addObserver(forName: ContentBlocker.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        popover?.close()
    }

    // MARK: - The page

    static func site(of url: URL?) -> String? {
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return BlockingAllowlist.normalized(host)
    }

    var site: String? { Self.site(of: currentURL?()) }

    func isOff(forSiteOf url: URL?) -> Bool {
        BlockingAllowlist.contains(Self.site(of: url), in: sites)
    }

    var isOffForSite: Bool { isOff(forSiteOf: currentURL?()) }

    /// The tab is about to load a page: its site decides whether this
    /// tab's requests are filtered.
    func willNavigate(to url: URL) {
        guard let contentController else { return }
        blocker?.setSuspended(isOff(forSiteOf: url), for: contentController)
    }

    func didCommit() {
        blockedCount = 0
        blockedHosts = [:]
        blockedURLs = []
        popover?.close()
        sync()
    }

    /// WebKit blocked a load on this tab's page.
    func didBlock(_ url: URL) {
        // Once per address: WebKit asks for a script or image twice, from
        // its preload scanner and from the parser, and reports both
        // (measured), and a page that retries is still one thing blocked.
        guard blockedURLs.insert(url.absoluteString).inserted else { return }
        blockedCount += 1
        if let host = url.host(percentEncoded: false) { blockedHosts[BlockingAllowlist.normalized(host), default: 0] += 1 }
        sync()
    }

    /// The switch in the popover. The page is reloaded so the choice shows.
    func setOff(_ off: Bool) {
        guard let site else { return }
        var sites = self.sites.filter { $0 != site }
        if off {
            // A wider entry already covers this site; narrowing is removing that one.
            sites.append(site)
        } else {
            sites.removeAll { BlockingAllowlist.contains(site, in: [$0]) }
        }
        self.sites = sites
        if let contentController { blocker?.setSuspended(off, for: contentController) }
        NotificationCenter.default.post(name: ContentBlocker.didChange, object: blocker)
        reload?()
    }

    // MARK: - The shield

    var summary: String {
        guard let blocker, blocker.isOn else { return "Content blocking is off" }
        guard let site else { return "Nothing to block on this page" }
        if isOffForSite { return "Blocking is off for \(site)" }
        if !blocker.isReady { return blocker.isBusy ? "The filter lists are being prepared" : "The filter lists have not been downloaded yet" }
        switch blockedCount {
        case 0: return "Nothing blocked on this page"
        case 1: return "1 item blocked on this page"
        default: return "\(blockedCount) items blocked on this page"
        }
    }

    func sync() {
        let on = blocker?.isOn == true && !isOffForSite
        let symbol = on ? "shield.lefthalf.filled" : "shield.slash"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Content blocking")
        button.title = on && blockedCount > 0 ? (blockedCount > 999 ? "999+" : String(blockedCount)) : ""
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
        popoverController?.refresh()
        onChange?()
    }

    @objc func showPopover(_ sender: Any?) {
        if let popover, popover.isShown { popover.close(); return }
        guard button.window != nil else { return }
        let controller = BlockingPopoverController(blocking: self)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
        popoverController = controller
    }

    /// A new issue on the project, with the site named and nothing else
    /// about the person: they see it before anything is sent.
    func reportBrokenSite() {
        popover?.close()
        guard let site else { return }
        var components = URLComponents(string: "https://github.com/martinykiriloff/simple-browser/issues/new")!
        let lists = blocker?.enabledSources.map(\.name).joined(separator: ", ") ?? ""
        components.queryItems = [
            URLQueryItem(name: "title", value: "Broken site: \(site)"),
            URLQueryItem(name: "labels", value: "broken site"),
            URLQueryItem(name: "body", value: """
            **Site:** \(site)

            **What is wrong** (what is missing, or does not work?):

            **Does it work with blocking switched off for the site?**

            Filter lists: \(lists)
            """),
        ]
        if let url = components.url { openInNewTab?(url) }
    }
}

/// What the shield shows when clicked.
@MainActor
final class BlockingPopoverController: NSViewController {
    private unowned let blocking: BlockingController
    let titleLabel = NSTextField(labelWithString: "")
    let siteSwitch = NSSwitch()
    let switchLabel = NSTextField(labelWithString: "")
    let hostsLabel = NSTextField(wrappingLabelWithString: "")
    let reportButton = NSButton(title: "Report a Broken Site…", target: nil, action: nil)
    let settingsButton = NSButton(title: "Privacy Settings…", target: nil, action: nil)

    init(blocking: BlockingController) {
        self.blocking = blocking
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        hostsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hostsLabel.textColor = .secondaryLabelColor
        siteSwitch.target = self
        siteSwitch.action = #selector(toggle(_:))
        siteSwitch.controlSize = .small
        switchLabel.lineBreakMode = .byTruncatingMiddle
        switchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let switchRow = NSStackView(views: [switchLabel, spacer, siteSwitch])
        for (button, action) in [(reportButton, #selector(report(_:))), (settingsButton, #selector(settings(_:)))] {
            button.target = self
            button.action = action
            button.bezelStyle = .accessoryBarAction
        }
        let buttons = NSStackView(views: [reportButton, settingsButton])
        buttons.spacing = 4

        let stack = NSStackView(views: [titleLabel, hostsLabel, switchRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: titleLabel)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 340),
            switchRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            hostsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        view = root
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        titleLabel.stringValue = blocking.summary
        let site = blocking.site
        let blockerOn = blocking.blocker?.isOn == true
        switchLabel.stringValue = site.map { "Block ads and trackers on \($0)" } ?? "Block ads and trackers"
        siteSwitch.state = blockerOn && site != nil && !blocking.isOffForSite ? .on : .off
        siteSwitch.isEnabled = blockerOn && site != nil
        reportButton.isEnabled = site != nil
        // Where the blocked requests were going, most first.
        let hosts = blocking.blockedHosts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6)
        hostsLabel.stringValue = hosts.map { "\($0.key)  ×\($0.value)" }.joined(separator: "\n")
            + (blocking.blockedHosts.count > 6 ? "\nand \(blocking.blockedHosts.count - 6) more" : "")
        hostsLabel.isHidden = hosts.isEmpty
    }

    @objc private func toggle(_ sender: Any?) { blocking.setOff(siteSwitch.state == .off) }
    @objc private func report(_ sender: Any?) { blocking.reportBrokenSite() }
    @objc private func settings(_ sender: Any?) {
        blocking.popover?.close()
        blocking.showSettings?()
    }
}
