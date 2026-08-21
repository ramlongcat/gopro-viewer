import AppKit
import Combine
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

    /// Emits ±1 when a two-finger horizontal swipe should step to the
    /// previous or next item. ViewerView subscribes; the gesture is detected
    /// here because the pointer spends its time over AVPlayerView or the
    /// photo's NSScrollView, neither of which SwiftUI gestures can reach.
    let swipe = PassthroughSubject<Int, Never>()

    private var window: NSWindow?
    private weak var model: AppModel?
    /// The last shape handed to fit(aspect:), kept so leaving full screen
    /// can restore the fitted, centered frame.
    private var lastAspect: CGFloat?
    /// Set while we close the window ourselves, so the delegate callback
    /// doesn't bounce straight back into the model.
    private var closingOurselves = false
    private var pointerMonitor: Any?
    private var idleTimer: Timer?

    /// Swipe bookkeeping: deltas accumulated over the gesture in flight, and
    /// whether it already navigated (its remaining events get swallowed so
    /// the leftover momentum doesn't pan the item it lands on).
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var swipeEligible = false
    private var swipeFired = false

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
        // Small enough that a vertical clip's fitted width never collides
        // with the minimum while the aspect lock is on.
        w.contentMinSize = NSSize(width: 280, height: 280)
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
        // A local monitor rather than a hover modifier: the pointer spends
        // most of its time over AVPlayerView's own NSView, which SwiftUI
        // never hears about. The same monitor watches for horizontal
        // trackpad swipes, which step between items.
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            self.pointerMoved()
            if event.type == .scrollWheel { return self.handleSwipe(event) }
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
    /// resizing to that shape. The geometry is deterministic: every item gets
    /// the same height, centered on the screen with an even margin, and only
    /// the width follows the media's shape (a clip too wide for the screen
    /// gives some height back). Deriving the size from the current frame — as
    /// this used to — let an in-flight animated resize feed back into the
    /// next fit, which is how the window ended up tiny or adrift.
    func fit(aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0 else { return }
        lastAspect = aspect
        guard window != nil, !isFullScreen else { return }
        // Never resize from inside a SwiftUI update. refit() fires in
        // .onChange within navigate()'s animated transaction, and a frame
        // change captured there is replayed by NSHostingView's animated
        // window sizing during the window's own layout pass — which macOS 26
        // punishes with an NSException (the crash when stepping through
        // items). One hop off the runloop leaves the transaction behind.
        DispatchQueue.main.async { [weak self] in self?.applyFit(aspect: aspect) }
    }

    private func applyFit(aspect: CGFloat) {
        guard let w = window, !isFullScreen else { return }
        let visible = (w.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var mediaH = (visible.height * 0.85).rounded()
        var mediaW = (mediaH * aspect).rounded()
        let maxW = (visible.width * 0.92).rounded()
        if mediaW > maxW { mediaW = maxW; mediaH = (mediaW / aspect).rounded() }

        // Round first, then lock to the rounded shape, so the constraint and
        // the size agree exactly and no half-pixel bar survives.
        let size = NSSize(width: mediaW, height: mediaH)
        w.contentAspectRatio = size
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: (visible.midX - frame.width / 2).rounded(),
                               y: (visible.midY - frame.height / 2).rounded())
        if w.frame != frame { w.setFrame(frame, display: true) }
    }

    // MARK: Trackpad swipe

    /// Turns a two-finger horizontal swipe into previous/next, the way Photos
    /// does. Only trackpad gestures qualify (they carry phases; mouse wheels
    /// don't), and a photo zoomed in past its fit keeps the swipe for
    /// panning.
    private func handleSwipe(_ e: NSEvent) -> NSEvent? {
        guard let w = window, e.window === w else { return e }
        if e.momentumPhase != [] {
            if e.momentumPhase == .ended { swipeFired = false }
            return swipeFired ? nil : e
        }
        switch e.phase {
        case .began:
            swipeX = 0
            swipeY = 0
            swipeFired = false
            swipeEligible = !canPanHorizontally(w.contentView)
            return e
        case .changed:
            if swipeFired { return nil }
            guard swipeEligible else { return e }
            swipeX += e.scrollingDeltaX
            swipeY += e.scrollingDeltaY
            // Clearly vertical from the start: hand the gesture back.
            if abs(swipeY) > abs(swipeX), abs(swipeY) > 24 {
                swipeEligible = false
                return e
            }
            if abs(swipeX) > 60, abs(swipeX) > 2 * abs(swipeY) {
                swipeFired = true
                // Natural scrolling: fingers moving left drag the content
                // left, which asks for the next item.
                swipe.send(swipeX < 0 ? 1 : -1)
                return nil
            }
            return e
        case .ended, .cancelled:
            return swipeFired ? nil : e
        default:
            return e
        }
    }

    /// True if some scroll view in the window has horizontal room to pan —
    /// a zoomed-in photo. (Reading NSScrollView's own geometry is fine; the
    /// grid's no-frame-geometry rule is about SwiftUI-scrolled overlays,
    /// which this window has none of.)
    private func canPanHorizontally(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if let sv = view as? NSScrollView, let doc = sv.documentView,
           doc.frame.width > sv.contentView.bounds.width + 1 {
            return true
        }
        return view.subviews.contains { canPanHorizontally($0) }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        window = nil
        lastAspect = nil
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
        // AppKit restores the pre-full-screen frame; put the fitted,
        // centered one back instead.
        if let lastAspect { fit(aspect: lastAspect) }
    }
}
