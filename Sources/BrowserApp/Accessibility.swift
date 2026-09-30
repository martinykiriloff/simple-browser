import AppKit

/// The Mac's accessibility settings the app follows, and an audit of its
/// own controls: every one VoiceOver reads must have a name.
@MainActor
enum Accessibility {
    /// Set by tests, which cannot change System Settings.
    static var reduceMotionOverride: Bool?
    static var increaseContrastOverride: Bool?

    /// Nothing slides or fades; it is simply there.
    static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Hairlines and tints become lines and colours.
    static var increaseContrast: Bool { increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// Every control in the tree VoiceOver would read without a name, as
    /// "class: what can be seen of it". Labels are their own name; editable
    /// fields, buttons, pop-ups and the like need a label or a title.
    static func unnamedControls(in root: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if let control = view as? NSControl, needsName(control) {
                let label = (control.accessibilityLabel() ?? "") + (control.accessibilityTitle() ?? "")
                if label.trimmingCharacters(in: .whitespaces).isEmpty {
                    found.append("\(type(of: control)): \(describe(control))")
                }
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return found
    }

    /// Toolbar items are not views: their label is their name.
    static func unnamedToolbarItems(in toolbar: NSToolbar?) -> [String] {
        (toolbar?.items ?? []).filter { !$0.isHidden && $0.label.isEmpty && ($0.view?.accessibilityLabel() ?? "").isEmpty && $0.itemIdentifier != .flexibleSpace }
            .map { $0.itemIdentifier.rawValue }
    }

    private static func needsName(_ control: NSControl) -> Bool {
        if let field = control as? NSTextField { return field.isEditable }
        if control is NSButton || control is NSPopUpButton || control is NSSegmentedControl || control is NSSlider || control is NSStepper { return true }
        return false
    }

    private static func describe(_ control: NSControl) -> String {
        if let button = control as? NSButton, let image = button.image { return "image \(image.name() ?? "?")" }
        if let field = control as? NSTextField { return "placeholder “\(field.placeholderString ?? "")”" }
        return control.identifier?.rawValue ?? "no title"
    }
}
