import AppKit
import WebKit
import BrowserKit

/// One tab's permissions: what its site may do, the questions put to the
/// person when that is not settled, pop-ups held back, and the camera and
/// microphone while they are in use.
///
/// A permission belongs to the site in the address bar. A frame from
/// somewhere else asking through it is named in the question, and gets
/// what the person gives the page they chose to visit, no more.
@MainActor
final class PermissionsController: NSObject, NSPopoverDelegate {
    static let didChange = Notification.Name("SimpleBrowser.sitePermissionsDidChange")

    weak var webView: WKWebView? { didSet { if webView !== oldValue { observeCapture() } } }
    /// The profile's choices, or for a private window the private session's.
    var stored: (() -> SitePermissions)?
    var store: ((SitePermissions) -> Void)?
    /// Where questions hang from: the lock in the address bar.
    var anchor: (() -> NSView?)?
    var container: NSView?
    var openInNewTab: ((URL) -> Void)?
    var onChange: (() -> Void)?

    let captureButton = NSButton()
    /// Allowed for the page showing, by "Allow Once".
    private(set) var allowedOnce: Set<SitePermission> = []
    private(set) var popover: NSPopover?
    private(set) var promptController: PermissionPromptController?
    private(set) var blockedPopups: [URL] = []
    private(set) var popupBar: PopupBlockedBar?
    /// What was asked and how it went, without anything private. For the self-test.
    private(set) var trace: [String] = []

    private struct Request {
        let permissions: [SitePermission]
        let site: String
        let requester: String?
        let answer: (Bool) -> Void
    }
    private var waiting: [Request] = []
    private var asking: Request?
    private var captureObservations: [NSKeyValueObservation] = []
    private var site: String?

    override init() {
        super.init()
        captureButton.bezelStyle = .toolbar
        captureButton.target = self
        captureButton.action = #selector(showCaptureMenu(_:))
        syncCapture()
    }

    func tearDown() {
        captureObservations = []
        popover?.close()
        popupBar?.removeFromSuperview()
    }

    private var choices: SitePermissions {
        get { stored?() ?? SitePermissions() }
        set {
            store?(newValue)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            onChange?()
        }
    }

    var currentSite: String? { SitePermissions.site(of: webView?.url) }

    // MARK: - The page

    /// A page committed. Anything allowed once was allowed for the page
    /// that asked; questions that page asked are answered no.
    func didCommitNavigation() {
        let next = currentSite
        if next != site { allowedOnce = [] }
        site = next
        let unanswered = waiting + [asking].compactMap { $0 }
        waiting = []
        asking = nil
        promptController = nil
        popover?.close()
        popover = nil
        unanswered.forEach { $0.answer(false) }
        blockedPopups = []
        popupBar?.removeFromSuperview()
        popupBar = nil
    }

    // MARK: - Asking

    /// Settles a request: from what was chosen before, or by asking.
    func request(_ permissions: [SitePermission], requester: WKSecurityOrigin? = nil, answer: @escaping (Bool) -> Void) {
        request(permissions, requesterSite: requester.flatMap { SitePermissions.site(scheme: $0.protocol, host: $0.host, port: $0.port) }, answer: answer)
    }

    /// - Parameter requesterSite: the site of the frame that asked, when it
    ///   is not the page's own.
    func request(_ permissions: [SitePermission], requesterSite: String?, answer: @escaping (Bool) -> Void) {
        guard let site = currentSite else { answer(false); return }
        let names = permissions.map(\.rawValue).joined(separator: "+")
        switch PermissionDecision.decide(permissions, site: site, stored: choices, allowedOnce: allowedOnce) {
        case .allow:
            note("\(names): allowed")
            answer(true)
        case .deny:
            note("\(names): refused")
            answer(false)
        case .ask:
            waiting.append(Request(permissions: permissions, site: site, requester: requesterSite == site ? nil : requesterSite, answer: answer))
            note("\(names): asking")
            askNext()
        }
    }

