import AppKit

/// Muting, Picture in Picture, and the now-playing control, for a tab.
extension BrowserWindowController {
    /// Window → Mute Tab, and the speaker on the tab.
    @objc func toggleMuteTab(_ sender: Any?) {
        media.setMuted(!media.isMuted)
    }

    /// View → Picture in Picture, and the toolbar button.
    @objc func togglePictureInPicture(_ sender: Any?) {
        Task { @MainActor in _ = await media.setPictureInPicture(!media.isPictureInPicture) }
    }

    /// With the setting on, a video playing goes into Picture in Picture as
    /// another tab is chosen, and back into its page as this one is again.
    func selectionChanged(selected: Bool) {
        defer { wasSelected = selected }
        if selected {
            if let task = autoPictureInPictureTask {
                // Back before the video was out: it stays in the page, and
                // whatever comes of a request already made goes back.
                task.cancel()
                autoPictureInPictureTask = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    if self.media.isPictureInPicture, !self.autoPictureInPictureActive { _ = await self.media.setPictureInPicture(false) }
                }
            }
            if autoPictureInPictureActive {
                autoPictureInPictureActive = false
                Task { @MainActor in _ = await media.setPictureInPicture(false) }
            }
        } else if wasSelected, BrowserSettings.automaticPictureInPicture, media.hasVideo, !media.isPictureInPicture {
            autoPictureInPictureTask = Task { @MainActor in
                guard await media.isPlayingVideo(), !Task.isCancelled else { return }
                let out = await media.setPictureInPicture(true)
                guard !Task.isCancelled else { return }
                autoPictureInPictureActive = out
                autoPictureInPictureTask = nil
            }
        }
    }

    /// Shows what the app is playing, from whichever tab.
    func syncNowPlaying(_ tab: BrowserWindowController?) {
        nowPlaying.show(tab)
        nowPlayingItem?.isHidden = tab == nil
        fitAddressField()
    }
}

/// The toolbar's now-playing control: the tab making sound, whichever it is,
/// with play/pause and next; its title shows the tab.
@MainActor
final class NowPlayingControl: NSStackView {
    let titleButton = NSButton(title: "", target: nil, action: nil)
    let playButton = NSButton()
    let nextButton = NSButton()
    private weak var tab: BrowserWindowController?

    init() {
        super.init(frame: .zero)
        spacing = 2
        titleButton.bezelStyle = .toolbar
        titleButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        titleButton.imagePosition = .imageLeading
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.target = self
        titleButton.action = #selector(showTab(_:))
        titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        for (button, action) in [(playButton, #selector(playPause(_:))), (nextButton, #selector(next(_:)))] {
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
        }
        nextButton.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Next")
        nextButton.toolTip = "Next"
        addArrangedSubview(titleButton)
        addArrangedSubview(playButton)
        addArrangedSubview(nextButton)
        setAccessibilityLabel("Now playing")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ tab: BrowserWindowController?) {
        self.tab = tab
        guard let tab else { return }
        let title = tab.media.title.isEmpty ? (tab.window?.title ?? "") : tab.media.title
        titleButton.title = title
        titleButton.toolTip = "\(title) — show this tab"
        playButton.image = NSImage(systemSymbolName: tab.media.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: tab.media.isPlaying ? "Pause" : "Play")
        playButton.toolTip = tab.media.isPlaying ? "Pause" : "Play"
        nextButton.isHidden = !tab.media.canSkip
    }

    var title: String { titleButton.title }

    @objc func showTab(_ sender: Any?) { tab?.show() }
    @objc func playPause(_ sender: Any?) {
        guard let tab else { return }
        Task { @MainActor in await tab.media.perform(.toggle) }
    }
    @objc func next(_ sender: Any?) {
        guard let tab else { return }
        Task { @MainActor in await tab.media.perform(.next) }
    }
}
