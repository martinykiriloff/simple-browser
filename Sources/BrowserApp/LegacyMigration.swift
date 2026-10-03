import Foundation

/// Keel was called SimpleBrowser. Its data folder moves with the name; the
/// bundle identifier, the Keychain items and the web data stores keep the old
/// name, because renaming them would sign every profile out and make saved
/// passwords unreadable.
enum LegacyMigration {
    static let oldFolder = "SimpleBrowser"
    static let newFolder = "Keel"

    /// Moves `Application Support/SimpleBrowser` to `Application Support/Keel`
    /// once, and points saved start pages at the new scheme. Runs before
    /// anything else reads the folder.
    static func run(fileManager fm: FileManager = .default) {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent(oldFolder, isDirectory: true)
        let new = support.appendingPathComponent(newFolder, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            return
        }
        let session = new.appendingPathComponent("Session.json")
        if let text = try? String(contentsOf: session, encoding: .utf8), text.contains("simplebrowser://") {
            try? text.replacingOccurrences(of: "simplebrowser://", with: "keel://").write(to: session, atomically: true, encoding: .utf8)
        }
    }
}
