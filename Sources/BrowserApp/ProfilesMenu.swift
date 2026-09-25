import AppKit
import BrowserKit

/// Fills a Profiles menu when it opens: every profile (click to open a window
/// in it, as in Chrome), then New, Rename and Delete for the current one.
///
/// Built on open rather than once, so a profile added or renamed in one
/// window is already right in every other window's menu.
@MainActor
final class ProfilesMenuFiller: NSObject, NSMenuDelegate {
    private let store: ProfileStore
    /// The profile the menu is "about": its window's, or the frontmost one's.
    private let current: () -> Profile

    init(store: ProfileStore, current: @escaping () -> Profile) {
        self.store = store
        self.current = current
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = current()
        for (index, profile) in store.profiles.enumerated() {
            let item = menu.addItem(withTitle: profile.name,
                                    action: #selector(AppDelegate.openProfileWindow(_:)),
                                    keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = [.command, .shift, .option]
            item.representedObject = profile.id
            item.image = ProfileBadge.image(for: profile)
            item.state = profile.id == current.id ? .on : .off
            item.toolTip = "Open a new window as \(profile.name)"
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Profile…", action: #selector(AppDelegate.newProfile(_:)), keyEquivalent: "")
        let rename = menu.addItem(withTitle: "Rename “\(current.name)”…",
                                  action: #selector(AppDelegate.renameProfile(_:)), keyEquivalent: "")
        rename.representedObject = current.id
        let delete = menu.addItem(withTitle: "Delete “\(current.name)”…",
                                  action: #selector(AppDelegate.deleteProfile(_:)), keyEquivalent: "")
        delete.representedObject = current.id
        // The roster refuses to remove its last profile; say so here too.
        if store.profiles.count == 1 { delete.action = nil }
    }
}

/// The coloured person symbol that says which profile a window is.
@MainActor
enum ProfileBadge {
    static func color(_ accent: GroupColor) -> NSColor {
        switch accent {
        case .graphite: return .systemGray
        case .red:      return .systemRed
        case .orange:   return .systemOrange
        case .yellow:   return .systemYellow
        case .green:    return .systemGreen
        case .teal:     return .systemTeal
        case .blue:     return .systemBlue
        case .purple:   return .systemPurple
        case .pink:     return .systemPink
        }
    }

    static func image(for profile: Profile) -> NSImage? {
        NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: profile.name)?
            .withSymbolConfiguration(.init(paletteColors: [.white, color(profile.accent)]))
    }
}
