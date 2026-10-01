import AppKit
import WebKit

/// Mouse and keyboard input for agents, built the way the window server
/// builds it and delivered to the web view, so the page sees trusted events
/// with real coordinates, buttons, click counts and modifier keys.
@MainActor
enum AgentInput {

    enum InputError: LocalizedError {
        case noWindow
        case unknownKey(String)

        var errorDescription: String? {
            switch self {
            case .noWindow: return "The tab has no window to send input to"
            case .unknownKey(let key): return "Unknown key \"\(key)\". Use KeyboardEvent.key names like Enter, Tab, ArrowDown, or a single character."
            }
        }
    }

    // MARK: - Mouse

    /// A point in the page's viewport (CSS pixels) as a point in the window.
    static func windowPoint(_ point: CGPoint, in webView: WKWebView) -> NSPoint {
        let scale = webView.pageZoom * webView.magnification
        var local = NSPoint(x: point.x * scale, y: point.y * scale)
        if !webView.isFlipped { local.y = webView.bounds.height - local.y }
        return webView.convert(local, to: nil)
    }

    /// Pages only take input while their view is focused: first responder
    /// in the key window. Agents drive a browser that is usually behind the
    /// terminal, so the tab's window becomes key in the app without the app
    /// coming forward.
    static func focus(_ webView: WKWebView) throws {
        guard let window = webView.window else { throw InputError.noWindow }
        if !window.isKeyWindow { window.makeKey() }
        if window.firstResponder !== webView { window.makeFirstResponder(webView) }
    }

