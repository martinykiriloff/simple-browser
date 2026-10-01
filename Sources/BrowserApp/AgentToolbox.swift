import AppKit
import WebKit
import AgentKit
import BrowserKit
import InspectKit

/// What the agent endpoint remembers about a tab it has driven.
@MainActor
final class AgentTabState {
    /// The person has been told an agent is driving this tab.
    var announced = false
}

/// The MCP tools, implemented against the browser's tabs. Everything here
/// runs on the main actor, as the tabs do; the page work happens in the
/// automation agent (isolated world) and the input in `AgentInput`.
@MainActor
final class AgentToolbox {

    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The browser's tabs, front window first.
    var tabs: () -> [BrowserWindowController] = { [] }
    var openTab: (_ beside: BrowserWindowController?, _ url: URL?, _ inFront: Bool) -> BrowserWindowController? = { _, _, _ in nil }
    let recorder: InspectorRecorder
    /// The client named in `initialize`, for what the person is told.
    var clientName = "An AI agent"
    /// One line per tool call, for Settings → Developer.
    var onActivity: ((String) -> Void)?

    private weak var currentTab: BrowserWindowController?

    init(recorder: InspectorRecorder) {
        self.recorder = recorder
    }

    func call(_ name: String, _ arguments: JSONValue) async -> MCPToolResult {
        let started = Date()
        let result: MCPToolResult
        do {
            result = try await perform(name, arguments)
        } catch {
            result = .error(Self.message(for: error))
        }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        onActivity?("\(name)\(result.isError ? " ✗" : "") · \(milliseconds) ms")
        return result
    }

    private func perform(_ name: String, _ a: JSONValue) async throws -> MCPToolResult {
        switch name {
        case "list_tabs": return listTabs()
        case "new_tab": return try await newTab(a)
        case "select_tab": return try selectTab(a)
        case "close_tab": return try closeTab(a)
        case "navigate": return try await navigate(a)
        case "wait_for": return try await waitFor(a)
        case "snapshot": return try await snapshot(a)
        case "get_page_content": return try await pageContent(a)
        case "screenshot": return try await screenshot(a)
        case "click": return try await click(a)
        case "hover": return try await hover(a)
        case "fill": return try await fill(a)
        case "fill_form": return try await fillForm(a)
        case "type_text": return try await typeText(a)
        case "press_key": return try await pressKey(a)
        case "select_option": return try await selectOption(a)
        case "scroll": return try await scroll(a)
        case "drag": return try await drag(a)
        case "upload_files": return try await uploadFiles(a)
        case "handle_dialog": return try handleDialog(a)
        case "evaluate": return try await evaluate(a)
        case "console_messages": return try consoleMessages(a)
        case "network_requests": return try networkRequests(a)
        case "network_request": return try await networkRequest(a)
        case "inspect_element": return try await inspectElement(a)
        case "performance_metrics": return try await performanceMetrics(a)
        case "storage": return try await storage(a)
        case "emulate": return try await emulate(a)
        case "devtools": return try await devtools(a)
        default: throw ToolError("Unknown tool \(name)")
        }
    }

    // MARK: - Tabs

    static func shortID(_ tab: BrowserWindowController) -> String {
        String(tab.tab.rawValue.uuidString.prefix(8)).lowercased()
    }

    private func frontmost() -> BrowserWindowController? {
        let all = tabs()
        for window in NSApp.orderedWindows {
            if let tab = all.first(where: { $0.window === window && $0.window?.tabGroup?.selectedWindow.map { $0 === window } ?? true }) { return tab }
        }
        return all.first
    }

    private func tab(_ a: JSONValue) throws -> BrowserWindowController {
        let all = tabs()
        if let id = a["tabId"]?.string?.lowercased().trimmingCharacters(in: .whitespaces), !id.isEmpty {
            let matches = all.filter { Self.shortID($0).hasPrefix(id) || $0.tab.rawValue.uuidString.lowercased() == id }
            guard let match = matches.first else { throw ToolError("No tab with id \(id). Call list_tabs for the open tabs.") }
            return match
        }
        if let currentTab, all.contains(where: { $0 === currentTab }) { return currentTab }
        guard let front = frontmost() else { throw ToolError("No browser window is open. Use new_tab.") }
        return front
    }

    /// A tab about to be acted on: awake, shown in its window, and the
    /// person told who is driving it.
    private func ready(_ tab: BrowserWindowController, show: Bool = true) async throws {
        if tab.isHibernated {
            tab.wake()
            try await waitForLoad(tab, timeout: 15)
        }
        if show, let window = tab.window, let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        let state = tab.agentState ?? AgentTabState()
        tab.agentState = state
        if !state.announced {
            state.announced = true
            tab.showNotice("\(clientName) is controlling this tab through the agent server (Settings → Developer).", seconds: 6)
        }
    }

    private func title(of tab: BrowserWindowController) -> String {
        let title = tab.pageWebView.title ?? ""
        return title.isEmpty ? (tab.window?.title ?? "") : title
    }

