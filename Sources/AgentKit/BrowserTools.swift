import Foundation

/// The browser's MCP tools: names, descriptions and argument schemas. The app
/// implements them; keeping the catalog here lets it be checked without one.
public enum BrowserTools {

    public static let instructions = """
    SimpleBrowser is a real desktop browser (WebKit) the person is also using. You drive its tabs.

    Workflow:
    1. `snapshot` the page: an accessibility tree where every element you can act on has a ref like [ref=e12].
    2. Act by ref: `click`, `fill`, `type_text`, `press_key`, `select_option`, `hover`, `upload_files`.
       Refs stay valid for the same element across snapshots until the page navigates.
    3. Check the outcome: action results report navigation, new console errors and open dialogs.
       Take another `snapshot` (or `wait_for`) after anything that changes the page.

    Debugging: `console_messages`, `network_requests` / `network_request` (full headers and bodies),
    `evaluate` (JavaScript in the page), `inspect_element` (box model, computed styles, matched CSS rules),
    `performance_metrics` (Core Web Vitals), `screenshot`, `get_page_content` (Markdown of the page).
    Console and network are recorded from the moment a tab opens, so nothing is missed before you ask.
    `devtools` opens the browser's DevTools for the person, e.g. on the element you are talking about.

    Every tool takes an optional `tabId`; without it, tools act on the tab you last opened or selected,
    else on the tab in front. Clicks and key presses are real input events (isTrusted), not synthetic DOM events.
    """

    // MARK: - Shared arguments

    static let tabId: JSONValue = ["type": "string", "description": "Tab id from list_tabs. Defaults to the tab you last opened or selected, else the frontmost tab."]
    static let ref: JSONValue = ["type": "string", "description": "Element ref from the latest snapshot, e.g. \"e12\"."]
    static let selector: JSONValue = ["type": "string", "description": "CSS selector, when you have no ref. The first match is used."]
    static let element: JSONValue = ["type": "string", "description": "Optional human-readable description of the element, echoed back in the result for the record."]

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var all = properties
        if all["tabId"] == nil { all["tabId"] = tabId }
        return ["type": "object", "properties": .object(all), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }

    static func targeting(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        extra.merging(["ref": ref, "selector": selector, "element": element]) { mine, _ in mine }
    }

    // MARK: - The catalog

