import AppKit
import UpdateKit

/// Keeps SimpleBrowser up to date from the project's GitHub Releases.
///
/// On launch, at most once a day, it asks GitHub for the latest release; a
/// newer one is offered with Install Update / Remind Me Later / Skip This
/// Version, as Sparkle offers it. Installing downloads the DMG, refuses it
/// unless its Ed25519 signature verifies against the key compiled in below,
/// checks the app inside is this app at the promised version, and swaps it in
/// once this copy has quit, then relaunches.
@MainActor
final class Updater {
    static let repository = "martinykiriloff/simple-browser"
    /// Its private half is the repository secret UPDATE_SIGNING_KEY; CI signs
    /// each release DMG with it. `swift run SignUpdate --generate-key` makes a new pair.
    static let publicKey = "9+ORZTr1HoFGu+RmJawgfCIhlC+7/hgOqtNVZbZGz28="

    private static let lastCheckKey = "updates.lastCheck"
    private static let skippedKey = "updates.skippedVersion"

    /// The release feed. Only a loopback address may replace GitHub's, for the self-test;
    /// the signature check applies to whatever it serves.
    var feedURL = GitHubReleases.latestURL(repository: repository)
    /// Where the running app is, and what version it is. Nil when run from
    /// the build folder: there is nothing to replace, only a page to open.
    var installedApp: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
    var currentVersion: AppVersion? = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    /// Answers the offer without a person, for the self-test.
    var autoAnswer: NSApplication.ModalResponse?
    /// Called instead of quitting, for the self-test.
    var onReadyToRelaunch: ((URL) -> Void)?
    /// Just before quitting to install: the session must come back as it was.
    var onWillRestart: (() -> Void)?
    /// Called with the message a failure would have shown, for the self-test.
    var onFailure: ((String) -> Void)?

    private var checking = false
    private var timer: Timer?
    private var progress: UpdateProgressWindow?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - When to check

    /// A few seconds after launch, so the first window is up first, then daily.
    func start() {
        guard currentVersion != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
        // Hourly, when the Mac has a quiet moment.
        IdleWork.repeating("update-check", every: 60 * 60) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard UpdatePolicy.isDue(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date) else { return }
        check(userInitiated: false)
    }

