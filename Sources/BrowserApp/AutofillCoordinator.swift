import AppKit
import WebKit
import PasswordKit

/// Addresses, cards and one-time codes in a tab's forms.
///
/// The agent in the page describes the form around the field in focus; what
/// each field is for is decided here (`AutofillClassifier`), and the list
/// under the field is a native panel the page cannot read. One choice fills
/// the whole form, name, address and card; a card is filled only after the
/// person has confirmed it is them (Touch ID or the Mac's password). Its
/// security code is never kept, and never filled.
@MainActor
final class AutofillCoordinator: NSObject, WKScriptMessageHandler {
    static let worldName = "KeelAutofill"
    static let handlerName = "simpleBrowserAutofill"
    static let passkeyHandlerName = "simpleBrowserPasskeys"

    let service: PasswordService
    weak var webView: WKWebView?
    /// False in private windows: nothing typed there is offered to be kept.
    var allowsSaving = true
    var onManage: (() -> Void)?
    private(set) var installError: String?

    private let world = WKContentWorld.world(name: AutofillCoordinator.worldName)
    private weak var userContentController: WKUserContentController?
    let suggestions = CredentialSuggestionPanel()
    private var keyMonitor: Any?
    private var focus: (frame: WKFrameInfo, kinds: [AutofillFieldKind?], index: Int, rect: NSRect?)?
    private var generation = 0

    /// For the self-test: the last list offered, and what is waiting to be saved.
    private(set) var offered: [String] = []
    private(set) var pendingSave: (address: AutofillAddress?, card: AutofillCard?)?
    private(set) var savePopover: NSPopover?
    private(set) var codePopover: NSPopover?
    private(set) weak var codeField: NSTextField?

