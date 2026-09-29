import AppKit
import WebKit
import UniformTypeIdentifiers
import BrowserKit

/// The toolbar's downloads button: an arrow, with a ring that fills as the
/// downloads under way do.
@MainActor
final class DownloadsButton: NSButton {
    var fraction: Double? { didSet { if fraction != oldValue { needsDisplay = true } } }
    var isBusy = false { didSet { if isBusy != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isBusy else { return }
        let side = min(bounds.width, bounds.height) - 8
        let ring = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = 2
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
        // Without a total there is nothing to show but that it is going.
        let done = fraction ?? 0.08
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: side / 2, startAngle: 90, endAngle: 90 - 360 * done, clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }
}

/// One download in a list: its icon, name, how it is going, and what can
/// be done about it. A finished one can be dragged out as the file it is.
@MainActor
final class DownloadRowView: NSView, NSDraggingSource {
    let id: UUID
    let nameLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let pageLabel = NSTextField(labelWithString: "")
    let icon = NSImageView()
    let primaryButton = NSButton()
    let removeButton = NSButton()
    let revealButton = NSButton()
    let progress = NSProgressIndicator()
    private var item: DownloadItem
    private let actions: DownloadsListController

    init(item: DownloadItem, actions: DownloadsListController, showsPage: Bool) {
        self.id = item.id
        self.item = item
        self.actions = actions
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [statusLabel, pageLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        pageLabel.isHidden = !showsPage
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        for (button, action) in [(primaryButton, #selector(primary(_:))), (removeButton, #selector(remove(_:))), (revealButton, #selector(reveal(_:)))] {
            button.isBordered = false
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        revealButton.image = NSImage(systemSymbolName: "magnifyingglass.circle", accessibilityDescription: "Show in Finder")
        revealButton.toolTip = "Show in Finder"

        let text = NSStackView(views: [nameLabel, progress, statusLabel, pageLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text, primaryButton, revealButton, removeButton])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        update(item, status: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(_ item: DownloadItem, status: String) {
        self.item = item
        nameLabel.stringValue = item.fileName
        nameLabel.textColor = item.state == .cancelled || item.state == .failed ? .secondaryLabelColor : .labelColor
        statusLabel.stringValue = status
        statusLabel.textColor = item.state == .failed ? .systemRed : .secondaryLabelColor
        pageLabel.stringValue = item.page.map { "From " + $0.absoluteString } ?? "From " + item.url.absoluteString
        let exists = item.state == .finished && FileManager.default.fileExists(atPath: item.path)
        icon.image = exists ? NSWorkspace.shared.icon(forFile: item.path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.fileName as NSString).pathExtension) ?? .data)
        icon.alphaValue = item.state == .finished ? 1 : 0.6
        progress.isHidden = !(item.state == .downloading || item.state == .paused)
        progress.isIndeterminate = item.fraction == nil && item.state == .downloading
        if let fraction = item.fraction { progress.doubleValue = fraction }
        if progress.isIndeterminate { progress.startAnimation(nil) }

        let (symbol, label): (String?, String) = {
            switch item.state {
            case .downloading: return ("pause.circle", "Pause")
            case .paused: return ("play.circle", "Resume")
            case .failed: return ("arrow.clockwise.circle", item.canResume ? "Resume" : "Try Again")
            case .cancelled: return ("arrow.clockwise.circle", "Download Again")
            case .finished: return (nil, "")
            }
        }()
        primaryButton.isHidden = symbol == nil
        primaryButton.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        primaryButton.toolTip = label
        primaryButton.setAccessibilityLabel(label)
        revealButton.isHidden = !exists
        let removes = item.state == .downloading || item.state == .paused
        removeButton.image = NSImage(systemSymbolName: removes ? "xmark.circle" : "minus.circle", accessibilityDescription: removes ? "Cancel" : "Remove from List")
        removeButton.toolTip = removes ? "Cancel" : "Remove from list"
        removeButton.setAccessibilityLabel(removes ? "Cancel" : "Remove from List")
        setAccessibilityLabel("\(item.fileName), \(status)")
    }

    var primaryTitle: String { primaryButton.isHidden ? "" : (primaryButton.toolTip ?? "") }

    @objc private func primary(_ sender: Any?) { actions.primary(id) }
    @objc private func remove(_ sender: Any?) { actions.removeOrCancel(id) }
    @objc private func reveal(_ sender: Any?) { actions.manager.reveal(id) }

    // A click opens it; a drag takes the file.
    private var mouseDownAt: NSPoint?
    override func mouseDown(with event: NSEvent) { mouseDownAt = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownAt = nil }
        guard let start = mouseDownAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 else { return }
        if event.clickCount >= 1, item.state == .finished { actions.open(id) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, item.state == .finished, FileManager.default.fileExists(atPath: item.path),
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownAt = nil
        let dragged = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: item.path) as NSURL)
        dragged.setDraggingFrame(icon.convert(icon.bounds, to: self), contents: icon.image)
        beginDraggingSession(with: [dragged], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move, .link] }
}

/// A list of downloads, for the button's popover (the recent few) and for
/// the Downloads window (all of them, with the page each came from).
@MainActor
final class DownloadsListController: NSViewController {
    let manager: DownloadManager
    /// The web view a resumed download goes through: any of the profile's.
    var webView: () -> WKWebView?
    var window: () -> NSWindow?
    var showAll: (() -> Void)?
    private let limit: Int?
    private let showsPage: Bool
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads")
    let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    let showAllButton = NSButton(title: "Show All Downloads", target: nil, action: nil)
    private(set) var rows: [DownloadRowView] = []
    private var observer: NSObjectProtocol?
    private var ticker: Timer?
    /// Replaces the "this file can run" alert, for the self-test.
    var confirmRisk: ((DownloadItem) async -> Bool)?