    static func click(at point: CGPoint, in webView: WKWebView, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
        guard let window = webView.window else { throw InputError.noWindow }
        try focus(webView)
        let location = windowPoint(point, in: webView)
        try move(to: location, in: webView)
        for count in 1...max(1, clickCount) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)
                else { continue }
                // Straight to the view: the window would hit-test, and treat
                // a press in a window that is not frontmost as activation.
                if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
            }
        }
    }

    static func hover(at point: CGPoint, in webView: WKWebView) throws {
        try move(to: windowPoint(point, in: webView), in: webView)
    }

    private static func move(to location: NSPoint, in webView: WKWebView) throws {
        guard let window = webView.window else { throw InputError.noWindow }
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        // Moves come from tracking areas, not hit-testing, so they go to the view.
        webView.mouseMoved(with: event)
    }

    /// Press, move in steps (so pointer-driven drag code sees motion), release.
    static func drag(from start: CGPoint, to end: CGPoint, in webView: WKWebView) async throws {
        guard let window = webView.window else { throw InputError.noWindow }
        let from = windowPoint(start, in: webView), to = windowPoint(end, in: webView)
        func send(_ type: NSEvent.EventType, _ location: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            switch type {
            case .leftMouseDown: webView.mouseDown(with: event)
            case .leftMouseUp: webView.mouseUp(with: event)
            default: webView.mouseDragged(with: event)
            }
        }
        try focus(webView)
        try move(to: from, in: webView)
        send(.leftMouseDown, from)
        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            send(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            try await Task.sleep(for: .milliseconds(16))
        }
        send(.leftMouseUp, to)
    }

    // MARK: - Keyboard

    private static let idempotentCommands: [String: Selector] = [
        "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
    ]

    struct Key {
        var keyCode: UInt16
        var characters: String
        var charactersIgnoringModifiers: String
    }

    /// Function-key characters AppKit uses for keys with no printable form.
    private static func function(_ scalar: Int) -> String { String(UnicodeScalar(UInt16(scalar)).map(Character.init) ?? " ") }

    static let namedKeys: [String: Key] = {
        func key(_ code: UInt16, _ chars: String) -> Key { Key(keyCode: code, characters: chars, charactersIgnoringModifiers: chars) }
        var keys: [String: Key] = [
            "enter": key(36, "\r"), "return": key(36, "\r"), "tab": key(48, "\t"), "escape": key(53, "\u{1b}"), "esc": key(53, "\u{1b}"),
            "backspace": key(51, "\u{7f}"), "delete": key(117, function(NSDeleteFunctionKey)), "space": key(49, " "), " ": key(49, " "),
            "arrowup": key(126, function(NSUpArrowFunctionKey)), "arrowdown": key(125, function(NSDownArrowFunctionKey)),
            "arrowleft": key(123, function(NSLeftArrowFunctionKey)), "arrowright": key(124, function(NSRightArrowFunctionKey)),
            "home": key(115, function(NSHomeFunctionKey)), "end": key(119, function(NSEndFunctionKey)),
            "pageup": key(116, function(NSPageUpFunctionKey)), "pagedown": key(121, function(NSPageDownFunctionKey)),
        ]
        let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionCodes.enumerated() { keys["f\(index + 1)"] = key(code, function(NSF1FunctionKey + index)) }
        return keys
    }()

    /// ANSI key codes, so `KeyboardEvent.code` is right for letters and digits.
    static let characterCodes: [Character: UInt16] = {
        let letters: [(Character, UInt16)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31), ("u", 32),
            ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            ("n", 45), ("m", 46), (".", 47), ("`", 50), (" ", 49)]
        return Dictionary(uniqueKeysWithValues: letters)
    }()

    /// Parses "Meta+Shift+K", "Enter", "a".
    static func parse(_ chord: String) throws -> (Key, NSEvent.ModifierFlags) {
        var parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" itself, or a chord ending in it ("Shift++").
        if chord.hasSuffix("+") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let name = parts.popLast(), !name.isEmpty else { throw InputError.unknownKey(chord) }
        var modifiers: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier.lowercased() {
            case "meta", "cmd", "command", "controlormeta": modifiers.insert(.command)
            case "control", "ctrl": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: throw InputError.unknownKey(chord)
            }
        }
        if let key = namedKeys[name.lowercased()] { return (key, modifiers) }
        guard name.count == 1, let character = name.first else { throw InputError.unknownKey(chord) }
        return (key(for: character, shifted: modifiers.contains(.shift)), modifiers)
    }

    static func key(for character: Character, shifted: Bool = false) -> Key {
        let lower = Character(character.lowercased())
        let code = characterCodes[lower] ?? 0
        let text = shifted ? String(character).uppercased() : String(character)
        return Key(keyCode: code, characters: text, charactersIgnoringModifiers: String(lower))
    }

    /// One key press: down and up, with modifiers. Command chords go through
    /// key-equivalent handling, which offers them to the page first.
    static func press(_ chord: String, in webView: WKWebView) throws {
        let (key, modifiers) = try parse(chord)
        try send(key, modifiers: modifiers, to: webView)
    }

    /// Text, one character at a time; newlines are Enter.
    static func type(_ text: String, in webView: WKWebView) async throws {
        for (index, character) in text.enumerated() {
            if character == "\n" || character == "\r\n" {
                try send(namedKeys["enter"]!, modifiers: [], to: webView)
            } else if character == "\t" {
                try send(namedKeys["tab"]!, modifiers: [], to: webView)
            } else {
                let isUpper = character.isUppercase
                var key = key(for: character)
                key.characters = String(character)
                try send(key, modifiers: isUpper ? .shift : [], to: webView)
            }
            // Let the web process keep up with long text.
            if index % 40 == 39 { try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private static func send(_ key: Key, modifiers: NSEvent.ModifierFlags, to webView: WKWebView) throws {
        guard let window = webView.window else { throw InputError.noWindow }
        try focus(webView)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: key.characters,
                             charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false, keyCode: key.keyCode)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return }
        if modifiers.contains(.command) {
            if !webView.performKeyEquivalent(with: down) { webView.keyDown(with: down) }
            // The page has seen the chord. WebKit hands what it leaves to the
            // menus only in the active app, so the editing commands that are
            // safe to repeat are performed here too.
            if modifiers.subtracting(.command).isEmpty, let selector = idempotentCommands[key.charactersIgnoringModifiers] {
                NSApp.sendAction(selector, to: webView, from: nil)
            }
        } else {
            webView.keyDown(with: down)
        }
        webView.keyUp(with: up)
    }
}
