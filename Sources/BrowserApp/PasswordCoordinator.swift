import AppKit
import WebKit
import PasswordKit

/// One web view's password handling: listens to the password agent, fills
/// saved sign-ins, drops the account list under a focused field, and asks
/// "Save password?" once a sign-in has worked.
///
/// Two rules hold throughout. The origin a password belongs to is always the
/// one WebKit reports for the frame a message came from, never something the
/// page said. And a password only ever travels to the page as an argument to
/// the agent in its isolated world, into a document whose origin the agent
/// re-checks, so a frame that navigated in the meantime gets nothing.
@MainActor
final class PasswordCoordinator: NSObject, WKScriptMessageHandler, NSPopoverDelegate {
    static let worldName = "SimpleBrowserPasswords"
    static let handlerName = "passwords"

    struct Candidate {
        var origin: String
        var username: String
        var password: String
        var currentPassword: String
        var form: String
        /// A real form submission, or only a button press or Return, which
        /// says less: see `expiry`.
        var trigger: String
        var isMainFrame: Bool
        var at = Date()

        /// How long to wait for a sign that it worked. A submitted form is
        /// followed by a page load, which can be slow. A button press on a
        /// page that never reloads shows its result at once, and waiting
        /// longer risks taking some later navigation for success.
        var expiry: TimeInterval { trigger == "submit" ? 30 : 10 }
    }

    struct Prompt {
        var mode: PasswordPromptViewController.Mode
        var origin: String
        var username: String
        var password: String
        var at = Date()
    }

    let service: PasswordService
    weak var webView: WKWebView?
    /// The key button, which the popovers hang from.
    var anchorItem: (() -> NSToolbarItem?)?
    var onStateChange: (() -> Void)?
    var onManage: (() -> Void)?
    private(set) var installError: String?

    let suggestions = CredentialSuggestionPanel()
    private(set) var promptController: PasswordPromptViewController?
    private(set) var accountsController: SiteAccountsViewController?
    private var popover: NSPopover?

    /// Submitted, but not yet known to have worked.
    private(set) var pending: Candidate?
    /// Worked; waiting for the user's answer. Survives the navigation that
    /// follows a sign-in, which is the whole point of it.
    private(set) var prompt: Prompt?
    private(set) var siteCredentialCount = 0
    /// Steps taken, without any secret in them. Read by the self-test.
    private(set) var trace: [String] = []

    private let world = WKContentWorld.world(name: PasswordCoordinator.worldName)
    private weak var userContentController: WKUserContentController?
    private var documentGeneration = 0
    private var reportsThisDocument = 0
    private var autofilledDocument = false
    private var mainFrame: WKFrameInfo?
    private var mainFrameHasLogin = false
    private var focus: (frame: WKFrameInfo, origin: String, role: String, rect: NSRect?)?
    /// What the focused new-password field accepts, from its attributes.
    private var focusRules = PasswordRules()
    private var focusGeneration = 0
    private var usernameHint: (origin: String, username: String, at: Date)?
    private var generated: [String: (password: String, id: UUID)] = [:]
    private var keyMonitor: Any?
    private var changeObserver: NSObjectProtocol?

    init(service: PasswordService) {
        self.service = service
        super.init()
    }

    // MARK: - Installation