    /// App menu → Check for Updates…
    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let update = try await fetchLatest()
                defaults.set(Date(), forKey: Self.lastCheckKey)
                let current = currentVersion ?? AppVersion("0")!
                let skipped = (defaults.string(forKey: Self.skippedKey)).flatMap(AppVersion.init)
                guard let update, UpdatePolicy.shouldOffer(update, current: current, skipped: skipped, userInitiated: userInitiated) else {
                    if userInitiated { upToDate() }
                    return
                }
                offer(update)
            } catch {
                if userInitiated { fail("SimpleBrowser could not check for updates.", error) }
            }
        }
    }

    private func fetchLatest() async throws -> AvailableUpdate? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SimpleBrowser/\(currentVersion?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }       // no release published yet
        guard status == 200 else { throw UpdateError.http(status) }
        return try GitHubReleases.parse(data)
    }

    /// No cookies, no cache: an update check identifies nobody.
    private static let session = URLSession(configuration: .ephemeral)

    // MARK: - Asking

    private func offer(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "A new version of SimpleBrowser is available!"
        var text = "SimpleBrowser \(update.version) is available — you have \(currentVersion?.description ?? "a development build"). Would you like to update now?"
        let notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += "\n\nWhat’s new:\n" + (notes.count > 700 ? String(notes.prefix(700)) + "…" : notes) }
        alert.informativeText = text
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: installedApp == nil ? "Open Release Page" : "Install Update")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()
        switch autoAnswer ?? alert.runModal() {
        case .alertFirstButtonReturn:
            defaults.removeObject(forKey: Self.skippedKey)
            if installedApp == nil { NSWorkspace.shared.open(update.pageURL) } else { install(update) }
        case .alertThirdButtonReturn:
            defaults.set(update.version.description, forKey: Self.skippedKey)
        default:
            // Remind Me Later: the next daily check asks again.
            break
        }
    }

    private func upToDate() {
        let alert = NSAlert()
        alert.messageText = "You’re up to date!"
        alert.informativeText = "SimpleBrowser \(currentVersion?.description ?? "(development build)") is the newest version available."
        alert.icon = NSApp.applicationIconImage
        if autoAnswer == nil { alert.runModal() }
    }

    private func fail(_ title: String, _ error: any Error) {
        lastError = "\(title) \(Self.describe(error))"
        progress?.close()
        progress = nil
        onFailure?(lastError ?? title)
        guard autoAnswer == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = Self.describe(error)
        alert.runModal()
    }

    /// For the self-test.
    private(set) var lastError: String?

    // MARK: - Installing

    enum UpdateError: Error, LocalizedError {
        case http(Int)
        case signature(UpdateSignature.VerifyError)
        case noAppInImage
        case wrongApp(String)
        case wrongVersion(String)
        case notReplaceable(String)
        case tool(String, String)

        var errorDescription: String? {
            switch self {
            case .http(let status): return "The update server answered \(status)."
            case .signature: return "The download is not signed by SimpleBrowser’s key, so it was not opened. Nothing was changed."
            case .noAppInImage: return "The downloaded disk image does not contain SimpleBrowser."
            case .wrongApp(let id): return "The downloaded app is not SimpleBrowser (\(id))."
            case .wrongVersion(let version): return "The downloaded app is version \(version), not the one offered."
            case .notReplaceable(let why): return why
            case .tool(let name, let output): return "\(name) failed: \(output)"
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? UpdateError { return error.errorDescription ?? "\(error)" }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return "The update server could not be reached. Check the connection and try again." }
        return error.localizedDescription
    }

    private func install(_ update: AvailableUpdate) {
        guard let installedApp else { return }
        let window = UpdateProgressWindow(version: update.version)
        progress = window
        window.show()
        Task { @MainActor in
            do {
                try Self.checkReplaceable(installedApp)
                window.status("Downloading SimpleBrowser \(update.version)…")
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBrowser-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let (signatureData, _) = try await Self.session.data(from: update.signatureURL)
                let (downloaded, response) = try await Self.session.download(from: update.dmgURL)
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw UpdateError.http(status) }
                let dmg = work.appendingPathComponent("update.dmg")
                try FileManager.default.moveItem(at: downloaded, to: dmg)

                window.status("Verifying…")
                do {
                    try UpdateSignature.verify(try Data(contentsOf: dmg, options: .mappedIfSafe),
                                               signature: String(decoding: signatureData, as: UTF8.self), publicKey: Self.publicKey)
                } catch let error as UpdateSignature.VerifyError {
                    throw UpdateError.signature(error)
                }

                window.status("Preparing…")
                let staged = try await Self.stage(dmg, in: work, expecting: update.version)
                window.status("Restarting SimpleBrowser…")
                try Self.scheduleSwap(staged: staged, over: installedApp, work: work)
                if let onReadyToRelaunch { onReadyToRelaunch(staged); return }
                onWillRestart?()
                NSApp.terminate(nil)
            } catch {
                fail("SimpleBrowser could not be updated.", error)
            }
        }
    }

    /// An app Gatekeeper is running from a translocated copy, or one in a
    /// folder this user cannot write, cannot be replaced in place.
    static func checkReplaceable(_ app: URL) throws {
        if app.path.contains("/AppTranslocation/") {
            throw UpdateError.notReplaceable("SimpleBrowser is running from a temporary location macOS made for it. Move it to the Applications folder, open it from there, and update again.")
        }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw UpdateError.notReplaceable("SimpleBrowser cannot replace itself in \(app.deletingLastPathComponent().path): that folder is not writable for this user.")
        }
    }

    /// Mounts the image, copies the app out, checks it is this app at the
    /// promised version with a valid signature, and unmounts.
    static func stage(_ dmg: URL, in work: URL, expecting version: AppVersion) async throws -> URL {
        let mount = work.appendingPathComponent("mount")
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        let staged = work.appendingPathComponent("SimpleBrowser.app")
        do {
            let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
            guard let app = apps.first(where: { $0.lastPathComponent == "SimpleBrowser.app" }) ?? apps.first else { throw UpdateError.noAppInImage }
            try await run("/usr/bin/ditto", [app.path, staged.path])
        } catch {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        let identifier = info?["CFBundleIdentifier"] as? String ?? "?"
        guard identifier == (Bundle.main.bundleIdentifier ?? "dev.simplebrowser.SimpleBrowser") else { throw UpdateError.wrongApp(identifier) }
        let stagedVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard AppVersion(stagedVersion) == version else { throw UpdateError.wrongVersion(stagedVersion) }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        // Verified above, by signature; the download's quarantine flag would
        // only make Gatekeeper ask about an app the person already chose.
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Hands the swap to a small script that waits for this process to exit,
    /// moves the old app aside, puts the new one in its place (moving the old
    /// one back if that fails), and opens it.
    static func scheduleSwap(staged: URL, over app: URL, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        let source = """
        #!/bin/sh
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.previous"
        if mv "$3" "$3.previous" && /usr/bin/ditto "$2" "$3"; then
          rm -rf "$3.previous"
        else
          rm -rf "$3"; mv "$3.previous" "$3"
        fi
        /usr/bin/open "$3"
        rm -rf "$4"
        """
        try Data(source.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, app.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: UpdateError.tool((tool as NSString).lastPathComponent, output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// A small window that says what the update is doing.
@MainActor
final class UpdateProgressWindow {
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init(version: AppVersion) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Updating SimpleBrowser"
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .bar
        spinner.isIndeterminate = true
        let column = NSStackView(views: [label, spinner])
        column.orientation = .vertical
        column.alignment = .leading
        let row = NSStackView(views: [icon, column])
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48),
            spinner.widthAnchor.constraint(equalToConstant: 270),
        ])
        window.contentView = row
        status("Preparing SimpleBrowser \(version)…")
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        spinner.startAnimation(nil)
    }

    func status(_ text: String) { label.stringValue = text }

    func close() { window.close() }
}
