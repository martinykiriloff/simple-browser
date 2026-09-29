import AppKit
import BrowserKit

/// Window → Pin Tab and the tab-group commands, for the tab in front.
extension BrowserWindowController {
    @objc func togglePinTab(_ sender: Any?) {
        organizer?.setPinned([self], !isPinned)
    }

    /// Window → New Tab Group: this tab in a new group, named at once.
    @objc func newTabGroup(_ sender: Any?) {
        guard let organizer, let id = organizer.newGroup(with: [self]) else { return }
        editGroup(id)
    }

    @objc func removeTabFromGroup(_ sender: Any?) {
        organizer?.removeFromGroup([self])
    }

    /// The name and colour, in a popover from the group in the sidebar, or
    /// from the top of the window when the sidebar is hidden.
    func editGroup(_ id: TabGroupID, from anchor: NSView? = nil) {
        guard let organizer else { return }
        let editor = GroupEditorController(organizer: organizer, group: id)
        let popover = NSPopover()
        popover.contentViewController = editor
        popover.behavior = .transient
        lastGroupEditor = editor
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        } else if let content = window?.contentView {
            popover.show(relativeTo: NSRect(x: content.bounds.midX, y: content.bounds.maxY - 4, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
    }
}