    /// Before the web view exists, so the agent is in the very first document.
    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        guard let url = AppResources.bundle.url(forResource: "password-agent", withExtension: "js", subdirectory: "PasswordAgent"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            installError = "password-agent.js is missing from the app's resources"
            return
        }
        controller.add(self, contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.webView?.window else { return event }
            return self.suggestions.handleKeyDown(event) ? nil : event
        }
        changeObserver = NotificationCenter.default.addObserver(forName: PasswordService.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSiteState() }
        }
    }

    func uninstall() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        suggestions.hide()
        popover?.close()
    }

    // MARK: - Navigation (called by the window controller)

    func didCommitNavigation() {
        documentGeneration += 1
        reportsThisDocument = 0
        autofilledDocument = false
        mainFrame = nil
        mainFrameHasLogin = false
        focus = nil
        focusGeneration += 1
        suggestions.hide()
        if accountsController != nil { popover?.close() }
        if let prompt, Date().timeIntervalSince(prompt.at) > 300 { self.prompt = nil }
        refreshSiteState()
    }

    /// The agent reports on every HTML document. If a sign-in led somewhere
    /// it does not run (a PDF, a download), no report will come to say the
    /// form is gone, so a finished load with no report counts as success.
    func didFinishNavigation() {
        guard let waiting = pending, waiting.isMainFrame else { return }
        let generation = documentGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, generation == self.documentGeneration, self.reportsThisDocument == 0,
                  let pending = self.pending, pending.at == waiting.at else { return }
            self.note("no report from the new page: treating the sign-in as successful")
            self.pending = nil
            self.decide(pending)
        }
    }

    // MARK: - Messages from the agent

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, message.world == world,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let frame = message.frameInfo
        let security = frame.securityOrigin
        guard let origin = CredentialOrigin.origin(scheme: security.protocol, host: security.host, port: security.port) else { return }

        switch kind {
        case "forms":
            handleForms(body, frame: frame, origin: origin)
        case "focus":
            handleFocus(body, frame: frame, origin: origin)
        case "blur":
            focus = nil
            focusGeneration += 1
            suggestions.hide()
        case "dismiss":
            suggestions.hide()
        case "input":
            handleInput(body)
        case "username-hint":
            if let username = body["username"] as? String { usernameHint = (origin, username, Date()) }
        case "candidate":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            pending = Candidate(origin: origin, username: body["username"] as? String ?? "", password: password,
                                currentPassword: body["currentPassword"] as? String ?? "",
                                form: body["form"] as? String ?? "login", trigger: body["trigger"] as? String ?? "click",
                                isMainFrame: frame.isMainFrame)
            note("candidate (\(body["trigger"] as? String ?? "?"), \(pending?.form ?? "")) for \(origin)")
        default:
            break
        }
    }

    private func handleForms(_ body: [String: Any], frame: WKFrameInfo, origin: String) {
        let login = (body["login"] as? NSNumber)?.intValue ?? 0
        let signup = (body["signup"] as? NSNumber)?.intValue ?? 0
        let fresh = body["fresh"] as? Bool ?? false
        note("forms \(frame.isMainFrame ? "main" : "frame") login=\(login) signup=\(signup) fresh=\(fresh)")

        if let waiting = pending, waiting.isMainFrame == frame.isMainFrame, frame.isMainFrame || waiting.origin == origin {
            if Date().timeIntervalSince(waiting.at) > waiting.expiry {
                pending = nil
            } else if login > 0 {
                // The sign-in form is back on a new page: the password was wrong.
                if fresh, waiting.form == "login" {
                    note("the sign-in form came back: not offering to save")
                    pending = nil
                }
            } else {
                pending = nil
                decide(waiting)
            }
        }

        guard frame.isMainFrame else { return }
        reportsThisDocument += 1
        mainFrame = frame
        mainFrameHasLogin = login > 0
        refreshSiteState()

        // Unasked filling is for the main frame only. A sign-in form in a
        // frame is offered its accounts when the person clicks into it.
        let passwordEmpty = body["passwordEmpty"] as? Bool ?? true
        if login > 0, passwordEmpty, !autofilledDocument, BrowserSettings.autofillPasswords {
            autofilledDocument = true
            autofill(frame: frame, origin: origin, prefilledUsername: body["prefilledUsername"] as? String ?? "")
        }
    }

    // MARK: - Filling

    private func autofill(frame: WKFrameInfo, origin: String, prefilledUsername: String) {
        let generation = documentGeneration
        Task { @MainActor in
            guard let credentials = try? await service.store.credentials(forPage: origin), !credentials.isEmpty else { return }
            // If the page already names an account, only that account will do.
            let chosen = prefilledUsername.isEmpty ? credentials.first : credentials.first { $0.username == prefilledUsername }
            guard let chosen, let password = try? await service.store.password(for: chosen.id),
                  generation == documentGeneration else { return }
            let result = await fill(username: chosen.username, password: password, frame: frame, origin: origin, onlyIfEmpty: true)
            note("autofill \(chosen.username.isEmpty ? "(no username)" : chosen.username): \(result)")
        }
    }

    @discardableResult
    private func fill(username: String, password: String, frame: WKFrameInfo, origin: String, onlyIfEmpty: Bool) async -> String {
        guard let webView else { return "no web view" }
        // `location.origin` is read in the agent's world, where page script
        // cannot have redefined it.
        let script = """
        if (!window.__sbPasswords || location.origin !== origin) return 'wrong document';
        var result = window.__sbPasswords.fill({ username: username, password: password, onlyIfEmpty: onlyIfEmpty });
        return result.password ? 'filled' : (result.username ? 'username only' : 'not filled');
        """
        let outcome = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["username": username, "password": password, "onlyIfEmpty": onlyIfEmpty, "origin": origin],
            in: frame, contentWorld: world
        )
        return outcome as? String ?? "failed"
    }

    /// Fill a chosen account, from the list under a field or the key button.
    func fill(_ credential: Credential, frame: WKFrameInfo, origin: String) {
        Task { @MainActor in
            guard CredentialOrigin.matches(saved: credential.origin, page: origin),
                  let password = try? await service.store.password(for: credential.id) else { return }
            let result = await fill(username: credential.username, password: password, frame: frame, origin: origin, onlyIfEmpty: false)
            note("fill \(credential.username.isEmpty ? "(no username)" : credential.username): \(result)")
        }
    }

    private func useGeneratedPassword(_ password: String, frame: WKFrameInfo, origin: String) {
        Task { @MainActor in
            guard let webView else { return }
            let script = """
            if (!window.__sbPasswords || location.origin !== origin) return null;
            return window.__sbPasswords.fillNew({ password: password });
            """
            let result = try? await webView.callAsyncJavaScript(script, arguments: ["password": password, "origin": origin],
                                                                in: frame, contentWorld: world) as? [String: Any]
            guard result?["filled"] as? Bool == true else { note("generated password: not filled"); return }
            // Saved now, not at submit: nobody has seen this password, so a
            // sign-up we fail to notice must not be the only copy of it.
            let username = result?["username"] as? String ?? ""
            if let saved = try? await service.store.save(origin: origin, username: username, password: password) {
                generated[origin] = (password, saved.id)
                note("generated password: filled and saved")
                service.changed()
            }
        }
    }

    // MARK: - The list under a field

    private func handleFocus(_ body: [String: Any], frame: WKFrameInfo, origin: String) {
        guard let role = body["role"] as? String else { return }
        var rect: NSRect?
        if let r = body["rect"] as? [String: Any],
           let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
           let width = (r["width"] as? NSNumber)?.doubleValue, let height = (r["height"] as? NSNumber)?.doubleValue {
            rect = NSRect(x: x, y: y, width: width, height: height)
        }
        focus = (frame, origin, role, rect)
        focusRules = role == "new-password"
            ? PasswordRules.parse(body["rules"] as? String ?? "",
                                  minLength: (body["minLength"] as? NSNumber)?.intValue,
                                  maxLength: (body["maxLength"] as? NSNumber)?.intValue)
            : PasswordRules()
        focusGeneration += 1
        note("focus \(role)")
        showSuggestions(filter: "", fieldIsEmpty: body["empty"] as? Bool ?? true)
    }

    private func handleInput(_ body: [String: Any]) {
        guard let focus else { return }
        if focus.role == "username" {
            showSuggestions(filter: body["text"] as? String ?? "", fieldIsEmpty: false)
        } else {
            // Retyping the password means the last attempt is not the one to save.
            if focus.role == "password" { pending = nil }
            suggestions.hide()
        }
    }

    private func showSuggestions(filter: String, fieldIsEmpty: Bool) {
        guard let focus else { return }
        let generation = focusGeneration
        Task { @MainActor in
            var items: [CredentialSuggestionPanel.Item] = []
            if focus.role == "new-password" {
                guard fieldIsEmpty else { suggestions.hide(); return }
                let password = PasswordGenerator.generate(rules: focusRules)
                items.append(.init(title: "Use Strong Password", subtitle: password, symbol: "key.fill") { [weak self] in
                    self?.useGeneratedPassword(password, frame: focus.frame, origin: focus.origin)
                })
            } else {
                let credentials = (try? await service.store.credentials(forPage: focus.origin)) ?? []
                let typed = filter.lowercased()
                for credential in credentials where typed.isEmpty || credential.username.lowercased().hasPrefix(typed) {
                    let moved = credential.origin == focus.origin ? nil : "saved for \(credential.origin)"
                    items.append(.init(title: credential.username.isEmpty ? "No username" : credential.username,
                                       subtitle: moved ?? "••••••••", symbol: "key") { [weak self] in
                        self?.fill(credential, frame: focus.frame, origin: focus.origin)
                    })
                }
                guard !items.isEmpty else { suggestions.hide(); return }
            }
            items.append(.init(title: "Manage Passwords…", subtitle: nil, symbol: "gearshape", isFooter: true) { [weak self] in
                self?.onManage?()
            })
            guard generation == focusGeneration, let window = webView?.window else { return }
            suggestions.show(items, below: screenRect(for: focus.rect), in: window)
            note("suggestions: \(items.count - 1)")
        }
    }

    /// The agent reports the field in CSS pixels of the top viewport. Inside a
    /// cross-origin frame it cannot know the frame's offset, so the list goes
    /// where the pointer is -- which is on the field that was just clicked.
    private func screenRect(for rect: NSRect?) -> NSRect {
        guard let webView, let window = webView.window, let rect else {
            let mouse = NSEvent.mouseLocation
            return NSRect(x: mouse.x - 20, y: mouse.y - 14, width: 260, height: 22)
        }
        let scale = webView.pageZoom * webView.magnification
        var inView = NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        if !webView.isFlipped { inView.origin.y = webView.bounds.height - inView.maxY }
        return window.convertToScreen(webView.convert(inView, to: nil))
    }

    // MARK: - Save and update

    private func decide(_ candidate: Candidate) {
        Task { @MainActor in
            var username = candidate.username
            if username.isEmpty, let hint = usernameHint, hint.origin == candidate.origin, Date().timeIntervalSince(hint.at) < 300 {
                username = hint.username   // typed on the first page of a two-page sign-in
            }

            // A password we generated is already saved; it may only have
            // lacked the username, which sign-up forms often ask for last.
            if let made = generated[candidate.origin], made.password == candidate.password {
                generated[candidate.origin] = nil
                if !username.isEmpty { _ = try? await service.store.update(made.id, username: username, password: nil) }
                note("generated password submitted: entry completed")
                service.changed()
                return
            }

            do {
                var existing: [(credential: Credential, password: String)] = []
                for credential in try await service.store.credentials(forPage: candidate.origin) {
                    existing.append((credential, try await service.store.password(for: credential.id)))
                }
                switch SaveDecision.decide(username: username, password: candidate.password,
                                           currentPassword: candidate.currentPassword, existing: existing) {
                case .nothing:
                    if let used = existing.first(where: { $0.password == candidate.password && (username.isEmpty || $0.credential.username == username) }) {
                        try? await service.store.markUsed(used.credential.id)
                    }
                    note("already saved")
                case .offerSave:
                    guard BrowserSettings.offerToSavePasswords, !service.isNeverSaved(candidate.origin) else {
                        note(service.isNeverSaved(candidate.origin) ? "never for this site" : "offering is off")
                        return
                    }
                    offer(Prompt(mode: .save, origin: candidate.origin, username: username, password: candidate.password))
                case .offerUpdate(let credential):
                    guard BrowserSettings.offerToSavePasswords else { note("offering is off"); return }
                    offer(Prompt(mode: .update(credential), origin: candidate.origin, username: credential.username, password: candidate.password))
                }
            } catch {
                note("could not read the vault: \(error)")
            }
        }
    }

    private func offer(_ prompt: Prompt) {
        self.prompt = prompt
        note(prompt.mode == .save ? "offer save" : "offer update")
        onStateChange?()
        showPromptPopover()
    }

    private func answer(_ decision: PasswordPromptViewController.Decision) {
        guard let prompt else { return }
        self.prompt = nil
        popover?.close()
        onStateChange?()
        Task { @MainActor in
            switch decision {
            case .save(let username, let password):
                do {
                    if case .update(let credential) = prompt.mode {
                        try await service.store.update(credential.id, username: nil, password: password)
                    } else {
                        try await service.store.save(origin: prompt.origin, username: username, password: password)
                    }
                    note("saved")
                    service.changed()
                } catch {
                    note("save failed: \(error)")
                    presentSaveFailure(error)
                }
            case .never:
                service.neverSave(prompt.origin)
                note("never for \(prompt.origin)")
            case .notNow:
                note("not now")
            }
        }
    }

    private func presentSaveFailure(_ error: any Error) {
        guard let window = webView?.window else { return }
        let alert = NSAlert()
        alert.messageText = "The password could not be saved"
        alert.informativeText = Self.describe(error)
        alert.beginSheetModal(for: window)
    }

    static func describe(_ error: any Error) -> String {
        switch error as? CredentialStoreError {
        case .cannotDecrypt:
            return "The saved passwords file could not be opened with the key in your Keychain. It has been left untouched."
        case .keyUnavailable(let reason): return reason
        case .io(let reason): return reason
        case .notFound: return "That password is no longer saved."
        case nil: return error.localizedDescription
        }
    }

    // MARK: - The key button

    var hasPrompt: Bool { prompt != nil }

    /// What the key button does: the waiting question if there is one,
    /// otherwise this site's accounts.
    func toggleFromKeyButton() {
        if let popover, popover.isShown { popover.close(); return }
        if prompt != nil { showPromptPopover() } else { showAccountsPopover() }
    }

    private func showPromptPopover() {
        guard let prompt else { return }
        let controller = PasswordPromptViewController(mode: prompt.mode, origin: prompt.origin, username: prompt.username,
                                                      password: prompt.password) { [weak self] in self?.answer($0) }
        promptController = controller
        present(controller)
    }

    private func showAccountsPopover() {
        let origin = webView?.url.flatMap(CredentialOrigin.origin(of:))
        Task { @MainActor in
            let credentials = origin == nil ? [] : ((try? await service.store.credentials(forPage: origin!)) ?? [])
            let frame = mainFrame
            let controller = SiteAccountsViewController(
                site: origin.map(CredentialOrigin.site(of:)) ?? "", credentials: credentials,
                canFill: mainFrameHasLogin && frame != nil,
                onFill: { [weak self] credential in
                    self?.popover?.close()
                    if let frame, let origin { self?.fill(credential, frame: frame, origin: origin) }
                },
                onManage: { [weak self] in
                    self?.popover?.close()
                    self?.onManage?()
                })
            accountsController = controller
            present(controller)
        }
    }

    private func present(_ controller: NSViewController) {
        popover?.close()
        guard let webView, webView.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        if let item = anchorItem?(), item.isVisible {
            popover.show(relativeTo: item)
        } else {
            // The key button is in the toolbar's overflow menu, or the
            // toolbar is hidden: hang it from the page's top right corner.
            let top = webView.isFlipped ? webView.bounds.minY : webView.bounds.maxY - 1
            popover.show(relativeTo: NSRect(x: webView.bounds.maxX - 60, y: top, width: 1, height: 1), of: webView, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
        promptController = nil
        accountsController = nil
    }

    private func refreshSiteState() {
        let origin = webView?.url.flatMap(CredentialOrigin.origin(of:))
        Task { @MainActor in
            let count = origin == nil ? 0 : ((try? await service.store.credentials(forPage: origin!).count) ?? 0)
            guard count != siteCredentialCount else { return }
            siteCredentialCount = count
            onStateChange?()
        }
    }

    private func note(_ step: String) {
        trace.append(step)
        if trace.count > 400 { trace.removeFirst(100) }
    }
}