    public static let all: [MCPTool] = [
        // Tabs
        MCPTool(name: "list_tabs", title: "List tabs",
                description: "Lists open tabs across all windows: id, title, URL, whether it is loading, and which tab tools act on by default.",
                inputSchema: schema([:]), readOnly: true),
        MCPTool(name: "new_tab", title: "Open a tab",
                description: "Opens a new tab, optionally at a URL, and makes it the tab later tools act on. Waits for the page to load.",
                inputSchema: schema([
                    "url": ["type": "string", "description": "URL, host (example.com) or search words. Omit for an empty tab."],
                    "background": ["type": "boolean", "description": "Open without bringing it to the front. Default false."],
                ])),
        MCPTool(name: "select_tab", title: "Select a tab",
                description: "Makes a tab the one later tools act on, and by default brings it to the front.",
                inputSchema: schema(["bringToFront": ["type": "boolean", "description": "Default true."]], required: ["tabId"])),
        MCPTool(name: "close_tab", title: "Close a tab",
                description: "Closes a tab. The person can reopen it with ⇧⌘T.", inputSchema: schema([:], required: ["tabId"]), destructive: true),

        // Navigation
        MCPTool(name: "navigate", title: "Navigate",
                description: "Loads a URL in the tab, or goes back, forward or reloads. Waits for the load to finish (up to timeoutMs) and reports the final URL, title and HTTP status.",
                inputSchema: schema([
                    "url": ["type": "string", "description": "URL, host or search words. Required when action is \"goto\"."],
                    "action": ["type": "string", "enum": ["goto", "back", "forward", "reload", "reload_bypassing_cache", "stop"], "description": "Default \"goto\"."],
                    "waitUntil": ["type": "string", "enum": ["load", "commit", "none"], "description": "Default \"load\"."],
                    "timeoutMs": ["type": "integer", "description": "Default 30000."],
                ])),
        MCPTool(name: "wait_for", title: "Wait for",
                description: "Waits until text appears or disappears, a selector matches (or stops matching), the network goes idle, or a fixed time passes. Give one condition.",
                inputSchema: schema([
                    "text": ["type": "string", "description": "Wait until this text is visible on the page."],
                    "textGone": ["type": "string", "description": "Wait until this text is no longer visible."],
                    "selector": ["type": "string", "description": "Wait until a visible element matches this CSS selector."],
                    "selectorGone": ["type": "string", "description": "Wait until nothing visible matches this CSS selector."],
                    "networkIdle": ["type": "boolean", "description": "Wait until no request has been in flight for 500 ms."],
                    "timeMs": ["type": "integer", "description": "Just wait this long."],
                    "timeoutMs": ["type": "integer", "description": "Give up after this long. Default 10000."],
                ]), readOnly: true),

        // Reading the page
        MCPTool(name: "snapshot", title: "Accessibility snapshot",
                description: "The page as an accessibility tree (roles, names, states, values), with a ref on every element you can act on. Far cheaper and more reliable than a screenshot for deciding what to do. Includes open shadow roots and same-origin iframes.",
                inputSchema: schema([
                    "selector": ["type": "string", "description": "Only the subtree under the first element matching this CSS selector."],
                    "ref": ["type": "string", "description": "Only the subtree under this ref."],
                    "interactiveOnly": ["type": "boolean", "description": "Only elements you can act on, plus headings for orientation. Default false."],
                    "maxLength": ["type": "integer", "description": "Truncate the snapshot past this many characters. Default 60000."],
                ]), readOnly: true),
        MCPTool(name: "get_page_content", title: "Page content",
                description: "The page (or one element) as Markdown, plain text or HTML. Markdown keeps headings, links, lists, tables and code blocks.",
                inputSchema: schema(targeting([
                    "format": ["type": "string", "enum": ["markdown", "text", "html"], "description": "Default \"markdown\"."],
                    "maxLength": ["type": "integer", "description": "Default 100000 characters."],
                ])), readOnly: true),
        MCPTool(name: "screenshot", title: "Screenshot",
                description: "A screenshot of the visible page, the full page, or one element. Returned as an image; optionally also saved to a file.",
                inputSchema: schema(targeting([
                    "fullPage": ["type": "boolean", "description": "The whole scrollable page, not just the viewport. Default false."],
                    "format": ["type": "string", "enum": ["png", "jpeg"], "description": "Default \"png\"; \"jpeg\" is much smaller."],
                    "quality": ["type": "integer", "description": "JPEG quality 1–100. Default 80."],
                    "savePath": ["type": "string", "description": "Also write the image to this absolute path."],
                ])), readOnly: true),

        // Acting
        MCPTool(name: "click", title: "Click",
                description: "Clicks an element with a real mouse event at its centre, after scrolling it into view. Reports if something else covers it. Waits briefly for any navigation it starts.",
                inputSchema: schema(targeting([
                    "button": ["type": "string", "enum": ["left", "right", "middle"], "description": "Default \"left\"."],
                    "doubleClick": ["type": "boolean", "description": "Default false."],
                    "modifiers": ["type": "array", "items": ["type": "string", "enum": ["Alt", "Control", "Meta", "Shift"]], "description": "Keys held during the click."],
                ]))),
        MCPTool(name: "hover", title: "Hover",
                description: "Moves the mouse over an element (fires mouseover/mouseenter and :hover styles).",
                inputSchema: schema(targeting())),
        MCPTool(name: "fill", title: "Fill a field",
                description: "Replaces the value of an input, textarea, select or contenteditable element, firing input and change events the way frameworks (React, Vue) expect. Use type_text instead when the page reacts to individual key presses.",
                inputSchema: schema(targeting([
                    "value": ["type": "string", "description": "The new value. For checkboxes and radios: \"true\" or \"false\"."],
                    "submit": ["type": "boolean", "description": "Press Enter afterwards. Default false."],
                ]), required: ["value"])),
        MCPTool(name: "fill_form", title: "Fill a form",
                description: "Fills several fields at once. Each field is {ref or selector, value}.",
                inputSchema: schema([
                    "fields": ["type": "array", "description": "Fields to fill, in order.",
                               "items": ["type": "object", "properties": ["ref": ref, "selector": selector, "value": ["type": "string"]], "required": ["value"]]],
                    "submit": ["type": "boolean", "description": "Press Enter in the last field afterwards. Default false."],
                ], required: ["fields"])),
        MCPTool(name: "type_text", title: "Type text",
                description: "Types text as real key presses into the focused element, or into the element given (which is clicked first to focus it).",
                inputSchema: schema(targeting([
                    "text": ["type": "string", "description": "Text to type."],
                    "submit": ["type": "boolean", "description": "Press Enter afterwards. Default false."],
                    "clear": ["type": "boolean", "description": "Select and delete the existing content first. Default false."],
                ]), required: ["text"])),
        MCPTool(name: "press_key", title: "Press a key",
                description: "Presses a key or chord in the page, e.g. \"Enter\", \"Escape\", \"Tab\", \"ArrowDown\", \"Backspace\", \"Meta+A\", \"Shift+Tab\", \"Control+Enter\".",
                inputSchema: schema([
                    "key": ["type": "string", "description": "Key name (KeyboardEvent.key) or a single character, optionally with modifiers joined by +."],
                    "repeat": ["type": "integer", "description": "Press it this many times. Default 1."],
                ], required: ["key"])),
        MCPTool(name: "select_option", title: "Select options",
                description: "Selects options in a <select> by value or visible label.",
                inputSchema: schema(targeting([
                    "values": ["type": "array", "items": ["type": "string"], "description": "Option values or labels. Several for a multiple select."],
                ]), required: ["values"])),
        MCPTool(name: "scroll", title: "Scroll",
                description: "Scrolls an element into view, or scrolls the page (or a scrollable element) by an amount or to an edge.",
                inputSchema: schema(targeting([
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"], "description": "Scroll this way instead of to the element."],
                    "amount": ["type": "integer", "description": "Pixels for up/down/left/right. Default: 80% of the viewport."],
                ]))),
        MCPTool(name: "drag", title: "Drag and drop",
                description: "Drags one element onto another with real mouse events.",
                inputSchema: schema([
                    "fromRef": ref, "fromSelector": selector, "toRef": ref, "toSelector": selector,
                ])),
        MCPTool(name: "upload_files", title: "Upload files",
                description: "Sets the files of an <input type=file> from absolute paths on this Mac and fires change.",
                inputSchema: schema(targeting([
                    "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths."],
                ]), required: ["paths"])),
        MCPTool(name: "handle_dialog", title: "Answer a dialog",
                description: "Answers the alert, confirm or prompt the page has open (action results say when one is). Also answers a beforeunload prompt.",
                inputSchema: schema([
                    "accept": ["type": "boolean", "description": "OK (true) or Cancel (false)."],
                    "promptText": ["type": "string", "description": "Text to enter into a prompt() before accepting."],
                ], required: ["accept"])),