    init(manager: DownloadManager, limit: Int?, showsPage: Bool, webView: @escaping () -> WKWebView?, window: @escaping () -> NSWindow?) {
        self.manager = manager
        self.limit = limit
        self.showsPage = showsPage
        self.webView = webView
        self.window = window
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        clearButton.target = self
        clearButton.action = #selector(clear(_:))
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.toolTip = "Remove finished downloads from the list. The files stay."
        showAllButton.target = self
        showAllButton.action = #selector(showAllDownloads(_:))
        showAllButton.bezelStyle = .accessoryBarAction
        showAllButton.isHidden = limit == nil
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [showAllButton, spacer, clearButton])
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(footer)
        root.addSubview(emptyLabel)
        let height = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            height,
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ] + (limit == nil ? [] : [root.widthAnchor.constraint(equalToConstant: 380), scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 380)]))
        view = root
        observer = NotificationCenter.default.addObserver(forName: DownloadManager.didChange, object: manager, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        // Speed and time left move on even when no byte arrives.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        ticker?.invalidate()
        ticker = nil
    }

    var shown: [DownloadItem] { limit.map { Array(manager.list.items.prefix($0)) } ?? manager.list.items }

    func refresh() {
        guard isViewLoaded else { return }
        let items = shown
        if rows.map(\.id) != items.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = items.map { DownloadRowView(item: $0, actions: self, showsPage: showsPage) }
            for row in rows {
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        for (row, item) in zip(rows, items) { row.update(item, status: manager.status(of: item)) }
        emptyLabel.isHidden = !items.isEmpty
        clearButton.isEnabled = manager.list.items.contains { $0.state == .finished || $0.state == .failed || $0.state == .cancelled }
    }

    // MARK: - What the rows do

    func primary(_ id: UUID) {
        guard let item = manager.list[id] else { return }
        Task { @MainActor in
            switch item.state {
            case .downloading: await manager.pause(id)
            case .paused, .failed: if let webView = webView() { await manager.resume(id, in: webView) }
            case .cancelled: if let webView = webView() { manager.retry(id, in: webView) }
            case .finished: break
            }
        }
    }

    func removeOrCancel(_ id: UUID) {
        guard let item = manager.list[id] else { return }
        Task { @MainActor in
            if item.state == .downloading || item.state == .paused { await manager.cancel(id) } else { await manager.remove(id) }
        }
    }

    func open(_ id: UUID) {
        Task { @MainActor in await manager.open(id, from: window(), confirm: confirmRisk) }
    }

    @objc private func clear(_ sender: Any?) { manager.clearFinished() }
    @objc private func showAllDownloads(_ sender: Any?) { showAll?() }
}

/// Window → Downloads (⌥⌘L): every download of the profile, with the page
/// each came from.
@MainActor
final class DownloadsWindowController: NSWindowController {
    let list: DownloadsListController

    init(manager: DownloadManager, profileName: String, webView: @escaping () -> WKWebView?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        weak var weakWindow = window
        list = DownloadsListController(manager: manager, limit: nil, showsPage: true, webView: webView, window: { weakWindow })
        super.init(window: window)
        QuietMode.apply(to: window)
        window.title = "Downloads — \(profileName)"
        window.minSize = NSSize(width: 420, height: 240)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        window.setContentSize(NSSize(width: 620, height: 440))
        if !window.setFrameUsingName("DownloadsWindow") { window.center() }
        window.setFrameAutosaveName("DownloadsWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}