    func request(_ permissions: [SitePermission], requester: WKSecurityOrigin? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            request(permissions, requester: requester) { continuation.resume(returning: $0) }
        }
    }

    private func askNext() {
        guard asking == nil, !waiting.isEmpty else { return }
        let request = waiting.removeFirst()
        // Settled meanwhile by the answer to an earlier question.
        let decision = PermissionDecision.decide(request.permissions, site: request.site, stored: choices, allowedOnce: allowedOnce)
        guard decision == .ask else {
            request.answer(decision == .allow)
            askNext()
            return
        }
        asking = request
        let controller = PermissionPromptController(permissions: request.permissions, site: request.site, requester: request.requester) { [weak self] answer in
            self?.answered(answer)
        }
        promptController = controller
        let popover = NSPopover()
        // Stays until answered: a click on the page is not an answer.
        popover.behavior = .applicationDefined
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        if let anchor = anchor?(), anchor.window != nil, !anchor.isHidden {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let webView, webView.window != nil {
            let top = webView.isFlipped ? webView.bounds.minY : webView.bounds.maxY - 1
            popover.show(relativeTo: NSRect(x: 40, y: top, width: 1, height: 1), of: webView, preferredEdge: .minY)
        }
    }

    enum Answer { case allow, allowOnce, deny, notNow }

    private func answered(_ answer: Answer) {
        guard let request = asking else { return }
        asking = nil
        promptController = nil
        popover?.close()
        popover = nil
        let names = request.permissions.map(\.rawValue).joined(separator: "+")
        switch answer {
        case .allow:
            var all = choices
            request.permissions.forEach { all.set(.allow, for: $0, site: request.site) }
            choices = all
            note("\(names): answered allow")
        case .allowOnce:
            allowedOnce.formUnion(request.permissions)
            note("\(names): answered allow once")
        case .deny:
            var all = choices
            // Only what was not already allowed: refusing the microphone
            // must not take back a camera given earlier.
            for permission in request.permissions where all.choice(for: permission, site: request.site) == nil {
                all.set(.deny, for: permission, site: request.site)
            }
            choices = all
            note("\(names): answered don't allow")
        case .notNow:
            note("\(names): dismissed")
            // The same thing asked for again while the question was up is
            // not asked about again the moment it is waved away.
            let same = waiting.filter { $0.site == request.site && Set($0.permissions).isSubset(of: Set(request.permissions)) }
            waiting.removeAll { $0.site == request.site && Set($0.permissions).isSubset(of: Set(request.permissions)) }
            same.forEach { $0.answer(false) }
        }
        request.answer(answer == .allow || answer == .allowOnce)
        askNext()
    }

    func popoverDidClose(_ notification: Notification) {
        // Closed without an answer (Escape): not now, and nothing remembered.
        if asking != nil, (notification.object as? NSPopover) === popover { answered(.notNow) }
    }

    // MARK: - Pop-ups

    /// A page opening a window by itself. True when it may.
    func allowsPopup(to url: URL?, userInitiated: Bool) -> Bool {
        guard !userInitiated, let site = currentSite else { return true }
        if PermissionDecision.decide([.popups], site: site, stored: choices, allowedOnce: allowedOnce) == .allow {
            note("popups: allowed")
            return true
        }
        note("popups: blocked")
        if let url { blockedPopups.append(url) }
        showPopupBar(site: site)
        return false
    }

    private func showPopupBar(site: String) {
        guard let container else { return }
        popupBar?.removeFromSuperview()
        let count = blockedPopups.count
        let bar = PopupBlockedBar(site: SitePermissions.displayName(of: site), count: max(1, count)) { [weak self] action in
            guard let self else { return }
            switch action {
            case .open:
                self.blockedPopups.forEach { self.openInNewTab?($0) }
            case .always:
                var all = self.choices
                all.set(.allow, for: .popups, site: site)
                self.choices = all
                self.note("popups: answered always allow")
                self.blockedPopups.forEach { self.openInNewTab?($0) }
            case .close:
                break
            }
            self.blockedPopups = []
            self.popupBar?.removeFromSuperview()
            self.popupBar = nil
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            bar.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        popupBar = bar
    }

    // MARK: - Camera and microphone in use

    private func observeCapture() {
        captureObservations = []
        guard let webView else { return }
        captureObservations = [
            webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.syncCapture() } },
            webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.syncCapture() } },
        ]
        syncCapture()
    }

    var cameraInUse: Bool { webView?.cameraCaptureState == .active }
    var microphoneInUse: Bool { webView?.microphoneCaptureState == .active }
    var isCapturing: Bool { cameraInUse || microphoneInUse }

    private func syncCapture() {
        let symbol = cameraInUse ? "video.fill" : "mic.fill"
        let what = cameraInUse && microphoneInUse ? "camera and microphone" : cameraInUse ? "camera" : "microphone"
        captureButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        captureButton.toolTip = isCapturing ? "This page is using your \(what). Click to stop." : ""
        captureButton.setAccessibilityLabel(isCapturing ? "Using your \(what)" : "Camera and microphone")
        onChange?()
    }

    @objc private func showCaptureMenu(_ sender: Any?) {
        let menu = NSMenu()
        if cameraInUse { menu.addItem(withTitle: "Stop Using Camera", action: #selector(stopCamera(_:)), keyEquivalent: "").target = self }
        if microphoneInUse { menu.addItem(withTitle: "Stop Using Microphone", action: #selector(stopMicrophone(_:)), keyEquivalent: "").target = self }
        if cameraInUse && microphoneInUse { menu.addItem(withTitle: "Stop Both", action: #selector(stopCapture(_:)), keyEquivalent: "").target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: captureButton.bounds.height + 4), in: captureButton)
    }

    @objc func stopCamera(_ sender: Any?) { webView?.setCameraCaptureState(.none) { } }
    @objc func stopMicrophone(_ sender: Any?) { webView?.setMicrophoneCaptureState(.none) { } }
    @objc func stopCapture(_ sender: Any?) {
        stopCamera(sender)
        stopMicrophone(sender)
    }

    private func note(_ step: String) {
        trace.append(step)
        if trace.count > 200 { trace.removeFirst(50) }
    }
}

/// "… would like to use your camera." Don't Allow, Allow Once, Allow.
@MainActor
final class PermissionPromptController: NSViewController {
    let permissions: [SitePermission]
    let site: String
    let requester: String?
    private let onAnswer: (PermissionsController.Answer) -> Void
    let questionLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var buttons: [NSButton] = []

    init(permissions: [SitePermission], site: String, requester: String?, onAnswer: @escaping (PermissionsController.Answer) -> Void) {
        self.permissions = permissions
        self.site = site
        self.requester = requester
        self.onAnswer = onAnswer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let icons = NSStackView(views: permissions.map { permission in
            let view = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: permission.name) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: 20, weight: .regular)
            view.contentTintColor = .controlAccentColor
            return view
        })
        icons.spacing = 8
        questionLabel.stringValue = SitePermission.question(for: permissions, site: SitePermissions.displayName(of: site))
        questionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        var details: [String] = []
        if let requester { details.append("Asked for by content from \(SitePermissions.displayName(of: requester)), shown on this page.") }
        // Plain http across a network, not http to this Mac itself.
        let exposed = PageSecurity.of(URL(string: site), hasOnlySecureContent: false) == .notSecure
        if exposed { details.append("This site is not encrypted: others on the network could use what you allow.") }
        detailLabel.stringValue = details.joined(separator: " ")
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = exposed && requester == nil ? .systemOrange : .secondaryLabelColor
        detailLabel.isHidden = details.isEmpty

        let deny = NSButton(title: "Don’t Allow", target: self, action: #selector(deny(_:)))
        let once = NSButton(title: "Allow Once", target: self, action: #selector(allowOnce(_:)))
        let allow = NSButton(title: "Allow", target: self, action: #selector(allow(_:)))
        deny.keyEquivalent = "\u{1b}"
        buttons = [deny, once, allow]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, deny, once, allow])
        row.spacing = 8

        let stack = NSStackView(views: [icons, questionLabel, detailLabel, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: detailLabel.isHidden ? questionLabel : detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 380),
            questionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        view = root
    }

    @objc private func deny(_ sender: Any?) { onAnswer(.deny) }
    @objc private func allowOnce(_ sender: Any?) { onAnswer(.allowOnce) }
    @objc private func allow(_ sender: Any?) { onAnswer(.allow) }
}

/// "Pop-up blocked", over the top of the page, with what to do about it.
@MainActor
final class PopupBlockedBar: NSVisualEffectView {
    enum Action { case open, always, close }
    private let onAction: (Action) -> Void
    let label = NSTextField(labelWithString: "")
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    let alwaysButton = NSButton(title: "", target: nil, action: nil)
    let closeButton = NSButton()

    init(site: String, count: Int, onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        label.stringValue = count == 1 ? "A pop-up window was blocked" : "\(count) pop-up windows were blocked"
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let icon = NSImageView(image: NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        openButton.title = count == 1 ? "Open" : "Open All"
        alwaysButton.title = "Always Allow on \(site)"
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.isBordered = false
        for (button, action) in [(openButton, #selector(open(_:))), (alwaysButton, #selector(always(_:))), (closeButton, #selector(dismiss(_:)))] {
            button.target = self
            button.action = action
            if button !== closeButton { button.bezelStyle = .accessoryBarAction }
        }
        let stack = NSStackView(views: [icon, label, openButton, alwaysButton, closeButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel(label.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func open(_ sender: Any?) { onAction(.open) }
    @objc private func always(_ sender: Any?) { onAction(.always) }
    @objc private func dismiss(_ sender: Any?) { onAction(.close) }
}
