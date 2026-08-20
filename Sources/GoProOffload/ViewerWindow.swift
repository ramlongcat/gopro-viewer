import AppKit
import SwiftUI

/// The viewer gets a window of its own rather than a sheet. Two reasons, both
/// of them AppKit's: a window with a sheet attached refuses to go full screen
/// (the button did nothing at all), and only a real window can be sized to the
/// clip's own aspect ratio — which is what keeps black bars off the preview.
final class ViewerWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ViewerWindowController()

    @Published private(set) var isFullScreen = false
    /// Full screen hides the floating controls once the pointer goes still.
    /// Always true in a window, where the chrome is part of the furniture.
    @Published private(set) var chromeVisible = true

    private var window: NSWindow?
    private weak var model: AppModel?
    private var didSize = false
    /// Set while we close the window ourselves, so the delegate callback
    /// doesn't bounce straight back into the model.
    private var closingOurselves = false
    private var pointerMonitor: Any?
    private var idleTimer: Timer?

    private let idleDelay: TimeInterval = 2.5

    func show(model: AppModel, transfers: TransferManager) {
        self.model = model
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Preview"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentMinSize = NSSize(width: 520, height: 340)
        w.acceptsMouseMovedEvents = true
        // The floating chrome carries close and full screen already; traffic
        // lights would only collide with the title pill. The invisible
        // titlebar band still drags the window.
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = true
        }
        let host = NSHostingView(rootView: ViewerView()
            .environmentObject(model)
            .environmentObject(transfers))
        // The window drives the size here, not the SwiftUI content.
        host.sizingOptions = []
        w.contentView = host
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        didSize = false
        // A local monitor rather than a hover modifier: the pointer spends
        // most of its time over AVPlayerView's own NSView, which SwiftUI
        // never hears about.
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]
        ) { [weak self] event in
            self?.pointerMoved()
            return event
        }
    }

    func close() {
        guard let w = window else { return }
        closingOurselves = true
        w.close()
        closingOurselves = false
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Any pointer activity brings the controls back and restarts the clock.
    private func pointerMoved() {
        guard isFullScreen else { return }
        if !chromeVisible { chromeVisible = true }
        armIdle()
    }

    private func armIdle() {
        idleTimer?.invalidate()
        guard isFullScreen else {
            chromeVisible = true
            return
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleDelay, repeats: false) { [weak self] _ in
            self?.chromeVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func setTitle(_ title: String) {
        window?.title = title
    }

    /// Sizes the window to exactly `aspect` — no letterbox — and locks
    /// resizing to that shape.
    func fit(aspect: CGFloat) {
        guard let w = window, !isFullScreen, aspect.isFinite, aspect > 0 else { return }
        let visible = (w.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = visible.width * 0.94, maxH = visible.height * 0.94

        var mediaW = w.contentView?.bounds.width ?? 1120
        var recenter = false
        if !didSize {
            // First item of the session: pick a comfortable size rather than
            // inheriting whatever the placeholder frame was.
            didSize = true
            recenter = true
            mediaW = min(1180, maxW)
        }
        var mediaH = mediaW / aspect
        if mediaH > maxH { mediaH = maxH; mediaW = mediaH * aspect }
        if mediaW > maxW { mediaW = maxW; mediaH = mediaW / aspect }

        // Round first, then lock to the rounded shape, so the constraint and
        // the size agree exactly and no half-pixel bar survives.
        let size = NSSize(width: mediaW.rounded(), height: mediaH.rounded())
        w.contentAspectRatio = size
        w.setContentSize(size)
        if recenter { w.center() }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        window = nil
        didSize = false
        isFullScreen = false
        chromeVisible = true
        if !closingOurselves { model?.viewer = nil }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        armIdle()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        armIdle()
    }
}