    private func listTabs() -> MCPToolResult {
        let all = tabs()
        guard !all.isEmpty else { return .text("No tabs are open. Use new_tab.") }
        let target = (try? tab([:]))
        let windows = NSApp.orderedWindows
        var lines = ["Tabs (* = the tab tools act on by default):"]
        for tab in all {
            var flags: [String] = []
            if tab.window?.tabGroup?.selectedWindow === tab.window || tab.window?.tabGroup == nil { flags.append("shown") }
            if tab.window?.isKeyWindow == true { flags.append("focused") }
            if tab.pageWebView.isLoading { flags.append("loading") }
            if tab.isHibernated { flags.append("asleep") }
            if tab.isPrivate { flags.append("private") }
            if tab.pageDialog != nil { flags.append("dialog open") }
            if tab.isDevToolsVisible { flags.append("devtools open") }
            let windowIndex = windows.firstIndex { $0 === tab.window?.tabGroup?.selectedWindow || $0 === tab.window }.map { " window \($0 + 1)" } ?? ""
            let mark = tab === target ? "*" : " "
            lines.append("\(mark) \(Self.shortID(tab))  \(title(of: tab).isEmpty ? "(untitled)" : title(of: tab)) — \(tab.currentURL?.absoluteString ?? "about:blank")  [\(flags.joined(separator: ", "))\(windowIndex.isEmpty ? "" : ";" + windowIndex)]")
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func newTab(_ a: JSONValue) async throws -> MCPToolResult {
        var url: URL?
        if let text = a["url"]?.string, !text.isEmpty {
            guard let resolved = BrowserSettings.destination(for: text) else { throw ToolError("Cannot make a URL of \(text)") }
            url = resolved
        }
        let background = a["background"]?.bool ?? false
        guard let opened = openTab((try? tab([:])), url, !background) else { throw ToolError("Could not open a tab") }
        currentTab = opened
        try await ready(opened, show: !background)
        if url != nil { try await waitForLoad(opened, timeout: 30) }
        return .text("Opened tab \(Self.shortID(opened)). Later tools act on it.\n" + pageLine(opened))
    }

    private func selectTab(_ a: JSONValue) throws -> MCPToolResult {
        let target = try tab(a)
        currentTab = target
        if a["bringToFront"]?.bool ?? true, let window = target.window {
            window.tabGroup?.selectedWindow = window
            window.orderFront(nil)
        }
        return .text("Selected tab \(Self.shortID(target)).\n" + pageLine(target))
    }

    private func closeTab(_ a: JSONValue) throws -> MCPToolResult {
        let target = try tab(a)
        let id = Self.shortID(target)
        target.window?.performClose(nil)
        if currentTab === target { currentTab = nil }
        return .text("Closed tab \(id).")
    }

    // MARK: - Navigation

    private func navigate(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let action = a["action"]?.string ?? "goto"
        let since = recorder.events.last?.sequence ?? -1
        let webView = tab.pageWebView
        switch action {
        case "goto":
            guard let text = a["url"]?.string, !text.isEmpty else { throw ToolError("navigate needs a url") }
            guard let url = BrowserSettings.destination(for: text) else { throw ToolError("Cannot make a URL of \(text)") }
            tab.load(url)
        case "back":
            guard webView.canGoBack else { throw ToolError("There is no page to go back to") }
            tab.goBack(nil)
        case "forward":
            guard webView.canGoForward else { throw ToolError("There is no page to go forward to") }
            tab.goForward(nil)
        case "reload": tab.reload(nil)
        case "reload_bypassing_cache": tab.reloadFromOrigin(nil)
        case "stop":
            tab.stopLoading(nil)
            return .text("Stopped.\n" + pageLine(tab))
        default: throw ToolError("Unknown action \(action)")
        }
        let timeout = Double(a["timeoutMs"]?.int ?? 30000) / 1000
        switch a["waitUntil"]?.string ?? "load" {
        case "none": break
        case "commit":
            try await waitUntil(timeout: timeout) { !webView.isLoading || webView.estimatedProgress > 0.1 }
        default:
            try await waitForLoad(tab, timeout: timeout)
        }
        return .text(navigationReport(tab, since: since))
    }

    /// Final URL, title, status, and what went wrong on the way.
    private func navigationReport(_ tab: BrowserWindowController, since: Int) -> String {
        var lines = [pageLine(tab)]
        let events = recorder.events.filter { $0.tab == tab.tab && $0.sequence > since }
        if let response = events.reversed().compactMap({ recorded -> NetworkEvent? in
            if case .network(let event) = recorded.event, event.source == .navigationDelegate, event.initiator == "navigation" { return event }
            return nil
        }).first, let status = response.statusCode {
            lines.append("HTTP \(status)" + (response.responseHeaders["content-type"].map { " · \($0)" } ?? ""))
        }
        for recorded in events {
            if case .navigation(let event) = recorded.event, event.phase == .failed {
                lines.append("Navigation failed: \(event.detail ?? event.url.absoluteString)")
            }
        }
        lines.append(contentsOf: problems(tab, since: since))
        if tab.pageWebView.isLoading { lines.append("Still loading.") }
        return lines.joined(separator: "\n")
    }

    private func pageLine(_ tab: BrowserWindowController) -> String {
        "Page: \(title(of: tab).isEmpty ? "(untitled)" : title(of: tab)) — \(tab.currentURL?.absoluteString ?? "about:blank")"
    }

    private func waitForLoad(_ tab: BrowserWindowController, timeout: Double) async throws {
        // Give a navigation just requested the moment it needs to start.
        try await Task.sleep(for: .milliseconds(60))
        try await waitUntil(timeout: timeout, orDialogIn: tab) { !tab.pageWebView.isLoading }
    }

    private func waitUntil(timeout: Double, orDialogIn tab: BrowserWindowController? = nil, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try await condition() { return }
            if let tab, tab.pageDialog != nil { return }
            if Date() > deadline { throw ToolError("Timed out after \(Int(timeout * 1000)) ms") }
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    private func waitFor(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let timeout = Double(a["timeoutMs"]?.int ?? 10000) / 1000
        if let time = a["timeMs"]?.int {
            try await Task.sleep(for: .milliseconds(min(time, 120_000)))
            return .text("Waited \(time) ms.\n" + pageLine(tab))
        }
        if a["networkIdle"]?.bool == true {
            var quietSince = Date()
            var lastCount = networkEventCount(tab)
            try await waitUntil(timeout: timeout, orDialogIn: tab) {
                let count = networkEventCount(tab)
                if count != lastCount || tab.pageWebView.isLoading { lastCount = count; quietSince = Date() }
                return Date().timeIntervalSince(quietSince) >= 0.5
            }
            return .text("The network is idle.\n" + pageLine(tab))
        }
        var condition: [String: JSONValue] = [:]
        for key in ["text", "textGone", "selector", "selectorGone"] { if let value = a[key], !value.isNull { condition[key] = value } }
        guard condition.count == 1 else { throw ToolError("Give exactly one of text, textGone, selector, selectorGone, networkIdle or timeMs") }
        do {
            try await waitUntil(timeout: timeout, orDialogIn: tab) {
                // Between documents there is nothing to ask; keep waiting.
                (try? await self.automation(tab, "check", .object(condition)))?.bool ?? false
            }
        } catch let error as ToolError {
            throw ToolError(error.message + " waiting for \(condition.first!.key) \(condition.first!.value.jsonString)")
        }
        if let dialog = tab.pageDialog { return .text(dialog.summary) }
        return .text("Done: \(condition.first!.key) \(condition.first!.value.jsonString).\n" + pageLine(tab))
    }

    private func networkEventCount(_ tab: BrowserWindowController) -> Int {
        recorder.count { recorded in
            if recorded.tab == tab.tab, case .network = recorded.event { return true }
            return false
        }
    }

    // MARK: - The automation agent

    private static let automationSource: String = {
        guard let url = AppResources.bundle.url(forResource: "automation-agent", withExtension: "js", subdirectory: "AutomationAgent"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    private let world = WKContentWorld.world(name: InspectorAgent.isolatedWorldName)

    /// Calls `__sbAutomation.handle(method, params)` in the isolated world,
    /// injecting the agent first if this document has not had it yet.
    private func automation(_ tab: BrowserWindowController, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        guard !Self.automationSource.isEmpty else { throw ToolError("The automation agent is missing from the app bundle") }
        let body = Self.automationSource + "\nreturn window.__sbAutomation.handle(method, params);"
        let result = JSONValue(any: try await script(tab, body, arguments: ["method": method, "params": params.anyValue], world: world))
        if let failure = result["__automationError"]?.string { throw ToolError(failure) }
        return result
    }

    /// Runs a script, unless a dialog is open or opens meanwhile: the page's
    /// thread is then blocked and the script would not return until the
    /// dialog is answered.
    private func script(_ tab: BrowserWindowController, _ body: String, arguments: [String: Any], world: WKContentWorld) async throws -> Any? {
        if let dialog = tab.pageDialog { throw ToolError(dialog.summary) }
        let webView = tab.pageWebView
        let gate = Gate()
        let sendable = SendableBox(arguments)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendableBox<Any?>, any Error>) in
            Task { @MainActor in
                do {
                    let value = try await webView.callAsyncJavaScript(body, arguments: sendable.value, in: nil, contentWorld: world)
                    if gate.open() { continuation.resume(returning: SendableBox(value)) }
                } catch {
                    if gate.open() { continuation.resume(throwing: ToolError(Self.message(for: error))) }
                }
            }
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(60)
                while !gate.isClosed {
                    if let dialog = tab.pageDialog, gate.open() { continuation.resume(throwing: ToolError(dialog.summary)); return }
                    if Date() > deadline, gate.open() { continuation.resume(throwing: ToolError("The page did not answer within 60 s (busy, or paused in the debugger)")); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }.value
    }

    /// The text of a script error, as the page reported it.
    static func message(for error: any Error) -> String {
        let ns = error as NSError
        if let message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String {
            let line = (ns.userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber).map { " (line \($0))" } ?? ""
            return message.replacingOccurrences(of: "^Error: ", with: "", options: .regularExpression) + line
        }
        if let toolError = error as? ToolError { return toolError.message }
        return error.localizedDescription
    }

    // MARK: - Reading the page

    private func snapshot(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        var params: [String: JSONValue] = [:]
        for key in ["selector", "ref", "interactiveOnly", "maxLength"] { if let value = a[key] { params[key] = value } }
        let result = try await automation(tab, "snapshot", .object(params))
        var lines = ["Page: \(result["title"]?.string ?? "") — \(result["url"]?.string ?? "")"]
        if let dialog = tab.pageDialog { lines.append(dialog.summary) }
        if let modal = result["modal"]?.string { lines.append("A modal <dialog> is open: [ref=\(modal)]") }
        if let focused = result["focused"]?.string { lines.append("Focused: [ref=\(focused)]") }
        lines.append("```yaml")
        lines.append(result["text"]?.string ?? "")
        lines.append("```")
        if result["truncated"]?.bool == true {
            lines.append("(Truncated. Pass selector or ref to snapshot part of the page, or interactiveOnly: true.)")
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func pageContent(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        var params: [String: JSONValue] = ["format": a["format"] ?? "markdown"]
        for key in ["ref", "selector", "maxLength"] { if let value = a[key] { params[key] = value } }
        let result = try await automation(tab, "content", .object(params))
        return .text("Page: \(result["title"]?.string ?? "") — \(result["url"]?.string ?? "")\n\n" + (result["text"]?.string ?? ""))
    }

    // MARK: - Screenshots

    private func screenshot(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let webView = tab.pageWebView
        let jpeg = a["format"]?.string == "jpeg"
        let quality = Double(min(max(a["quality"]?.int ?? 80, 1), 100)) / 100
        var note = ""
        let image: CGImage

        if a["fullPage"]?.bool == true, a["ref"] == nil, a["selector"] == nil {
            let size = try await automation(tab, "pageSize")
            let data = try await webView.pdf(configuration: WKPDFConfiguration())
            guard let rep = NSPDFImageRep(data: data) else { throw ToolError("Could not render the page") }
            let cssWidth = size["width"]?.double ?? rep.bounds.width
            // Readable but bounded: at most 1280 CSS px wide and 8000 px tall.
            let scale = min(1, 1280 / max(cssWidth, 1)) * (rep.bounds.width > 0 ? cssWidth / rep.bounds.width : 1)
            var pixelSize = CGSize(width: rep.bounds.width * scale, height: rep.bounds.height * scale)
            if pixelSize.height > 8000 {
                note = "\n(Cut at 8000 px of \(Int(pixelSize.height)); scroll and take viewport screenshots for the rest.)"
                pixelSize.height = 8000
            }
            image = try Self.render(rep, size: pixelSize, scale: scale)
        } else {
            let configuration = WKSnapshotConfiguration()
            var describe = "the viewport"
            if a["ref"] != nil || a["selector"] != nil {
                let rect = try await automation(tab, "rect", Self.targetParams(a))
                let zoom = webView.pageZoom * webView.magnification
                var frame = CGRect(x: (rect["x"]?.double ?? 0) * zoom, y: (rect["y"]?.double ?? 0) * zoom,
                                   width: (rect["width"]?.double ?? 0) * zoom, height: (rect["height"]?.double ?? 0) * zoom)
                let visible = frame.intersection(CGRect(origin: .zero, size: webView.bounds.size))
                guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { throw ToolError("The element has no visible area") }
                if visible.size != frame.size { note = "\n(Only the part of the element inside the viewport was captured.)" }
                frame = visible
                if !webView.isFlipped { frame.origin.y = webView.bounds.height - frame.maxY }
                configuration.rect = frame
                describe = rect["describe"]?.string ?? "the element"
            }
            configuration.afterScreenUpdates = true
            let snapshot = try await webView.takeSnapshot(configuration: configuration)
            guard let cg = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ToolError("Could not capture the page") }
            // One pixel per CSS pixel: what the page measures in, and lighter.
            let target = configuration.rect == .null ? webView.bounds.size : configuration.rect.size
            image = try Self.resize(cg, to: CGSize(width: target.width / webView.pageZoom, height: target.height / webView.pageZoom))
            note = "Screenshot of \(describe)." + note
        }

        guard let data = Self.encode(image, jpeg: jpeg, quality: quality) else { throw ToolError("Could not encode the image") }
        var text = note.isEmpty ? "Screenshot of the full page." : note.trimmingCharacters(in: .newlines)
        if let path = a["savePath"]?.string, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try data.write(to: url, options: .atomic)
            text += "\nSaved to \(url.path)."
        }
        text += "\n\(image.width)×\(image.height) \(jpeg ? "JPEG" : "PNG"), \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))."
        return MCPToolResult([.image(base64: data.base64EncodedString(), mimeType: jpeg ? "image/jpeg" : "image/png"), .text(text)])
    }

    private static func render(_ rep: NSPDFImageRep, size: CGSize, scale: CGFloat) throws -> CGImage {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError("The page is empty")
        }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // PDF space starts at the bottom; keep the top of the page.
        context.translateBy(x: 0, y: CGFloat(height) - rep.bounds.height * scale)
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        rep.draw(in: rep.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw ToolError("Could not render the page") }
        return image
    }

    private static func resize(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        if width == image.width && height == image.height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func encode(_ image: CGImage, jpeg: Bool, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) : rep.representation(using: .png, properties: [:])
    }

    // MARK: - Acting

    static func targetParams(_ a: JSONValue) -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let ref = a["ref"]?.string { params["ref"] = .string(ref) }
        if let selector = a["selector"]?.string { params["selector"] = .string(selector) }
        return .object(params)
    }

    /// Scrolls the element into view and finds where to press, refusing
    /// what a person could not click.
    private func aim(_ tab: BrowserWindowController, _ a: JSONValue, allowCovered: Bool = false) async throws -> (CGPoint, JSONValue) {
        let target = try await automation(tab, "prepare", Self.targetParams(a))
        let describe = target["describe"]?.string ?? "the element"
        if let problem = target["problem"]?.string { throw ToolError("\(describe) \(problem)") }
        if target["disabled"]?.bool == true { throw ToolError("\(describe) is disabled") }
        if !allowCovered, let covered = target["covered"]?.string {
            throw ToolError("\(describe) is covered by \(covered), which would get the click. Close or scroll past it first, or act on it.")
        }
        // Let the scroll settle before the event lands.
        try await Task.sleep(for: .milliseconds(30))
        return (CGPoint(x: target["x"]?.double ?? 0, y: target["y"]?.double ?? 0), target)
    }

    private func click(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let since = recorder.events.last?.sequence ?? -1
        let urlBefore = tab.pageWebView.url
        let button = a["button"]?.string ?? "left"
        if button != "left" {
            // Real right and middle clicks open menus that hold the main thread; these are DOM events.
            let result = try await automation(tab, "contextMenu", .object(Self.targetParams(a).object!.merging(["button": .string(button)]) { a, _ in a }))
            return .text("Dispatched a \(button) click (DOM events, isTrusted false) on \(result["describe"]?.string ?? "the element").\n" + (await afterAction(tab, since: since, urlBefore: urlBefore)))
        }
        let (point, target) = try await aim(tab, a)
        var modifiers: NSEvent.ModifierFlags = []
        for name in a["modifiers"]?.array?.compactMap(\.string) ?? [] {
            switch name {
            case "Alt": modifiers.insert(.option)
            case "Control": modifiers.insert(.control)
            case "Meta": modifiers.insert(.command)
            case "Shift": modifiers.insert(.shift)
            default: break
            }
        }
        try AgentInput.click(at: point, in: tab.pageWebView, clickCount: a["doubleClick"]?.bool == true ? 2 : 1, modifiers: modifiers)
        let verb = a["doubleClick"]?.bool == true ? "Double-clicked" : "Clicked"
        return .text("\(verb) \(target["describe"]?.string ?? "the element").\n" + (await afterAction(tab, since: since, urlBefore: urlBefore)))
    }

    private func hover(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let (point, target) = try await aim(tab, a, allowCovered: true)
        try AgentInput.hover(at: point, in: tab.pageWebView)
        try await Task.sleep(for: .milliseconds(120))
        var text = "Hovering over \(target["describe"]?.string ?? "the element")."
        if let covered = target["covered"]?.string { text += " (\(covered) is on top of it and gets the hover.)" }
        return .text(text)
    }

    private func fill(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let since = recorder.events.last?.sequence ?? -1
        let urlBefore = tab.pageWebView.url
        var params = Self.targetParams(a).object!
        params["value"] = a["value"] ?? ""
        let result = try await automation(tab, "fill", .object(params))
        var text = "Filled \(result["describe"]?.string ?? "the field") with \(result["value"]?.jsonString ?? "\"\"")."
        if a["submit"]?.bool == true {
            try AgentInput.press("Enter", in: tab.pageWebView)
            text += " Pressed Enter."
            return .text(text + "\n" + (await afterAction(tab, since: since, urlBefore: urlBefore)))
        }
        return .text(text + problemsSuffix(tab, since: since))
    }

    private func fillForm(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let since = recorder.events.last?.sequence ?? -1
        let urlBefore = tab.pageWebView.url
        guard let fields = a["fields"]?.array, !fields.isEmpty else { throw ToolError("fields is empty") }
        var lines: [String] = []
        for (index, field) in fields.enumerated() {
            var params = Self.targetParams(field).object!
            params["value"] = field["value"] ?? ""
            do {
                let result = try await automation(tab, "fill", .object(params))
                lines.append("✓ \(result["describe"]?.string ?? "field \(index + 1)") = \(result["value"]?.jsonString ?? "\"\"")")
            } catch {
                lines.append("✗ field \(index + 1) (\(field["ref"]?.string ?? field["selector"]?.string ?? "?")): \(Self.message(for: error))")
            }
        }
        if a["submit"]?.bool == true {
            try AgentInput.press("Enter", in: tab.pageWebView)
            lines.append("Pressed Enter.")
            lines.append(await afterAction(tab, since: since, urlBefore: urlBefore))
        }
        return MCPToolResult([.text(lines.joined(separator: "\n"))], isError: lines.contains { $0.hasPrefix("✗") })
    }

    private func typeText(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let since = recorder.events.last?.sequence ?? -1
        let urlBefore = tab.pageWebView.url
        var into = "the focused element"
        if a["ref"] != nil || a["selector"] != nil {
            let (point, target) = try await aim(tab, a)
            try AgentInput.click(at: point, in: tab.pageWebView)
            into = target["describe"]?.string ?? into
            try await Task.sleep(for: .milliseconds(50))
        }
        if a["clear"]?.bool == true, try await automation(tab, "selectContents")["selected"]?.bool == true {
            try AgentInput.press("Backspace", in: tab.pageWebView)
        }
        let text = a["text"]?.string ?? ""
        try await AgentInput.type(text, in: tab.pageWebView)
        var summary = "Typed \(text.count) characters into \(into)."
        if a["submit"]?.bool == true {
            try AgentInput.press("Enter", in: tab.pageWebView)
            summary += " Pressed Enter."
        }
        return .text(summary + "\n" + (await afterAction(tab, since: since, urlBefore: urlBefore)))
    }

    private func pressKey(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let since = recorder.events.last?.sequence ?? -1
        let urlBefore = tab.pageWebView.url
        let key = a["key"]?.string ?? ""
        let repeatCount = min(max(a["repeat"]?.int ?? 1, 1), 100)
        for _ in 0..<repeatCount { try AgentInput.press(key, in: tab.pageWebView) }
        return .text("Pressed \(key)\(repeatCount > 1 ? " ×\(repeatCount)" : "").\n" + (await afterAction(tab, since: since, urlBefore: urlBefore)))
    }

    private func selectOption(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let since = recorder.events.last?.sequence ?? -1
        var params = Self.targetParams(a).object!
        params["values"] = a["values"] ?? []
        let result = try await automation(tab, "selectOption", .object(params))
        return .text("Selected \(result["value"]?.jsonString ?? "") in \(result["describe"]?.string ?? "the list")." + problemsSuffix(tab, since: since))
    }

    private func scroll(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        var params = Self.targetParams(a).object!
        if let direction = a["direction"] { params["direction"] = direction }
        if let amount = a["amount"] { params["amount"] = amount }
        guard params.count > 0 else { throw ToolError("Give a ref or selector to scroll to, or a direction") }
        let result = try await automation(tab, "scroll", .object(params))
        var text = "Scrolled \(result["describe"]?.string ?? "the page") to \(result["scrollX"]?.int ?? 0), \(result["scrollY"]?.int ?? 0)."
        if let height = result["scrollHeight"]?.int, let viewport = result["viewportHeight"]?.int {
            text += " Content height \(height) px, viewport \(viewport) px."
        }
        return .text(text)
    }

    private func drag(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        let since = recorder.events.last?.sequence ?? -1
        let urlBefore = tab.pageWebView.url
        let from: JSONValue = ["ref": a["fromRef"] ?? nil, "selector": a["fromSelector"] ?? nil]
        let to: JSONValue = ["ref": a["toRef"] ?? nil, "selector": a["toSelector"] ?? nil]
        let (start, source) = try await aim(tab, Self.targetParams(from), allowCovered: true)
        let (end, destination) = try await aim(tab, Self.targetParams(to), allowCovered: true)
        try await AgentInput.drag(from: start, to: end, in: tab.pageWebView)
        return .text("Dragged \(source["describe"]?.string ?? "") onto \(destination["describe"]?.string ?? ""). (Pointer-event drags work; HTML5 drag and drop needs a real drag session and may not.)\n"
                     + (await afterAction(tab, since: since, urlBefore: urlBefore)))
    }

    private func uploadFiles(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        var files: [JSONValue] = []
        for path in a["paths"]?.array?.compactMap(\.string) ?? [] {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { throw ToolError("Cannot read \(url.path)") }
            guard data.count <= 50_000_000 else { throw ToolError("\(url.lastPathComponent) is over 50 MB") }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType ?? "application/octet-stream"
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            files.append(["name": .string(url.lastPathComponent), "type": .string(type), "base64": .string(data.base64EncodedString()),
                          "lastModified": .number(modified.timeIntervalSince1970 * 1000)])
        }
        var params = Self.targetParams(a).object!
        params["files"] = .array(files)
        let result = try await automation(tab, "setFiles", .object(params))
        return .text("Set \(result["describe"]?.string ?? "the input") to \(result["files"]?.array?.compactMap(\.string).joined(separator: ", ") ?? "").")
    }

    private func handleDialog(_ a: JSONValue) throws -> MCPToolResult {
        let tab = try tab(a)
        guard let dialog = tab.pageDialog else { throw ToolError("No dialog is open in tab \(Self.shortID(tab)).") }
        let accept = a["accept"]?.bool ?? true
        let summary = "\(dialog.kind.rawValue)(\"\(dialog.message)\")"
        tab.answerDialog(accept: accept, text: a["promptText"]?.string)
        return .text("Answered \(summary) with \(accept ? "OK" : "Cancel")\(a["promptText"]?.string.map { " and \"\($0)\"" } ?? "").")
    }

    /// What happened because of an action: a navigation it started, new
    /// errors in the console, a dialog it opened.
    private func afterAction(_ tab: BrowserWindowController, since: Int, urlBefore: URL?) async -> String {
        try? await Task.sleep(for: .milliseconds(150))
        if tab.pageWebView.isLoading { try? await waitForLoad(tab, timeout: 10) }
        var lines: [String] = []
        if tab.pageWebView.url != urlBefore {
            lines.append("Navigated. " + navigationReport(tab, since: since))
        } else {
            lines.append(pageLine(tab))
            lines.append(contentsOf: problems(tab, since: since))
        }
        if let dialog = tab.pageDialog { lines.append(dialog.summary) }
        return lines.joined(separator: "\n")
    }

    private func problemsSuffix(_ tab: BrowserWindowController, since: Int) -> String {
        let found = problems(tab, since: since)
        return found.isEmpty ? "" : "\n" + found.joined(separator: "\n")
    }

    /// Errors and failed requests recorded after `since`, briefly.
    private func problems(_ tab: BrowserWindowController, since: Int) -> [String] {
        var errors: [String] = [], failures: [String] = []
        for recorded in recorder.events where recorded.tab == tab.tab && recorded.sequence > since {
            switch recorded.event {
            case .console(let entry) where entry.level == .error:
                errors.append("  #\(recorded.sequence) \(entry.isUncaught ? "Uncaught " : "")\(String(entry.message.prefix(300)))")
            case .network(let event) where event.isFailure && event.source != .navigationDelegate:
                failures.append("  \(event.method ?? "GET") \(event.statusCode.map(String.init) ?? event.failure ?? "failed") \(String(event.url.absoluteString.prefix(200)))")
            default: break
            }
        }
        var lines: [String] = []
        if !errors.isEmpty { lines.append("New console errors (\(errors.count)):"); lines.append(contentsOf: errors.suffix(5)) }
        if !failures.isEmpty { lines.append("Failed requests (\(failures.count)):"); lines.append(contentsOf: Array(Set(failures)).sorted().suffix(5)) }
        return lines
    }

    // MARK: - Debugging

    private func evaluate(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let expression = a["expression"]?.string ?? ""
        let isolated = a["world"]?.string == "isolated"
        let hasTarget = a["ref"] != nil || a["selector"] != nil

        let token = UUID().uuidString
        var prelude = "let __sbTarget = null;\n"
        if hasTarget {
            if isolated {
                _ = try await automation(tab, "describe", Self.targetParams(a))
                prelude = Self.automationSource + "\nlet __sbTarget = window.__sbAutomation.target(__sbParams);\n"
            } else {
                var params = Self.targetParams(a).object!
                params["token"] = .string(token)
                _ = try await automation(tab, "mark", .object(params))
                prelude = """
                const __sbFind = (root) => {
                  const hit = root.querySelector('[data-sb-agent-target="\(token)"]');
                  if (hit) return hit;
                  for (const el of root.querySelectorAll('*')) if (el.shadowRoot) { const inner = __sbFind(el.shadowRoot); if (inner) return inner; }
                  return null;
                };
                let __sbTarget = __sbFind(document);
                if (__sbTarget) __sbTarget.removeAttribute('data-sb-agent-target');

                """
            }
        }
        // A function (an arrow, a declaration) is called with the element.
        let asExpression = "await (async () => (\n\(expression)\n))()"
        let asStatements = "await (async () => {\n\(expression)\n})()"
        let worldToUse: WKContentWorld = isolated ? world : .page
        var arguments: [String: Any] = [:]
        if isolated { arguments["__sbParams"] = Self.targetParams(a).anyValue }
        func run(_ value: String) async throws -> MCPToolResult {
            let body = prelude + """
            let __sbValue;
            try {
              __sbValue = \(value);
              if (typeof __sbValue === "function") __sbValue = await __sbValue(__sbTarget);
            } catch (e) {
              return { __sbError: (e && e.name ? e.name + ": " : "") + String(e && e.message !== undefined ? e.message : e) + (e && e.stack ? "\\n" + e.stack : "") };
            }

            """ + Self.serializer
            let result = try await script(tab, body, arguments: arguments, world: worldToUse)
            if let failure = (result as? [String: Any])?["__sbError"] as? String { throw ToolError(failure) }
            var text = (result as? String) ?? "undefined"
            if text.count > 50_000 { text = String(text.prefix(50_000)) + "\n…(truncated at 50000 characters)" }
            return .text(text)
        }
        do {
            return try await run(asExpression)
        } catch let error as ToolError where error.message.contains("SyntaxError") {
            // Statements, not an expression: run them as a function body (use return for a value).
            return try await run(asStatements)
        }
    }

    /// Turns `__sbValue` into readable JSON: nodes, errors, maps, cycles and all.
    private static let serializer = """
    const __sbSeen = new WeakSet();
    const __sbJSON = JSON.stringify(__sbValue, (key, v) => {
      if (typeof v === "bigint") return v.toString() + "n";
      if (typeof v === "function") return "[Function " + (v.name || "anonymous") + "]";
      if (typeof v === "symbol") return v.toString();
      if (v === undefined) return key === "" ? undefined : "[undefined]";
      if (typeof Node !== "undefined" && v instanceof Node) {
        if (v.nodeType !== 1) return "[" + v.nodeName + "]";
        return "<" + v.localName + (v.id ? "#" + v.id : "") + (v.classList.length ? "." + [...v.classList].join(".") : "") + ">";
      }
      if (v instanceof Error) return { name: v.name, message: v.message, stack: v.stack };
      if (v instanceof Map) return Object.fromEntries(v);
      if (v instanceof Set) return [...v];
      if (v && typeof v === "object") { if (__sbSeen.has(v)) return "[Circular]"; __sbSeen.add(v); }
      return v;
    }, 2);
    return __sbJSON === undefined ? "undefined" : __sbJSON;
    """

    private static let consoleRank: [ConsoleEntry.Level: Int] = [.debug: 0, .trace: 1, .info: 1, .warn: 2, .error: 3]

    private func consoleMessages(_ a: JSONValue) throws -> MCPToolResult {
        let tab = try tab(a)
        let minimum = ["all": 0, "debug": 0, "info": 1, "warn": 2, "error": 3][a["level"]?.string ?? "all"] ?? 0
        let search = a["search"]?.string?.lowercased()
        let after = a["afterId"]?.int ?? -1
        let limit = min(max(a["limit"]?.int ?? 100, 1), 1000)
        var lines: [String] = []
        var count = 0
        for recorded in recorder.events where recorded.tab == tab.tab && recorded.sequence > after {
            switch recorded.event {
            case .navigation(let event) where event.phase == .committed:
                if search == nil { lines.append("── navigated to \(event.url.absoluteString) ──") }
            case .console(let entry):
                guard entry.type != "command", entry.type != "result" else { continue }
                guard (Self.consoleRank[entry.level] ?? 1) >= minimum else { continue }
                if let search, !entry.message.lowercased().contains(search) { continue }
                count += 1
                var line = "#\(recorded.sequence) [\(entry.level.rawValue)] \(InspectorEventFormatter.timestamp(entry.timestamp)) "
                line += (entry.isUncaught ? "Uncaught " : "") + String(entry.message.prefix(4000))
                if let table = entry.table {
                    line += "\n  " + table.columns.joined(separator: " | ")
                    for row in table.rows.prefix(20) { line += "\n  " + row.joined(separator: " | ") }
                }
                let wantStacks = a["includeStacks"]?.bool ?? (entry.level == .error)
                if wantStacks {
                    for frame in entry.stack.prefix(8) { line += "\n    at " + InspectorEventFormatter.describe(frame) }
                }
                lines.append(line)
            default: break
            }
        }
        // Newest kept, as the console scrolls.
        var shown = lines
        var dropped = 0
        while shown.filter({ $0.hasPrefix("#") }).count > limit { shown.removeFirst(); dropped += 1 }
        if shown.isEmpty { return .text("No console messages\(minimum > 0 ? " at that level" : "") in tab \(Self.shortID(tab)).") }
        let header = "\(count) message\(count == 1 ? "" : "s") in tab \(Self.shortID(tab))\(dropped > 0 ? " (oldest left out; raise limit or use afterId)" : ""):"
        return .text(([header] + shown).joined(separator: "\n"))
    }

    /// The tab's requests, merged across sources as the Network panel does.
    private func requestLog(_ tab: BrowserWindowController, sinceNavigation: Bool) -> [NetworkRequest] {
        let log = NetworkRequestLog()
        var navigationStart = Date.distantPast
        for recorded in recorder.events where recorded.tab == tab.tab {
            switch recorded.event {
            case .network(let event): log.ingest(event)
            case .navigation(let event) where event.phase == .started: navigationStart = event.timestamp.addingTimeInterval(-0.5)
            default: break
            }
        }
        return sinceNavigation ? log.requests.filter { $0.startedAt >= navigationStart } : log.requests
    }

    static func requestID(_ request: NetworkRequest) -> String { String(request.id.uuidString.prefix(8)).lowercased() }

    private func networkRequests(_ a: JSONValue) throws -> MCPToolResult {
        let tab = try tab(a)
        var requests = requestLog(tab, sinceNavigation: a["sinceNavigation"]?.bool ?? true)
        if let filter = a["filter"]?.string?.lowercased(), !filter.isEmpty {
            requests = requests.filter { $0.url.absoluteString.lowercased().contains(filter) }
        }
        if let type = a["type"]?.string, type != "all" {
            requests = requests.filter { request in
                switch type {
                case "fetch": return request.resourceType == "fetch" || request.resourceType == "xhr"
                case "other": return !["document", "fetch", "xhr", "script", "stylesheet", "image", "font", "media", "websocket"].contains(request.resourceType)
                default: return request.resourceType == type
                }
            }
        }
        if a["failedOnly"]?.bool == true { requests = requests.filter(\.isFailure) }
        let limit = min(max(a["limit"]?.int ?? 200, 1), 2000)
        let total = requests.count
        requests = Array(requests.suffix(limit))
        guard !requests.isEmpty else { return .text("No matching requests in tab \(Self.shortID(tab)).") }
        var lines = ["\(total) request\(total == 1 ? "" : "s")\(total > limit ? ", newest \(limit) shown" : "") — id method status type size time url:"]
        for request in requests {
            let status = request.failure.map { "failed(\($0))" } ?? request.statusCode.map(String.init) ?? "pending"
            let size = (request.transferSize ?? request.bodySize).map { InspectorEventFormatter.byteCount($0) } ?? "–"
            let time = request.duration.map { InspectorEventFormatter.milliseconds($0) } ?? "–"
            lines.append("\(Self.requestID(request)) \(request.method ?? "GET") \(status) \(request.resourceType) \(size) \(time) \(request.url.absoluteString.prefix(300))")
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func networkRequest(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        let id = (a["id"]?.string ?? "").lowercased()
        guard let request = requestLog(tab, sinceNavigation: false).last(where: { Self.requestID($0).hasPrefix(id) }) else {
            throw ToolError("No request \(id) in tab \(Self.shortID(tab)). Ids come from network_requests.")
        }
        var lines = ["\(request.method ?? "GET") \(request.url.absoluteString)"]
        lines.append("Status: \(request.failure.map { "failed — \($0)" } ?? request.statusCode.map(String.init) ?? "pending")")
        lines.append("Type: \(request.resourceType)\(request.mimeType.map { " (\($0))" } ?? "")\(request.protocolName.map { " · \($0)" } ?? "")")
        if let duration = request.duration { lines.append("Time: \(InspectorEventFormatter.milliseconds(duration))") }
        if let size = request.transferSize { lines.append("Transferred: \(InspectorEventFormatter.byteCount(size))") }
        if let timing = request.timing {
            lines.append(String(format: "Timing (ms): dns %.0f, connect %.0f, tls %.0f, waiting %.0f, download %.0f",
                                timing.domainLookupEnd - timing.domainLookupStart, timing.connectEnd - timing.connectStart,
                                timing.secureConnectionStart > 0 ? timing.connectEnd - timing.secureConnectionStart : 0,
                                timing.responseStart - timing.requestStart, timing.responseEnd - timing.responseStart))
        }
        lines.append("\nRequest headers:")
        lines.append(contentsOf: request.requestHeaders.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" })
        if request.requestHeaders.isEmpty { lines.append("  (not observed for this request)") }
        lines.append("\nResponse headers:")
        lines.append(contentsOf: request.responseHeaders.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" })
        if request.responseHeaders.isEmpty { lines.append("  (not observed for this request)") }
        let max = a["maxBodyLength"]?.int ?? 20000
        if let body = request.requestBody, !body.isEmpty {
            lines.append("\nRequest body:\n" + String(body.prefix(max)))
        }
        if a["includeBody"]?.bool ?? true {
            var body = request.responseBody
            if body == nil, let protocolID = request.protocolRequestID, tab.protocolBridge.isAttached {
                if let result = try? await tab.protocolBridge.send("Network.getResponseBody", ["requestId": protocolID]) {
                    let raw = result["body"] as? String
                    body = (result["base64Encoded"] as? Bool) == true ? raw.map { "(base64) " + $0 } : raw
                }
            }
            if let body {
                lines.append("\nResponse body\(body.count > max ? " (first \(max) of \(body.count) characters)" : ""):\n" + String(body.prefix(max)))
            } else {
                lines.append("\nResponse body: not captured. Bodies of fetch and XHR are always kept; for other resources open DevTools (devtools tool) and reload, and every body is kept.")
            }
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func inspectElement(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        var params = Self.targetParams(a).object!
        if let properties = a["properties"] { params["properties"] = properties }
        if let includeRules = a["includeRules"] { params["includeRules"] = includeRules }
        let result = try await automation(tab, "inspect", .object(params))
        var lines = [result["describe"]?.string ?? "", "Selector: \(result["selector"]?.string ?? "")"]
        let attributes = result["attributes"]?.object ?? [:]
        if !attributes.isEmpty {
            lines.append("Attributes: " + attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.jsonString)" }.joined(separator: " "))
        }
        if let box = result["boxModel"] {
            let rect = box["rect"]
            func sides(_ name: String) -> String {
                let s = box[name]
                return [s?["top"], s?["right"], s?["bottom"], s?["left"]].map { $0?.double.map { String(format: "%g", $0) } ?? "0" }.joined(separator: " ")
            }
            lines.append(String(format: "Box: x %.0f y %.0f, %.0f×%.0f (viewport CSS px) · margin %@ · border %@ · padding %@",
                                rect?["x"]?.double ?? 0, rect?["y"]?.double ?? 0, rect?["width"]?.double ?? 0, rect?["height"]?.double ?? 0,
                                sides("margin"), sides("border"), sides("padding")))
        }
        if let accessibility = result["accessibility"] {
            lines.append("Accessibility: role \(accessibility["role"]?.string ?? "none"), name \(accessibility["name"]?.jsonString ?? "\"\""), \(accessibility["states"]?.array?.compactMap(\.string).joined(separator: ", ") ?? "")")
        }
        lines.append("\nComputed styles:")
        for (name, value) in (result["computed"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) { lines.append("  \(name): \(value.string ?? "")") }
        if let inline = result["inlineStyle"]?.string, !inline.isEmpty { lines.append("\nInline style: \(inline)") }
        if let rules = result["matchedRules"]?.array, !rules.isEmpty {
            lines.append("\nMatched CSS rules, highest priority first:")
            for rule in rules {
                let conditions = rule["conditions"]?.string.flatMap { $0.isEmpty ? nil : " @ \($0)" } ?? ""
                lines.append("  \(rule["selector"]?.string ?? "")  — \(rule["source"]?.string ?? "")\(conditions)")
                for declaration in rule["declarations"]?.array?.compactMap(\.string) ?? [] { lines.append("      \(declaration);") }
            }
        }
        if let count = result["crossOriginStyleSheets"]?.int { lines.append("(\(count) cross-origin stylesheet\(count == 1 ? "" : "s") could not be read.)") }
        if let error = result["matchedRulesError"]?.string { lines.append("(Matched rules unavailable: \(error))") }
        if let text = result["text"]?.string, !text.isEmpty { lines.append("\nText: \(text)") }
        return .text(lines.joined(separator: "\n"))
    }

    private func performanceMetrics(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let metrics = try await automation(tab, "metrics")
        var lines = ["Performance of \(metrics["url"]?.string ?? "")"]
        // Entries the recorder collected from document start, for the current document only.
        var entries: [PerformanceEntry] = []
        for recorded in recorder.events where recorded.tab == tab.tab {
            switch recorded.event {
            case .navigation(let event) where event.phase == .committed: entries = []
            case .performance(let entry): entries.append(entry)
            default: break
            }
        }
        let longTasks = entries.filter { $0.entryType == "longtask" }
        let shifts = entries.filter { $0.entryType == "layout-shift" && !($0.detail ?? "").contains("had recent input") }
        let interactions = entries.filter { $0.entryType == "first-input" || $0.entryType == "event" }
        let fcp = entries.first { $0.entryType == "paint" && $0.name == "first-contentful-paint" }?.startTime
        let lcpEntry = entries.last { $0.entryType == "largest-contentful-paint" }
        let vitals: [(String, Double?, Double, Double, String?)] = [
            ("LCP", lcpEntry?.startTime, 2500, 4000, lcpEntry?.detail ?? (lcpEntry == nil ? "WebKit may not report it for this page" : nil)),
            ("CLS", shifts.isEmpty ? (fcp == nil ? nil : 0) : shifts.reduce(0) { $0 + ($1.value ?? 0) }, 0.1, 0.25, shifts.isEmpty ? nil : "\(shifts.count) shift\(shifts.count == 1 ? "" : "s")"),
            ("INP", interactions.map(\.duration).max(), 200, 500, interactions.isEmpty ? "no slow interaction yet" : "\(interactions.count) slow interaction\(interactions.count == 1 ? "" : "s")"),
            ("FCP", fcp, 1800, 3000, nil),
            ("TTFB", metrics["navigation"]?["ttfb"]?.double, 800, 1800, nil),
        ]
        lines.append("\nCore Web Vitals (rated by web.dev thresholds):")
        for (name, value, good, poor, note) in vitals {
            guard let value else { lines.append("  \(name): not measured\(note.map { " — \($0)" } ?? "")"); continue }
            let rating = value <= good ? "good" : value <= poor ? "needs improvement" : "poor"
            let shown = name == "CLS" ? String(format: "%.3f", value) : "\(Int(value)) ms"
            lines.append("  \(name): \(shown) — \(rating)\(note.map { " · \($0)" } ?? "")")
        }
        if !longTasks.isEmpty {
            let total = longTasks.reduce(0) { $0 + $1.duration }
            lines.append("Long tasks: \(longTasks.count), \(Int(total)) ms total, longest \(Int(longTasks.map(\.duration).max() ?? 0)) ms")
        }
        if let navigation = metrics["navigation"], !navigation.isNull {
            lines.append("\nNavigation: TTFB \(navigation["ttfb"]?.int ?? 0) ms · DOM interactive \(navigation["domInteractive"]?.int ?? 0) ms · DOMContentLoaded \(navigation["domContentLoaded"]?.int ?? 0) ms · load \(navigation["load"]?.int ?? 0) ms · \(navigation["protocol"]?.string ?? "") · \(navigation["type"]?.string ?? "")")
        }
        if let resources = metrics["resources"] {
            lines.append("Resources: \(resources["count"]?.int ?? 0), \(InspectorEventFormatter.byteCount(Int64(resources["transferBytes"]?.double ?? 0))) transferred, \(InspectorEventFormatter.byteCount(Int64(resources["decodedBytes"]?.double ?? 0))) decoded")
            for (type, info) in (resources["byType"]?.object ?? [:]).sorted(by: { ($0.value["transferBytes"]?.double ?? 0) > ($1.value["transferBytes"]?.double ?? 0) }) {
                lines.append("  \(type): \(info["count"]?.int ?? 0), \(InspectorEventFormatter.byteCount(Int64(info["transferBytes"]?.double ?? 0)))")
            }
            if let blocking = resources["renderBlocking"]?.array, !blocking.isEmpty {
                lines.append("Render-blocking: " + blocking.compactMap(\.string).joined(separator: ", "))
            }
            if let slowest = resources["slowest"]?.array, !slowest.isEmpty {
                lines.append("Slowest:")
                for item in slowest { lines.append("  \(item["ms"]?.int ?? 0) ms \(item["type"]?.string ?? "") \(item["url"]?.string?.prefix(160) ?? "")") }
            }
        }
        if let dom = metrics["dom"] { lines.append("DOM: \(dom["elements"]?.int ?? 0) elements, depth \(dom["maxDepth"]?.int ?? 0)") }
        if let memory = metrics["memory"], !memory.isNull {
            lines.append("JS heap: \(InspectorEventFormatter.byteCount(Int64(memory["usedJSHeapSize"]?.double ?? 0))) used")
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func storage(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab, show: false)
        let area = a["area"]?.string ?? "local"
        let action = a["action"]?.string ?? "get"
        let key = a["key"]?.string
        if area == "cookies" {
            guard let url = tab.pageWebView.url, let host = url.host else { throw ToolError("The tab has no page") }
            let store = tab.pageWebView.configuration.websiteDataStore.httpCookieStore
            let all = await store.allCookies().filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            switch action {
            case "get":
                let shown = all.filter { key == nil || $0.name == key }
                if shown.isEmpty { return .text("No cookies for \(host)\(key.map { " named \($0)" } ?? "").") }
                return .text(shown.map { cookie in
                    var flags = [cookie.domain, cookie.path]
                    if cookie.isHTTPOnly { flags.append("HttpOnly") }
                    if cookie.isSecure { flags.append("Secure") }
                    if let policy = cookie.sameSitePolicy { flags.append("SameSite=\(policy.rawValue)") }
                    flags.append(cookie.expiresDate.map { "expires \(ISO8601DateFormatter().string(from: $0))" } ?? "session")
                    return "\(cookie.name)=\(cookie.value.prefix(500))  (\(flags.joined(separator: "; ")))"
                }.joined(separator: "\n"))
            case "set":
                guard let key else { throw ToolError("set needs a key (the cookie name)") }
                guard let cookie = HTTPCookie(properties: [.name: key, .value: a["value"]?.string ?? "", .domain: host, .path: "/",
                                                           .secure: url.scheme == "https" ? "TRUE" : "FALSE"]) else { throw ToolError("Invalid cookie") }
                await store.setCookie(cookie)
                return .text("Set cookie \(key) for \(host).")
            case "delete":
                guard let key else { throw ToolError("delete needs a key (the cookie name)") }
                let matching = all.filter { $0.name == key }
                for cookie in matching { await store.deleteCookie(cookie) }
                return .text("Deleted \(matching.count) cookie\(matching.count == 1 ? "" : "s") named \(key).")
            default:
                for cookie in all { await store.deleteCookie(cookie) }
                return .text("Deleted \(all.count) cookies for \(host).")
            }
        }
        let storageArea: JSONValue = .string(area == "session" ? "session" : "local")
        let method: String
        var params: [String: JSONValue] = ["area": storageArea]
        switch action {
        case "set":
            guard let key else { throw ToolError("set needs a key") }
            method = "Storage.setEntry"; params["key"] = .string(key); params["value"] = a["value"] ?? ""
        case "delete":
            guard let key else { throw ToolError("delete needs a key") }
            method = "Storage.removeEntry"; params["key"] = .string(key)
        case "clear": method = "Storage.clear"
        default: method = "Storage.getEntries"
        }
        let body = "return window.__sbAgent.handle(method, params);"
        let raw = try await script(tab, body, arguments: ["method": method, "params": JSONValue.object(params).anyValue], world: world)
        let result = JSONValue(any: raw)
        if method != "Storage.getEntries" { return .text("\(action.capitalized) done in \(area)Storage.") }
        var entries: [(String, String)] = []
        if let array = result.array {
            for item in array {
                if let pair = item.array, pair.count == 2 { entries.append((pair[0].string ?? "", pair[1].string ?? "")) }
                else if let k = item["key"]?.string { entries.append((k, item["value"]?.string ?? "")) }
            }
        } else if let object = result.object {
            entries = object.map { ($0.key, $0.value.string ?? $0.value.jsonString) }
        }
        if let key { entries = entries.filter { $0.0 == key } }
        if entries.isEmpty { return .text("\(area)Storage is empty\(key.map { " for \($0)" } ?? "").") }
        return .text(entries.sorted { $0.0 < $1.0 }.map { "\($0.0) = \($0.1.prefix(2000))" }.joined(separator: "\n"))
    }

    private static let devices: [String: (Int, Int, String)] = {
        let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let iPad = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let android = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36"
        return ["iPhone 15 Pro": (393, 852, iPhone), "iPhone SE": (375, 667, iPhone), "Pixel 8": (412, 915, android),
                "Galaxy S23": (360, 780, android), "iPad Air": (820, 1180, iPad), "iPad Pro 12.9": (1024, 1366, iPad)]
    }()

    private func emulate(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        if a["reset"]?.bool == true {
            tab.setDeviceEmulation(nil)
            return .text("Device emulation off.")
        }
        var device: [String: Any]
        if let name = a["device"]?.string {
            guard let preset = Self.devices[name] else { throw ToolError("Unknown device \(name)") }
            device = ["name": name, "width": preset.0, "height": preset.1, "userAgent": preset.2]
        } else if let width = a["width"]?.int, let height = a["height"]?.int {
            device = ["name": "Custom", "width": width, "height": height, "userAgent": a["userAgent"]?.string ?? ""]
        } else {
            throw ToolError("Give a device, or width and height, or reset")
        }
        if let agent = a["userAgent"]?.string { device["userAgent"] = agent }
        tab.setDeviceEmulation(device)
        try await waitForLoad(tab, timeout: 15)
        let bounds = tab.pageWebView.bounds.size
        var text = "Emulating \(device["name"] as? String ?? "a device"): \(device["width"]!)×\(device["height"]!)."
        if Int(bounds.width) < (device["width"] as? Int ?? 0) || Int(bounds.height) < (device["height"] as? Int ?? 0) {
            text += " The window is smaller, so the viewport is \(Int(bounds.width))×\(Int(bounds.height))."
        }
        return .text(text + "\n" + pageLine(tab))
    }

    private func devtools(_ a: JSONValue) async throws -> MCPToolResult {
        let tab = try tab(a)
        try await ready(tab)
        if a["action"]?.string == "close" {
            if tab.isDevToolsVisible { tab.toggleDevTools(nil) }
            return .text("DevTools closed.")
        }
        let hasTarget = a["ref"] != nil || a["selector"] != nil
        let panel = a["panel"]?.string ?? (hasTarget ? "elements" : nil)
        let fresh = tab.devTools == nil
        tab.showDevTools(panel: panel)
        guard hasTarget else { return .text("DevTools open\(panel.map { " on \($0)" } ?? "").") }
        let node = try await automation(tab, "nodeId", Self.targetParams(a))
        guard let nodeId = node["nodeId"]?.int else { throw ToolError("DevTools cannot see that element") }
        if fresh, let tools = tab.devTools {
            // The UI has to load before it can take the selection.
            try await waitUntil(timeout: 10) { !tools.view.isLoading }
            try await Task.sleep(for: .milliseconds(800))
        }
        tab.devTools?.handleAuxiliary(kind: "inspect", body: ["nodeId": nodeId])
        return .text("DevTools open on Elements with \(node["describe"]?.string ?? "the element") selected.")
    }
}

/// Opens once: the first of several racing outcomes wins.
@MainActor
private final class Gate {
    private(set) var isClosed = false
    func open() -> Bool {
        if isClosed { return false }
        isClosed = true
        return true
    }
}

/// Carries a non-`Sendable` value across a continuation that never leaves the main actor.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
