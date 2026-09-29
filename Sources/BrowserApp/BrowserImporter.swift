import AppKit
import Security
import BrowserKit
import DataKit
import PasswordKit

/// Brings another browser's bookmarks, history, open tabs and passwords
/// into a profile. The other browser's files are read away from the main
/// thread; what was found is then added to the profile's own stores.
@MainActor
final class BrowserImporter {
    struct Result: Equatable {
        var bookmarks = 0, readingList = 0, pages = 0, tabs = 0, passwords = 0
        var problems: [String] = []

        var summary: String {
            var parts: [String] = []
            if bookmarks > 0 { parts.append(bookmarks == 1 ? "1 bookmark" : "\(bookmarks) bookmarks") }
            if readingList > 0 { parts.append("\(readingList) reading list \(readingList == 1 ? "item" : "items")") }
            if pages > 0 { parts.append(pages == 1 ? "1 page of history" : "\(pages) pages of history") }
            if tabs > 0 { parts.append(tabs == 1 ? "1 open tab" : "\(tabs) open tabs") }
            if passwords > 0 { parts.append(passwords == 1 ? "1 password" : "\(passwords) passwords") }
            let what = parts.isEmpty ? "Nothing new to bring over." : "Brought over " + Self.list(parts) + "."
            return ([what] + problems).joined(separator: " ")
        }

        static func list(_ items: [String]) -> String {
            items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    let app: AppDelegate
    /// The secret a Chromium browser keeps its passwords' key in. Asking
    /// the Keychain for it is what makes macOS ask the person to allow it.
    var chromiumSecret: (BrowserImport.Browser) -> String? = BrowserImporter.keychainSecret

    init(app: AppDelegate) { self.app = app }

    func run(_ source: BrowserImport.Source, parts: BrowserImport.Parts, into profile: Profile) async -> Result {
        var result = Result()
        let contents: BrowserImport.Contents
        do {
            contents = try await Task.detached { try BrowserImport.read(source, parts: parts) }.value
        } catch {
            result.problems.append("Could not read \(source.browser.name)’s files: \(error).")
            return result
        }
        if parts.contains(.bookmarks), let store = app.bookmarks(for: profile) {
            do {
                result.bookmarks += try store.importBookmarks(contents.bookmarksBar, into: store.favoritesID)
                if contents.otherBookmarks.contains(where: { $0.count > 0 }) {
                    result.bookmarks += try store.importBookmarks(contents.otherBookmarks, into: store.importFolder(named: "Imported from \(source.browser.name)"))
                }
                result.readingList += try store.importReadingList(contents.readingList)
                NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
            } catch {
                result.problems.append("Some bookmarks could not be added: \(error).")
            }
        }
        if parts.contains(.history), let history = app.history(for: profile) {
            do { result.pages = try history.importPages(contents.history) } catch { result.problems.append("History could not be added: \(error).") }
        }
        if parts.contains(.openTabs), !contents.windows.isEmpty {
            // Asleep, as a restored session is: nothing loads until it is shown.
            let windows = contents.windows.map { tabs in
                SessionSnapshot.Window(profileID: profile.id, frame: CodableRect(x: 120, y: 120, width: 1280, height: 800),
                                       tabs: tabs.map { SessionSnapshot.Tab(url: $0.url, title: $0.title, state: nil) }, selected: 0)
            }
            app.restore(SessionSnapshot(windows: windows))
            result.tabs = contents.windows.reduce(0) { $0 + $1.count }
        }
        if parts.contains(.passwords), !contents.logins.isEmpty {
            if let secret = chromiumSecret(source.browser), let key = ChromiumPasswords.key(from: secret) {
                let rows = contents.logins.compactMap { login -> PasswordCSV.Row? in
                    guard let origin = CredentialOrigin.normalize(login.origin),
                          let password = ChromiumPasswords.decrypt(login.encryptedPassword, key: key), !password.isEmpty else { return nil }
                    return PasswordCSV.Row(origin: origin, username: login.username, password: password)
                }
                do {
                    let summary = try await app.passwords(for: profile).importRows(rows)
                    result.passwords = summary.added + summary.updated
                    if rows.count < contents.logins.count {
                        result.problems.append("\(contents.logins.count - rows.count) passwords could not be read.")
                    }
                } catch {
                    result.problems.append("Passwords could not be saved: \(error).")
                }
            } else {
                result.problems.append("Passwords were not brought over: \(source.browser.name)’s key in the Keychain was not given.")
            }
        }
        return result
    }

    /// Chromium's "… Safe Storage" item. macOS shows its own prompt, naming
    /// the item, for the person to allow once or always.
    nonisolated static func keychainSecret(_ browser: BrowserImport.Browser) -> String? {
        guard let service = browser.safeStorageService else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
