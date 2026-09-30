import AppKit
import BrowserKit

/// Keeps a record of every open window and tab on disk, and brings them back.
///
/// Written every few seconds while anything changes, not only at quit: a
/// crash, a power cut or `kill -9` loses at most those seconds. A marker
/// file says the app is running; finding it at launch means the last run
/// did not end cleanly.
@MainActor
final class SessionController {
    private let directory: URL
    private var sessionFile: URL { directory.appendingPathComponent("Session.json") }
    private var runningMarker: URL { directory.appendingPathComponent("Session.running") }
    private var updateMarker: URL { directory.appendingPathComponent("Session.restart-for-update") }
    private var timer: Timer?
    private var lastWritten: Data?
    /// The session found at launch, for History → Reopen All Windows from
    /// Last Session when it was not restored automatically.
    private(set) var previous: SessionSnapshot?
    private(set) var uncleanExit = false
    private(set) var restartForUpdate = false
    /// Off for self-test runs, so a test never overwrites the person's session.
    var isEnabled = true

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("SimpleBrowser", isDirectory: true)
    }

    /// Reads what the last run left, and marks this run as running.
    func begin() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        uncleanExit = FileManager.default.fileExists(atPath: runningMarker.path)
        restartForUpdate = FileManager.default.fileExists(atPath: updateMarker.path)
        try? FileManager.default.removeItem(at: updateMarker)
        if let data = try? Data(contentsOf: sessionFile) {
            previous = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        }
        guard isEnabled else { return }
        FileManager.default.createFile(atPath: runningMarker.path, contents: Data())
    }

    /// Saves every few seconds, when something changed.
    private var snapshot: (() -> SessionSnapshot)?

    func startSaving(_ snapshot: @escaping () -> SessionSnapshot) {
        guard isEnabled else { return }
        self.snapshot = snapshot
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let snapshot = self.snapshot else { return }
                self.save(snapshot())
            }
        }
        timer?.tolerance = 1
    }

    func save(_ snapshot: SessionSnapshot) {
        guard isEnabled else { return }
        var comparable = snapshot
        comparable.savedAt = .distantPast
        guard let data = try? JSONEncoder().encode(comparable), data != lastWritten else { return }
        lastWritten = data
        if let stamped = try? JSONEncoder().encode(snapshot) { try? stamped.write(to: sessionFile, options: .atomic) }
    }

    /// A clean quit: the session is saved and the marker goes.
    func end(_ snapshot: SessionSnapshot) {
        guard isEnabled else { return }
        timer?.invalidate()
        lastWritten = nil
        save(snapshot)
        try? FileManager.default.removeItem(at: runningMarker)
    }

    /// The updater is about to quit and relaunch into the new version.
    func markRestartForUpdate() {
        FileManager.default.createFile(atPath: updateMarker.path, contents: Data())
    }

    func shouldRestore(choice: StartupChoice) -> Bool {
        StartupChoice.shouldRestore(choice: choice, uncleanExit: uncleanExit, restartForUpdate: restartForUpdate,
                                    hasSession: !(previous?.isEmpty ?? true))
    }
}
