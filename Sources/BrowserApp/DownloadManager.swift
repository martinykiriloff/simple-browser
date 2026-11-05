import AppKit
import WebKit
import BrowserKit

/// The downloads of one profile: what is under way, what is paused, what
/// was saved, kept from launch to launch.
///
/// Through `WKDownload`, so a request carries the profile's cookies: a file
/// behind a sign-in downloads as the signed-in person. A paused download
/// keeps what WebKit needs to take it up again (its resume data) on disk,
/// so it can be resumed after the app was quit.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let didChange = Notification.Name("Keel.downloadsDidChange")

    private(set) var list = DownloadList()
    /// Where the list and resume data are kept; nil keeps them in memory
    /// (a private window's downloads, a test's).
    let directory: URL?
    /// How many downloads this launch began: the toolbar button appears
    /// with the first.
    private(set) var startedThisLaunch = 0

    private struct Pending {
        var page: URL?
        var askWhere: Bool
        var folder: URL?
        var choose: ((String) async -> URL?)?
        weak var window: NSWindow?
        var resuming: UUID?
    }
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var ids: [ObjectIdentifier: UUID] = [:]
    private var live: [UUID: WKDownload] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var meters: [UUID: DownloadMeter] = [:]
    /// Being paused or cancelled by the person: WebKit's report that the
    /// download "failed" is that, not a failure.
    private var stopping: Set<UUID> = []
    /// Whose file carries the quarantine mark already, so it is put on once
    /// and as soon as there is a file to put it on.
    private var quarantined: Set<UUID> = []
    private var resumeDataInMemory: [UUID: Data] = [:]
    private var lastSave = Date.distantPast

    init(directory: URL?) {
        self.directory = directory
        super.init()
        if let directory {
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Resume"), withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: directory.appendingPathComponent("Downloads.json")),
               let saved = try? JSONDecoder().decode(DownloadList.self, from: data) {
                list = saved
                list.markInterrupted { FileManager.default.fileExists(atPath: self.resumeURL($0)?.path ?? "") }
                save(force: true)
            }
        }
    }

    // MARK: - Starting

    /// "Save Link As…" and the like: a download the browser starts.
    func start(_ url: URL, in webView: WKWebView, page: URL?, askWhere: Bool, folder: URL? = nil, choose: ((String) async -> URL?)? = nil,
               adopted: ((UUID) -> Void)? = nil) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated {
                self?.adopt(download, page: page, askWhere: askWhere, window: webView.window, folder: folder, choose: choose, adopted: adopted)
            }
        }
    }

    /// A navigation or link WebKit turned into a download.
    func adopt(_ download: WKDownload, page: URL?, askWhere: Bool, window: NSWindow?, folder: URL? = nil, choose: ((String) async -> URL?)? = nil,
               adopted: ((UUID) -> Void)? = nil) {
        download.delegate = self
        pending[ObjectIdentifier(download)] = Pending(page: page, askWhere: askWhere, folder: folder, choose: choose, window: window)
        adoptions[ObjectIdentifier(download)] = adopted
    }

    private var adoptions: [ObjectIdentifier: (UUID) -> Void] = [:]

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        let context = pending.removeValue(forKey: key) ?? Pending(page: nil, askWhere: false)
        if let id = context.resuming, let item = list[id] {
            // Taken up again: into the file it was going into.
            return URL(fileURLWithPath: item.path)
        }
        let name = Self.safeFileName(suggestedFilename)
        let folder = context.folder ?? BrowserSettings.downloadFolder
        let destination: URL?
        if context.askWhere || (BrowserSettings.askWhereToSave && context.folder == nil) {
            destination = await ask(name, folder: folder, window: context.window, choose: context.choose)
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Names being written to count as taken: two files of one name
            // arriving together had both been given it, and one was lost.
            let taken = Set(list.items.filter { $0.isActive || $0.state == .paused }.map(\.path))
            destination = Self.unique(folder.appendingPathComponent(name), taken: taken)
        }
        guard let destination else {
            adoptions[key] = nil
            return nil
        }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let item = DownloadItem(url: response.url ?? download.originalRequest?.url ?? destination, page: context.page, path: destination.path,
                                total: total, needsConfirmation: DownloadRisk.isDangerous(fileName: destination.lastPathComponent))
        list.add(item)
        startedThisLaunch += 1
        track(download, as: item.id)
        adoptions.removeValue(forKey: key)?(item.id)
        changed(save: true)
        return destination
    }

    private func track(_ download: WKDownload, as id: UUID) {
        ids[ObjectIdentifier(download)] = id
        live[id] = download
        meters[id] = DownloadMeter()
        observations[id] = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let done = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async { self?.progressed(id, received: done, total: total) }
        }
    }

    private func progressed(_ id: UUID, received: Int64, total: Int64) {
        guard list[id]?.state == .downloading else { return }
        // WebKit makes the file itself, so the earliest moment there is one
        // to mark is the first sign of bytes in it -- long before the file
        // is whole, and so before it could be opened.
        markQuarantine(id)
        list.update(id) { item in
            item.received = max(item.received, received)
            if total > 0 { item.total = total }
        }
        meters[id]?.record(bytes: received, at: ProcessInfo.processInfo.systemUptime)
        changed(save: false)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = forget(download), let item = list[id] else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: item.path))?[.size] as? NSNumber)?.int64Value
        list.update(id) { item in
            item.state = .finished
            item.finishedAt = Date()
            if let size { item.received = size; item.total = size }
            item.canResume = false
        }
        removeResumeData(id)
        // Nothing arrived to mark earlier if the file was empty until now.
        markQuarantine(id)
        let file = URL(fileURLWithPath: item.path)
        if !Self.isQuarantined(file), !Self.quarantine(file, from: item.url, page: item.page) {
            // Said out loud rather than swallowed: macOS will not check a
            // file it was never told came from the web, and the browser
            // will not open it either.
            let why = "macOS could not be told this file came from the web, so it is not opened from here"
            list.update(id) { $0.failure = why }
            FileHandle.standardError.write(Data("[downloads] \(item.fileName): \(why)\n".utf8))
        }
        // What Safari posts: the Downloads stack in the Dock bounces.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: item.path)
        changed(save: true)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let id = forget(download) else {
            pending[ObjectIdentifier(download)] = nil
            return
        }
        // Part of a file is still a file from the web: what was written
        // before it stopped is marked too, so it is checked if it is ever
        // opened or taken up again.
        markQuarantine(id)
        if stopping.contains(id) { return }      // paused or cancelled; its own code finishes the job
        if let resumeData { storeResumeData(resumeData, for: id) }
        list.update(id) { item in
            item.state = .failed
            item.failure = error.localizedDescription
            item.canResume = resumeData != nil
        }
        changed(save: true)
    }

    @discardableResult
    private func forget(_ download: WKDownload) -> UUID? {
        guard let id = ids.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        live[id] = nil
        observations[id] = nil
        meters[id] = nil
        return id
    }

    // MARK: - Pause, resume, cancel

    func pause(_ id: UUID) async {
        // `stopping` is taken before the await below, so a second click
        // while WebKit is still stopping the first one does nothing.
        guard let download = live[id], list[id]?.state == .downloading, !stopping.contains(id) else { return }
        stopping.insert(id)
        let data = await download.cancel()
        forget(download)
        stopping.remove(id)
        if let data { storeResumeData(data, for: id) }
        list.update(id) { item in
            item.state = .paused
            item.canResume = data != nil
        }
        changed(save: true)
    }

    /// Takes a paused or failed download up again from where it stopped,
    /// or from the start if nothing was kept to go on from.
    func resume(_ id: UUID, in webView: WKWebView) async {
        guard let item = list[id], item.state == .paused || item.state == .failed else { return }
        // Going again is written down before asking WebKit, which takes a
        // turn of the loop: two quick clicks on Resume would otherwise both
        // pass the guard and set two downloads writing the same file.
        list.update(id) { item in
            item.state = .downloading
            item.failure = nil
        }
        changed(save: true)
        guard let data = resumeData(for: id) else {
            retry(id, in: webView)
            return
        }
        let download = await webView.resumeDownload(fromResumeData: data)
        download.delegate = self
        pending[ObjectIdentifier(download)] = Pending(page: item.page, askWhere: false, resuming: id)
        track(download, as: id)
        changed(save: true)
    }

    /// From the start, under the same name.
    func retry(_ id: UUID, in webView: WKWebView) {
        guard let item = list[id] else { return }
        try? FileManager.default.removeItem(atPath: item.path)
        removeResumeData(id)
        quarantined.remove(id)
        list.remove(id)
        let destination = URL(fileURLWithPath: item.path)
        start(item.url, in: webView, page: item.page, askWhere: false, folder: destination.deletingLastPathComponent())
        changed(save: true)
    }

    /// Stops it and removes what was saved of it.
    func cancel(_ id: UUID) async {
        // As with pause: the second of two quick clicks finds it already
        // being stopped and leaves it alone.
        guard let item = list[id], item.state != .cancelled, !stopping.contains(id) else { return }
        if let download = live[id] {
            stopping.insert(id)
            _ = await download.cancel()
            forget(download)
            stopping.remove(id)
        }
        removeResumeData(id)
        if item.state != .finished {
            try? FileManager.default.removeItem(atPath: item.path)
            quarantined.remove(id)
        }
        list.update(id) { item in
            item.state = .cancelled
            item.canResume = false
        }
        changed(save: true)
    }

    /// Takes it off the list. The file, if it finished, stays where it is.
    func remove(_ id: UUID) async {
        if list[id]?.isActive == true || list[id]?.state == .paused { await cancel(id) }
        removeResumeData(id)
        quarantined.remove(id)
        list.remove(id)
        changed(save: true)
    }

    func clearFinished() {
        list.clearFinished()
        changed(save: true)
    }

    /// Developer aid: forgets every download, as though the app had just launched with none.
    func forgetAll() async {
        for item in list.items { await remove(item.id) }
        startedThisLaunch = 0
        changed(save: true)
    }

    /// At quit: everything under way is paused, so that it can be taken up
    /// again next time rather than started over.
    func pauseAll() async {
        for item in list.active { await pause(item.id) }
        save(force: true)
    }

    // MARK: - The files

    /// Opens a finished download. One that can run is asked about first,
    /// once; after "Keep" it opens like any other.
    func open(_ id: UUID, from window: NSWindow?, confirm: ((DownloadItem) async -> Bool)? = nil) async {
        guard let item = list[id], item.state == .finished else { return }
        guard FileManager.default.fileExists(atPath: item.path) else {
            list.update(id) { $0.state = .failed; $0.failure = "The file was moved or deleted" }
            changed(save: true)
            return
        }
        // Gatekeeper's one chance. A file macOS was never told came from the
        // web runs unchecked, so one that cannot be marked is not opened
        // from here at all.
        let file = URL(fileURLWithPath: item.path)
        if !Self.isQuarantined(file), !Self.quarantine(file, from: item.url, page: item.page) {
            let why = "macOS could not be told this file came from the web, so it cannot be opened from here"
            list.update(id) { $0.failure = why }
            changed(save: true)
            FileHandle.standardError.write(Data("[downloads] \(item.fileName): \(why)\n".utf8))
            await tellAboutUncheckedFile(item, window: window)
            return
        }
        if item.needsConfirmation {
            let keep = await (confirm ?? { [weak self] in await self?.askAboutRisk($0, window: window) ?? false })(item)
            guard keep else { return }
            list.update(id) { $0.needsConfirmation = false }
            changed(save: true)
        }
        opened.append(item.path)
        if openFiles { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
    }

    /// Off in the self-test, which must not launch what it downloaded.
    var openFiles = true
    private(set) var opened: [String] = []

    private func askAboutRisk(_ item: DownloadItem, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(item.fileName)” can run on your Mac"
        alert.informativeText = "It was downloaded from \(item.source). Open it only if you trust where it came from."
        // Cancel first, so Return -- and Escape -- do the safe thing. This
        // warning is the only gate before the file runs; a stray keystroke
        // must not open it.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[1].hasDestructiveAction = true
        if let window { return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn }
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Said once, where it matters: the file is on disk, but the browser
    /// will not hand it to macOS unchecked.
    private func tellAboutUncheckedFile(_ item: DownloadItem, window: NSWindow?) async {
        // The self-test turns opening off; it must not be stopped by a sheet.
        guard openFiles else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(item.fileName)” cannot be opened from here"
        alert.informativeText = "macOS could not be told that it was downloaded from \(item.source), so it would run without being checked. "
            + "It is still in your downloads folder: show it in the Finder to decide for yourself."
        alert.addButton(withTitle: "OK")
        if let window { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func reveal(_ id: UUID) {
        guard let item = list[id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    private func ask(_ name: String, folder: URL, window: NSWindow?, choose: ((String) async -> URL?)?) async -> URL? {
        if let choose { return await choose(name) }
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = folder
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return nil }
        // The panel already asked about replacing; WebKit refuses to write over a file.
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Marks the file as downloaded from the web, as Safari does, so macOS
    /// checks it and asks before it first runs. True when the mark is on
    /// the file afterwards: a volume that keeps no such mark, or a file
    /// that is not there, is a no, not a shrug.
    @discardableResult
    static func quarantine(_ file: URL, from url: URL, page: URL?) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "Keel",
            kLSQuarantineDataURLKey as String: url,
        ]
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        do { try file.setResourceValues(values) } catch { return false }
        return isQuarantined(file)
    }

    /// Whether the mark is really on the file. Setting it can fail quietly,
    /// so what is opened is decided by reading it back.
    static func isQuarantined(_ file: URL) -> Bool {
        guard let properties = (try? file.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties else { return false }
        return properties[kLSQuarantineTypeKey as String] != nil
    }

    /// Puts the mark on as soon as there is a file to put it on. Tried once
    /// as the bytes start arriving; whether it took is read back from the
    /// file itself at the end, and again before anything is opened.
    private func markQuarantine(_ id: UUID) {
        guard !quarantined.contains(id), let item = list[id],
              FileManager.default.fileExists(atPath: item.path) else { return }
        quarantined.insert(id)
        Self.quarantine(URL(fileURLWithPath: item.path), from: item.url, page: item.page)
    }

    /// A name that is safe as a file name: no path separators, no control
    /// characters, not hidden, not empty, not absurdly long.
    static func safeFileName(_ proposed: String) -> String {
        let cleaned = proposed.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || "/:\\".unicodeScalars.contains($0) ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let name = cleaned.isEmpty ? "download" : cleaned
        return name.count > 200 ? String(name.prefix(200)) : name
    }

    /// `report.pdf`, then `report (2).pdf`, as Finder names copies.
    static func unique(_ url: URL, taken: Set<String> = []) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) || taken.contains(url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        for n in 2... {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !manager.fileExists(atPath: candidate.path), !taken.contains(candidate.path) { return candidate }
        }
        return url
    }

    // MARK: - For the list

    func status(of item: DownloadItem) -> String {
        DownloadFormat.status(item, speed: meters[item.id]?.speed, secondsLeft: meters[item.id]?.secondsLeft(total: item.total))
    }

    // MARK: - Keeping

    private func resumeURL(_ id: UUID) -> URL? { directory?.appendingPathComponent("Resume/\(id.uuidString).resume") }

    private func storeResumeData(_ data: Data, for id: UUID) {
        if let url = resumeURL(id) { try? data.write(to: url, options: .atomic) } else { resumeDataInMemory[id] = data }
    }

    private func resumeData(for id: UUID) -> Data? {
        if let url = resumeURL(id) { return try? Data(contentsOf: url) }
        return resumeDataInMemory[id]
    }

    private func removeResumeData(_ id: UUID) {
        if let url = resumeURL(id) { try? FileManager.default.removeItem(at: url) }
        resumeDataInMemory[id] = nil
    }

    private func changed(save now: Bool) {
        save(force: now)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Progress is written down every couple of seconds, not at every byte.
    private func save(force: Bool) {
        guard let directory, force || Date().timeIntervalSince(lastSave) > 2 else { return }
        lastSave = Date()
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: directory.appendingPathComponent("Downloads.json"), options: .atomic)
        }
    }
}
