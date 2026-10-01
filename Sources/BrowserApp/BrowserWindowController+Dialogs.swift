import AppKit
import WebKit

/// An `alert()`, `confirm()` or `prompt()` the page has open, shown as a
/// sheet on the tab's window. The person answers it with the buttons; an
/// agent answers it with `handle_dialog`, which presses the same buttons.
@MainActor
final class PageDialog {
    enum Kind: String { case alert, confirm, prompt }

    let kind: Kind
    let message: String
    let defaultText: String?
    let origin: String
    let alert: NSAlert
    let field: NSTextField?

    init(kind: Kind, message: String, defaultText: String?, origin: String, alert: NSAlert, field: NSTextField?) {
        self.kind = kind; self.message = message; self.defaultText = defaultText
        self.origin = origin; self.alert = alert; self.field = field
    }

    var summary: String {
        var text = "A \(kind.rawValue)() dialog from \(origin) is open: \"\(message)\""
        if kind == .prompt { text += " (default text: \"\(defaultText ?? "")\")" }
        return text + ". Answer it with handle_dialog."
    }
}

extension BrowserWindowController {

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await presentDialog(.alert, message: message, defaultText: nil, frame: frame)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await presentDialog(.confirm, message: message, defaultText: nil, frame: frame).accepted
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let answer = await presentDialog(.prompt, message: prompt, defaultText: defaultText, frame: frame)
        return answer.accepted ? answer.text : nil
    }

    private func presentDialog(_ kind: PageDialog.Kind, message: String, defaultText: String?, frame: WKFrameInfo) async -> (accepted: Bool, text: String?) {
        let origin = frame.securityOrigin.host.isEmpty ? (frame.request.url?.absoluteString ?? "this page") : frame.securityOrigin.host
        // One dialog at a time, as in every browser; one behind another sheet is declined.
        guard pageDialog == nil, let window = shownWindow, window.attachedSheet == nil else {
            return (kind == .alert, nil)
        }
        let alert = NSAlert()
        alert.messageText = origin == "this page" ? "This page says" : "\(origin) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if kind != .alert { alert.addButton(withTitle: "Cancel") }
        var field: NSTextField?
        if kind == .prompt {
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            field = input
        }
        let dialog = PageDialog(kind: kind, message: message, defaultText: defaultText, origin: origin, alert: alert, field: field)
        pageDialog = dialog
        if !window.isKeyWindow, !QuietMode.isOn { NSApp.requestUserAttention(.informationalRequest) }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            if let field { alert.window.makeFirstResponder(field) }
        }
        pageDialog = nil
        return (response == .alertFirstButtonReturn, field?.stringValue)
    }

    /// Presses the dialog's OK or Cancel. False when none is open.
    @discardableResult
    func answerDialog(accept: Bool, text: String?) -> Bool {
        guard let dialog = pageDialog, let window = dialog.alert.window.sheetParent else { return false }
        if let text, let field = dialog.field { field.stringValue = text }
        window.endSheet(dialog.alert.window, returnCode: accept || dialog.kind == .alert ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        return true
    }
}
