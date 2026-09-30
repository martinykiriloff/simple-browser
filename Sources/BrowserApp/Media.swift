import AppKit
import MediaPlayer
import WebKit

/// What one tab is playing, and its controls: play and pause, next and
/// previous (the page's own media session actions), mute, and Picture in
/// Picture.
@MainActor
final class TabMedia: NSObject, WKScriptMessageHandler {
    static let worldName = "SimpleBrowserMedia"
    static let handlerName = "simpleBrowserMedia"

    weak var webView: WKWebView?
    /// Told whenever what the tab plays changes.
    var onChange: (() -> Void)?
    private let world = WKContentWorld.world(name: TabMedia.worldName)
    private weak var userContentController: WKUserContentController?

    private(set) var isPlaying = false
    private(set) var isAudible = false
    private(set) var hasVideo = false
    private(set) var isPictureInPicture = false
    private(set) var canSkip = false
    private(set) var title = ""
    private(set) var artist = ""
    /// When it last started playing: the media keys go to the latest.
    private(set) var startedAt: Date?
    /// Measured on 2026-09-30: asked back into Picture in Picture within a
    /// second or two of leaving it, WebKit either ignores the request or puts
    /// the video straight back in the page; how long depends on how far the
    /// last window had got. Asked after 1.5 seconds it usually stays out, so
    /// a request that soon waits for the gap, and one that does not take is
    /// made again, up to three times.
    static let pictureInPictureGap: TimeInterval = 1.5
    static let pictureInPictureAttempts = 3
    private var leftPictureInPictureAt: Date?

    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        guard let url = AppResources.bundle.url(forResource: "media-agent", withExtension: "js", subdirectory: "MediaAgent"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        controller.add(self, contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        // The page's own next and previous, kept where the app can call them.
        controller.addUserScript(WKUserScript(source: """
            (() => {
              const session = navigator.mediaSession;
              if (!session || !window.MediaSession) return;
              const handlers = new Map();
              const original = MediaSession.prototype.setActionHandler;
              const mark = () => { if (document.documentElement) document.documentElement.dataset.sbMediaActions = Array.from(handlers.keys()).join(' '); };
              Object.defineProperty(MediaSession.prototype, 'setActionHandler', { configurable: true, writable: true, value: function (action, handler) {
                if (handler) handlers.set(action, handler); else handlers.delete(action);
                mark();
                return original.call(this, action, handler);
              } });
              Object.defineProperty(window, '__sbMediaSessionAction', { value: (action) => {
                const handler = handlers.get(action);
                if (!handler) return false;
                handler({ action });
                return true;
              } });
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        // Pages may go full screen, and videos into Picture in Picture.
        configuration.preferences.isElementFullscreenEnabled = true
        WebInspectorSPI.setPreference("allowsPictureInPictureMediaPlayback", true, on: configuration.preferences)
    }

    func uninstall() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
    }

    /// A new page: nothing is playing until it says so.
    func didCommitNavigation() {
        guard isPlaying || hasVideo || isPictureInPicture else { return }
        isPlaying = false
        isAudible = false
        hasVideo = false
        isPictureInPicture = false
        canSkip = false
        onChange?()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["kind"] as? String == "state" else { return }
        let playing = body["playing"] as? Bool ?? false
        if playing && !isPlaying { startedAt = Date() }
        isPlaying = playing
        isAudible = body["audible"] as? Bool ?? false
        hasVideo = body["hasVideo"] as? Bool ?? false
        let pictureInPicture = body["pictureInPicture"] as? Bool ?? false
        if isPictureInPicture && !pictureInPicture { leftPictureInPictureAt = Date() }
        isPictureInPicture = pictureInPicture
        canSkip = body["canSkip"] as? Bool ?? false
        title = body["title"] as? String ?? ""
        artist = body["artist"] as? String ?? ""
        onChange?()
    }

    // MARK: - Controls

    enum Command: String { case play, pause, toggle, next = "nexttrack", previous = "previoustrack" }

    func perform(_ command: Command) async {
        guard let webView else { return }
        switch command {
        case .next, .previous:
            _ = try? await webView.callAsyncJavaScript("return window.__sbMediaSessionAction ? window.__sbMediaSessionAction(name) : false",
                                                       arguments: ["name": command.rawValue], in: nil, contentWorld: .page)
        case .play, .pause, .toggle:
            // A page that handles play and pause itself is asked first, as the media keys would.
            let handled = try? await webView.callAsyncJavaScript("""
                const own = (document.documentElement.dataset.sbMediaActions || '').split(' ');
                const playing = Array.from(document.querySelectorAll('video, audio')).some(m => !m.paused);
                const wanted = name === 'toggle' ? (playing ? 'pause' : 'play') : name;
                return own.includes(wanted) && window.__sbMediaSessionAction ? window.__sbMediaSessionAction(wanted) : false
                """,
                arguments: ["name": command.rawValue], in: nil, contentWorld: .page) as? Bool
            if handled != true {
                _ = try? await webView.callAsyncJavaScript("return window.__simpleBrowserMedia.command(name)", arguments: ["name": command.rawValue],
                                                           in: nil, contentWorld: world)
            }
        }
    }

    var isMuted: Bool {
        guard let webView, webView.responds(to: NSSelectorFromString("_mediaMutedState")) else { return false }
        return ((webView.value(forKey: "_mediaMutedState") as? NSNumber)?.intValue ?? 0) & 1 != 0
    }

    /// WebKit's own page mute: the page cannot turn it back on.
    func setMuted(_ muted: Bool) {
        guard let webView else { return }
        let setter = NSSelectorFromString("_setPageMuted:")
        if webView.responds(to: setter), let method = webView.method(for: setter) {
            typealias Set = @convention(c) (AnyObject, Selector, Int) -> Void
            unsafeBitCast(method, to: Set.self)(webView, setter, muted ? 1 : 0)
        }
        onChange?()
    }

    /// Answers whether the video is where it was asked to be.
    @discardableResult
    func setPictureInPicture(_ on: Bool) async -> Bool {
        guard on else {
            leftPictureInPictureAt = Date()
            return await askPictureInPicture(false)
        }
        for attempt in 0..<Self.pictureInPictureAttempts {
            if let left = leftPictureInPictureAt {
                let wait = Self.pictureInPictureGap - Date().timeIntervalSince(left)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            if Task.isCancelled { return false }
            guard await askPictureInPicture(true) else { return false }
            if await pictureInPictureSettled() { return true }
            // Not out, or back in the page by itself: as if it had just left.
            leftPictureInPictureAt = Date()
            if attempt + 1 < Self.pictureInPictureAttempts { FileHandle.standardError.write(Data("[media] Picture in Picture did not take, asking again\n".utf8)) }
        }
        return false
    }

    private func askPictureInPicture(_ on: Bool) async -> Bool {
        guard let webView else { return false }
        return (try? await webView.callAsyncJavaScript("return window.__simpleBrowserMedia.pictureInPicture(on)", arguments: ["on": on],
                                                       in: nil, contentWorld: world) as? Bool) ?? false
    }

    /// Out within a second, and still out a moment later.
    private func pictureInPictureSettled() async -> Bool {
        let deadline = Date().addingTimeInterval(1.2)
        while !isPictureInPicture {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(700))
        return isPictureInPicture && !Task.isCancelled
    }

    func isPlayingVideo() async -> Bool {
        guard let webView else { return false }
        return (try? await webView.callAsyncJavaScript("return window.__simpleBrowserMedia.isPlayingVideo()", arguments: [:], in: nil, contentWorld: world) as? Bool) ?? false
    }
}

/// Every tab's media, for the whole app: the now-playing control in the
/// toolbar, the Mac's Now Playing and its media keys. The keys go to the
/// tab that started playing last, wherever it is, not to the tab in front.
@MainActor
final class MediaCenter {
    static let didChange = Notification.Name("MediaCenter.didChange")

    var tabs: () -> [BrowserWindowController] = { [] }
    /// Off in test runs: the person's own music keeps its keys.
    var publishesNowPlaying = !QuietMode.isOn
    private var registered = false

    /// What the keys and the toolbar control: the latest to start of the
    /// tabs playing, or, when none is, the latest that played.
    var current: BrowserWindowController? {
        let all = tabs()
        let playing = all.filter { $0.media.isPlaying }
        return (playing.isEmpty ? all.filter { $0.media.startedAt != nil } : playing)
            .max { ($0.media.startedAt ?? .distantPast) < ($1.media.startedAt ?? .distantPast) }
    }

    func changed() {
        publish()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// What the media keys do.
    func handle(_ command: TabMedia.Command) {
        guard let tab = current else { return }
        Task { @MainActor in await tab.media.perform(command) }
    }

    /// Window → Mute Background Tabs: every tab making sound but the one in front.
    func muteBackgroundTabs(except front: BrowserWindowController?) {
        for tab in tabs() where tab !== front && tab.media.isAudible { tab.media.setMuted(true) }
    }

    // MARK: - The Mac's Now Playing

    private func publish() {
        guard publishesNowPlaying else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let tab = current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        register()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: tab.media.title.isEmpty ? (tab.window?.title ?? "") : tab.media.title,
            MPMediaItemPropertyArtist: tab.media.artist.isEmpty ? (tab.currentURL?.host() ?? "") : tab.media.artist,
        ]
        center.playbackState = tab.media.isPlaying ? .playing : .paused
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = tab.media.canSkip
        commands.previousTrackCommand.isEnabled = tab.media.canSkip
    }

    private func register() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        let pairs: [(MPRemoteCommand, TabMedia.Command)] = [
            (commands.playCommand, .play), (commands.pauseCommand, .pause), (commands.togglePlayPauseCommand, .toggle),
            (commands.nextTrackCommand, .next), (commands.previousTrackCommand, .previous),
        ]
        for (remote, command) in pairs {
            remote.addTarget { [weak self] _ in
                Task { @MainActor in self?.handle(command) }
                return .success
            }
        }
    }
}
