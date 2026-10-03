import AppKit
import WebKit

/// Find in page (⌘F): a bar over the top right of the page, every match
/// highlighted, "3 of 12", ⌘G and ⇧⌘G for the next and the previous.
///
/// The count and the highlights come from WebKit's own find, the one Safari
/// uses, which searches frames too. It is private API, reached by name and
/// probed: where it is missing, the public `find(_:configuration:)` still
/// finds and selects, and the bar says "Found" instead of a count.
@MainActor
final class FindController: NSObject, NSSearchFieldDelegate {
    weak var webView: WKWebView? {
        didSet {
            guard webView !== oldValue else { return }
            attach()
        }
    }
    /// Where the bar goes: over the page.
    weak var container: NSView?
    var onClose: (() -> Void)?

    let bar = NSVisualEffectView()
    let field = NSSearchField()
    let countLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let nextButton = NSButton()
    let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private(set) var matchCount: Int?
    /// Counted from 1, as shown.
    private(set) var matchIndex: Int?
    private(set) var usesPrivateFind = false
    private(set) var isVisible = false
    /// What was last looked for, by ⌘G when the bar is closed, and by ⌘E.
    private(set) var lastQuery = ""

    // _WKFindOptions
    private static let caseInsensitive: UInt = 1 << 0
    private static let backwards: UInt = 1 << 3
    private static let wrapAround: UInt = 1 << 4
    private static let showFindIndicator: UInt = 1 << 6
    private static let showHighlight: UInt = 1 << 7
    private static let determineMatchIndex: UInt = 1 << 9
    private static let findString = NSSelectorFromString("_findString:options:maxCount:")
    private static let hideFindUI = NSSelectorFromString("_hideFindUI")
    private static let setFindDelegate = NSSelectorFromString("_setFindDelegate:")

    override init() {
        super.init()
        build()
    }

