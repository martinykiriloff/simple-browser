import AppKit

/// Back and Forward: a click goes one step; holding the button, or a
/// right-click, lists every step in that direction, as in Safari and Chrome.
@MainActor
final class NavigationButton: NSButton {
    /// Builds the list when it is about to show.
    var historyMenu: (() -> NSMenu?)?
    private var holdTimer: Timer?
    private var showedMenu = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showedMenu = false
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showedMenu = true
                self.popHistory()
            }
        }
        // Track until the button is released, so a short press stays a click.
        highlight(true)
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            if showedMenu { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        highlight(false)
        holdTimer?.invalidate()
        if !showedMenu, let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        popHistory()
    }

    private func popHistory() {
        holdTimer?.invalidate()
        guard let menu = historyMenu?(), !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