        // Debugging
        MCPTool(name: "evaluate", title: "Evaluate JavaScript",
                description: "Runs JavaScript in the page and returns the result as JSON. Give an expression (\"document.title\", top-level await allowed) or a function (\"(el) => el.getBoundingClientRect()\"), which receives the element when a ref or selector is given.",
                inputSchema: schema(targeting([
                    "expression": ["type": "string", "description": "An expression or a function source."],
                    "world": ["type": "string", "enum": ["page", "isolated"], "description": "\"page\" (default) sees the page's own globals; \"isolated\" cannot be interfered with by page script."],
                ]), required: ["expression"])),
        MCPTool(name: "console_messages", title: "Console messages",
                description: "Console output and uncaught errors (with stacks) recorded since the tab opened, newest last. Pass afterId to get only what is new.",
                inputSchema: schema([
                    "level": ["type": "string", "enum": ["all", "error", "warn", "info", "debug"], "description": "Minimum level. Default \"all\"."],
                    "search": ["type": "string", "description": "Only messages containing this text."],
                    "afterId": ["type": "integer", "description": "Only messages after this id (ids are in each line)."],
                    "limit": ["type": "integer", "description": "Default 100, newest kept."],
                    "includeStacks": ["type": "boolean", "description": "Default true for errors."],
                ]), readOnly: true),
        MCPTool(name: "network_requests", title: "Network requests",
                description: "Requests the tab made since it opened: id, method, status, type, size, time, URL. Use network_request for headers and bodies.",
                inputSchema: schema([
                    "filter": ["type": "string", "description": "Only URLs containing this text."],
                    "type": ["type": "string", "enum": ["all", "document", "fetch", "script", "stylesheet", "image", "font", "media", "websocket", "other"], "description": "Default \"all\"."],
                    "failedOnly": ["type": "boolean", "description": "Only failures and HTTP status ≥ 400."],
                    "sinceNavigation": ["type": "boolean", "description": "Only requests since the current page started loading. Default true."],
                    "limit": ["type": "integer", "description": "Default 200, newest kept."],
                ]), readOnly: true),
        MCPTool(name: "network_request", title: "Network request detail",
                description: "One request in full: request and response headers, request body, response body, timing phases.",
                inputSchema: schema([
                    "id": ["type": "string", "description": "Request id from network_requests."],
                    "includeBody": ["type": "boolean", "description": "Default true."],
                    "maxBodyLength": ["type": "integer", "description": "Default 20000 characters."],
                ], required: ["id"]), readOnly: true),
        MCPTool(name: "inspect_element", title: "Inspect element",
                description: "What DevTools' Elements panel shows for one element: tag, attributes, box model, computed styles, and the CSS rules that match it with their source, in cascade order.",
                inputSchema: schema(targeting([
                    "properties": ["type": "array", "items": ["type": "string"], "description": "Computed style properties to report. Default: a layout and typography set."],
                    "includeRules": ["type": "boolean", "description": "Include matched CSS rules. Default true."],
                ])), readOnly: true),
        MCPTool(name: "performance_metrics", title: "Performance metrics",
                description: "Core Web Vitals (LCP, CLS, INP, FCP, TTFB), long tasks, navigation timing, resource counts and sizes, and the JS heap, for the current page.",
                inputSchema: schema([:]), readOnly: true),
        MCPTool(name: "storage", title: "Cookies and storage",
                description: "Reads or changes cookies (including HttpOnly) and localStorage / sessionStorage for the current page.",
                inputSchema: schema([
                    "area": ["type": "string", "enum": ["cookies", "local", "session"]],
                    "action": ["type": "string", "enum": ["get", "set", "delete", "clear"], "description": "Default \"get\"."],
                    "key": ["type": "string", "description": "Cookie name or storage key."],
                    "value": ["type": "string", "description": "For set."],
                ], required: ["area"])),
        MCPTool(name: "emulate", title: "Emulate a device",
                description: "Gives the page a device's viewport and user agent (DevTools device mode), or a custom size; reset restores the window. Media queries respond.",
                inputSchema: schema([
                    "device": ["type": "string", "enum": ["iPhone 15 Pro", "iPhone SE", "Pixel 8", "Galaxy S23", "iPad Air", "iPad Pro 12.9"], "description": "A preset."],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "userAgent": ["type": "string"],
                    "reset": ["type": "boolean", "description": "Turn emulation off."],
                ])),
        MCPTool(name: "devtools", title: "Show DevTools",
                description: "Opens or closes the browser's DevTools for the person watching, on a panel, or on the Elements panel with an element selected (by ref or selector).",
                inputSchema: schema(targeting([
                    "action": ["type": "string", "enum": ["open", "close"], "description": "Default \"open\"."],
                    "panel": ["type": "string", "enum": ["elements", "console", "sources", "network", "performance", "application"]],
                ]))),
    ]

    public static func tool(named name: String) -> MCPTool? { all.first { $0.name == name } }
}