    init(service: PasswordService) {
        self.service = service
    }

    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        guard let url = AppResources.bundle.url(forResource: "autofill-agent", withExtension: "js", subdirectory: "AutofillAgent"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            installError = "autofill-agent.js is missing from the app's resources"
            return
        }
        controller.add(self, contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        // The first passkey a page asks for is when the browser asks macOS
        // for passkeys, as Chrome does. It says only that it asked.
        controller.add(self, contentWorld: .page, name: Self.passkeyHandlerName)
        controller.addUserScript(WKUserScript(source: """
            (() => {
              const proto = window.CredentialsContainer && CredentialsContainer.prototype;
              if (!proto) return;
              for (const name of ["create", "get"]) {
                const original = proto[name];
                if (typeof original !== "function") continue;
                // defineProperty: a plain assignment is silently refused here.
                Object.defineProperty(proto, name, { configurable: true, writable: true, value: function (options) {
                  if (options && options.publicKey) { try { window.webkit.messageHandlers.\(Self.passkeyHandlerName).postMessage(name); } catch (e) {} }
                  return original.call(this, options);
                } });
              }
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.webView?.window else { return event }
            return self.suggestions.handleKeyDown(event) ? nil : event
        }
    }

    func uninstall() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
        userContentController?.removeScriptMessageHandler(forName: Self.passkeyHandlerName, contentWorld: .page)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        suggestions.hide()
        savePopover?.close()
        codePopover?.close()
    }

    // MARK: - From the page

    /// For the self-test: pages that asked for a passkey.
    private(set) var passkeyRequests = 0

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.passkeyHandlerName {
            passkeyRequests += 1
            if PasskeyAccess.hasEntitlement, PasskeyAccess.state == .notDetermined {
                Task { @MainActor in _ = await PasskeyAccess.requestAuthorization() }
            }
            return
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "focus": handleFocus(body, frame: message.frameInfo)
        case "blur", "input":
            generation += 1
            suggestions.hide()
        case "submit": handleSubmit(body)
        default: break
        }
    }

    private static func descriptors(_ body: [String: Any]) -> [(AutofillFieldDescriptor, String)] {
        (body["fields"] as? [[String: Any]] ?? []).map { field in
            func text(_ key: String) -> String { field[key] as? String ?? "" }
            return (AutofillFieldDescriptor(tag: text("tag"), type: text("type"), autocomplete: text("autocomplete"), name: text("name"),
                                            id: text("id"), placeholder: text("placeholder"), label: text("label")), text("value"))
        }
    }

    private func handleFocus(_ body: [String: Any], frame: WKFrameInfo) {
        guard BrowserSettings.autofillForms else { return }
        let fields = Self.descriptors(body)
        let kinds = AutofillClassifier.kinds(of: fields.map(\.0))
        let index = (body["focused"] as? NSNumber)?.intValue ?? -1
        guard kinds.indices.contains(index), let focused = kinds[index] else { suggestions.hide(); return }
        var rect: NSRect?
        if let r = body["rect"] as? [String: Any], let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
           let width = (r["width"] as? NSNumber)?.doubleValue, let height = (r["height"] as? NSNumber)?.doubleValue {
            rect = NSRect(x: x, y: y, width: width, height: height)
        }
        focus = (frame, kinds, index, rect)
        generation += 1
        if focused == .oneTimeCode {
            showCodeField()
            return
        }
        let current = generation
        Task { @MainActor in
            guard let contents = try? await service.autofill?.contents(), current == generation else { return }
            let items = offers(for: focused, kinds: kinds, contents: contents)
            offered = items.map(\.title)
            guard !items.isEmpty, let window = webView?.window else { suggestions.hide(); return }
            suggestions.show(items, below: screenRect(for: rect), in: window)
        }
    }

    /// What to offer for this field: with a form that has both, the whole
    /// of it first ("Home · Visa •••• 4242"), then each address or card.
    private func offers(for focused: AutofillFieldKind, kinds: [AutofillFieldKind?], contents: AutofillVault.Contents) -> [CredentialSuggestionPanel.Item] {
        let wantsCard = kinds.contains(.cardNumber)
        let wantsAddress = kinds.contains { $0?.isAddress == true && $0 != .email && $0 != .phone } || (!wantsCard && kinds.contains { $0?.isAddress == true })
        var items: [CredentialSuggestionPanel.Item] = []
        if wantsCard, wantsAddress, let address = contents.addresses.first, let card = contents.cards.first {
            items.append(.init(title: "\(address.label.isEmpty ? address.fullName : address.label) · \(card.masked)", subtitle: "Name, address and card",
                               symbol: "wand.and.stars") { [weak self] in self?.choose(address: address, card: card) })
        }
        if focused.isCard {
            for card in contents.cards {
                items.append(.init(title: card.masked, subtitle: [card.nameOnCard, card.expiry.isEmpty ? "" : "expires \(card.expiry)"].filter { !$0.isEmpty }.joined(separator: ", "),
                                   symbol: "creditcard") { [weak self] in self?.choose(address: nil, card: card) })
            }
        } else {
            for address in contents.addresses {
                items.append(.init(title: address.summary, subtitle: [address.fullName, address.email].filter { !$0.isEmpty }.joined(separator: " · "),
                                   symbol: "house") { [weak self] in self?.choose(address: address, card: nil) })
            }
        }
        guard !items.isEmpty else { return [] }
        items.append(.init(title: "AutoFill Settings…", subtitle: nil, symbol: "gearshape", isFooter: true) { [weak self] in self?.onManage?() })
        return items
    }

    /// Fills the form: after the person confirms it is them, when a card is in it.
    func choose(address: AutofillAddress?, card: AutofillCard?) {
        guard let focus else { return }
        Task { @MainActor in
            if card != nil, !(await service.authenticator.authenticate(reason: "fill your card details")) { return }
            let values = AutofillFill.values(for: focus.kinds, address: address, card: card)
            let strings = Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
            _ = try? await webView?.callAsyncJavaScript("return window.__simpleBrowserAutofill.fill(values)", arguments: ["values": strings],
                                                        in: focus.frame, contentWorld: world)
        }
    }

    // MARK: - Saving what was typed

    private func handleSubmit(_ body: [String: Any]) {
        guard allowsSaving, BrowserSettings.autofillForms else { return }
        let fields = Self.descriptors(body)
        let captured = AutofillFill.captured(kinds: AutofillClassifier.kinds(of: fields.map(\.0)), values: fields.map(\.1))
        guard captured.address != nil || captured.card != nil else { return }
        Task { @MainActor in
            let contents = (try? await service.autofill?.contents()) ?? .init()
            let address = captured.address.flatMap { new in contents.addresses.contains { $0.isSame(as: new) } ? nil : new }
            let card = captured.card.flatMap { new in contents.cards.contains { $0.number == new.number } ? nil : new }
            guard address != nil || card != nil else { return }
            pendingSave = (address, card)
            offerToSave(address: address, card: card)
        }
    }

    private func offerToSave(address: AutofillAddress?, card: AutofillCard?) {
        guard let webView, webView.window != nil else { return }
        let what = [card.map { "your card \($0.masked)" }, address.map { "the address \($0.streetLines.first ?? $0.summary)" }].compactMap { $0 }
        let controller = AutofillSavePrompt(message: "Save \(what.joined(separator: " and ")) for AutoFill?",
                                            detail: card == nil ? "It is kept encrypted with your passwords." : "It is kept encrypted with your passwords. Its security code is not kept.") { [weak self] save in
            self?.answerSave(save)
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        let anchor = focus?.rect.map { rect -> NSRect in
            let scale = webView.pageZoom
            var inView = NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            if !webView.isFlipped { inView.origin.y = webView.bounds.height - inView.maxY }
            return inView
        } ?? NSRect(x: webView.bounds.midX, y: webView.bounds.maxY - 10, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: webView, preferredEdge: .maxY)
        savePopover = popover
    }

    func answerSave(_ save: Bool) {
        savePopover?.close()
        savePopover = nil
        guard save, let pending = pendingSave else { pendingSave = nil; return }
        pendingSave = nil
        Task { @MainActor in
            if let address = pending.address { try? await service.autofill?.save(address) }
            if let card = pending.card { try? await service.autofill?.save(card) }
            NotificationCenter.default.post(name: PasswordService.didChange, object: service)
        }
    }

    // MARK: - One-time codes

    /// A native field for the code, where macOS AutoFill offers the one just
    /// sent by text message or email; what is put in it goes to the page.
    private func showCodeField() {
        guard let webView, webView.window != nil, let focus else { return }
        codePopover?.close()
        let controller = OneTimeCodeController { [weak self] code in self?.fillCode(code) }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        var anchor = NSRect(x: webView.bounds.midX, y: webView.bounds.maxY - 10, width: 1, height: 1)
        if let rect = focus.rect {
            let scale = webView.pageZoom
            anchor = NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            if !webView.isFlipped { anchor.origin.y = webView.bounds.height - anchor.maxY }
        }
        popover.show(relativeTo: anchor, of: webView, preferredEdge: .minY)
        codePopover = popover
        codeField = controller.field
    }

    func fillCode(_ code: String) {
        codePopover?.close()
        guard let focus, !code.isEmpty else { return }
        Task { @MainActor in
            _ = try? await webView?.callAsyncJavaScript("return window.__simpleBrowserAutofill.fill(values)",
                                                        arguments: ["values": [String(focus.index): code]], in: focus.frame, contentWorld: world)
            webView?.window?.makeFirstResponder(webView)
        }
    }

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
}

/// "Save your card Visa •••• 4444 for AutoFill?"
final class AutofillSavePrompt: NSViewController {
    private let message: String
    private let detail: String
    private let answer: (Bool) -> Void

    init(message: String, detail: String, answer: @escaping (Bool) -> Void) {
        self.message = message
        self.detail = detail
        self.answer = answer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let title = NSTextField(wrappingLabelWithString: message)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: detail)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let notNow = NSButton(title: "Not Now", target: self, action: #selector(notNow(_:)))
        let buttons = NSStackView(views: [NSView(), notNow, save])
        let stack = NSStackView(views: [title, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        title.widthAnchor.constraint(equalToConstant: 280).isActive = true
        note.widthAnchor.constraint(equalToConstant: 280).isActive = true
        buttons.widthAnchor.constraint(equalToConstant: 280).isActive = true
        view = stack
    }

    @objc private func save(_ sender: Any?) { answer(true) }
    @objc private func notNow(_ sender: Any?) { answer(false) }
}

/// The code field: macOS offers the code that just arrived in Messages or Mail.
final class OneTimeCodeController: NSViewController, NSTextFieldDelegate {
    let field = NSTextField()
    private let done: (String) -> Void

    init(done: @escaping (String) -> Void) {
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Verification code")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        field.contentType = .oneTimeCode
        field.placeholderString = "From Messages or Mail"
        field.delegate = self
        field.setAccessibilityLabel("Verification code")
        let fill = NSButton(title: "Fill", target: self, action: #selector(fill(_:)))
        fill.keyEquivalent = "\r"
        let row = NSStackView(views: [field, fill])
        let stack = NSStackView(views: [title, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc func fill(_ sender: Any?) { done(field.stringValue.trimmingCharacters(in: .whitespaces)) }
}