    private func build() {
        bar.material = .popover
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setAccessibilityLabel("Find in page")

        field.placeholderString = "Find in page"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(fieldAction(_:))
        field.setAccessibilityLabel("Find in page")
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        for (button, symbol, label, action) in [(previousButton, "chevron.up", "Previous match", #selector(findPrevious(_:))),
                                                (nextButton, "chevron.down", "Next match", #selector(findNext(_:)))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = label + (button === nextButton ? " (⌘G)" : " (⇧⌘G)")
            button.target = self
            button.action = action
        }
        doneButton.bezelStyle = .accessoryBarAction
        doneButton.target = self
        doneButton.action = #selector(done(_:))

        if Keel.chromeEnabled {
            // Design D (G1-05): a flat #171B22 bar with a 1 pt ring.
            bar.appearance = Keel.darkAppearance
            let flat = KeelFill(fill: Keel.raised, border: Keel.menuBorder, radius: 10)
            bar.addSubview(flat)
            NSLayoutConstraint.activate([
                flat.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                flat.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                flat.topAnchor.constraint(equalTo: bar.topAnchor),
                flat.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            ])
            countLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            countLabel.textColor = Keel.muted
        }
        let stack = NSStackView(views: [field, countLabel, previousButton, nextButton, doneButton])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),
        ])
        sync()
    }

    private func attach() {
        guard let webView else { return }
        usesPrivateFind = webView.responds(to: Self.findString) && webView.responds(to: Self.setFindDelegate)
        if usesPrivateFind { _ = webView.perform(Self.setFindDelegate, with: self) }
    }

    // MARK: - Showing

    /// ⌘F. With text selected on the page, that is what is looked for.
    func show(with text: String? = nil) {
        guard let container else { return }
        if !isVisible {
            container.addSubview(bar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                // In Keel's chrome the page is inset from the container's sides.
                bar.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                              constant: -12 - (Keel.chromeEnabled ? BrowserWindowController.keelPageMargin : 4)),
                bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            ])
            isVisible = true
        }
        if let text, !text.isEmpty { field.stringValue = text }
        else if field.stringValue.isEmpty { field.stringValue = lastQuery }
        bar.window?.makeFirstResponder(field)
        field.selectText(nil)
        if !field.stringValue.isEmpty { find(field.stringValue, backwards: false, again: false) } else { sync() }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        bar.removeFromSuperview()
        clearHighlights()
        matchCount = nil
        matchIndex = nil
        sync()
        onClose?()
    }

    /// A new page has nothing found on it yet.
    func didCommitNavigation() {
        matchCount = nil
        matchIndex = nil
        if isVisible, !field.stringValue.isEmpty {
            // The bar stays, as in Safari, and looks on the new page.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.isVisible else { return }
                self.find(self.field.stringValue, backwards: false, again: false)
            }
        }
        sync()
    }

    private func clearHighlights() {
        guard let webView else { return }
        if usesPrivateFind, webView.responds(to: Self.hideFindUI) { _ = webView.perform(Self.hideFindUI) }
    }

    // MARK: - Finding

    /// ⌘E: what is selected on the page becomes what ⌘G looks for.
    func useSelection(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastQuery = trimmed
        field.stringValue = trimmed
    }

    @objc func findNext(_ sender: Any?) { findAgain(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { findAgain(backwards: true) }

    private func findAgain(backwards: Bool) {
        let text = isVisible ? field.stringValue : lastQuery
        guard !text.isEmpty else { show(); return }
        if !isVisible { show(with: text); return }
        find(text, backwards: backwards, again: true)
    }

    @objc private func fieldAction(_ sender: Any?) {
        // Return in the field: the next match, or the previous with ⇧.
        let shift = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let isReturn = NSApp.currentEvent?.type == .keyDown && (NSApp.currentEvent?.keyCode == 36 || NSApp.currentEvent?.keyCode == 76)
        find(field.stringValue, backwards: shift, again: isReturn)
    }

    func controlTextDidChange(_ notification: Notification) {
        find(field.stringValue, backwards: false, again: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            if let webView { webView.window?.makeFirstResponder(webView) }
            return true
        }
        return false
    }

    @objc private func done(_ sender: Any?) {
        hide()
        if let webView { webView.window?.makeFirstResponder(webView) }
    }

    /// - Parameter again: move on from the current match; otherwise the
    ///   search starts over, as it does while the text is being typed.
    func find(_ text: String, backwards: Bool, again: Bool) {
        guard let webView else { return }
        guard !text.isEmpty else {
            clearHighlights()
            matchCount = nil
            matchIndex = nil
            sync()
            return
        }
        lastQuery = text
        if usesPrivateFind, let method = webView.method(for: Self.findString) {
            typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
            var options = Self.caseInsensitive | Self.wrapAround | Self.showHighlight | Self.showFindIndicator | Self.determineMatchIndex
            if backwards { options |= Self.backwards }
            if !again {
                // Typing a longer word must not skip to the match after the
                // one that is showing: start from the top of what is selected.
                webView.evaluateJavaScript("window.getSelection().collapseToStart()", in: nil, in: .defaultClient) { _ in }
            }
            unsafeBitCast(method, to: Find.self)(webView, Self.findString, text as NSString, options, 1000)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.field.stringValue == text || !self.isVisible else { return }
                self.matchCount = result.matchFound ? nil : 0
                self.matchIndex = nil
                self.found = result.matchFound
                self.sync()
            }
        }
    }

    private var found = false

    // MARK: - _WKFindDelegate

    @objc(_webView:didCountMatches:forString:)
    func webView(_ webView: WKWebView, didCountMatches matches: UInt, forString string: String) {
        guard string == lastQuery else { return }
        matchCount = Int(matches)
        sync()
    }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFindMatches matches: UInt, forString string: String, withMatchIndex index: Int) {
        guard string == lastQuery else { return }
        matchCount = Int(matches)
        matchIndex = index >= 0 ? index + 1 : nil
        sync()
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFindString string: String) {
        guard string == lastQuery else { return }
        matchCount = 0
        matchIndex = nil
        sync()
    }

    // MARK: - The bar

    var status: String {
        guard !field.stringValue.isEmpty else { return "" }
        if let count = matchCount {
            if count == 0 { return "Not found" }
            if let index = matchIndex { return "\(index) of \(count)" }
            return count == 1 ? "1 match" : "\(count) matches"
        }
        return usesPrivateFind ? "" : (found ? "Found" : "")
    }

    private func sync() {
        countLabel.stringValue = status
        countLabel.textColor = matchCount == 0 ? .systemRed : .secondaryLabelColor
        let some = !field.stringValue.isEmpty && matchCount != 0
        previousButton.isEnabled = some
        nextButton.isEnabled = some
    }
}
