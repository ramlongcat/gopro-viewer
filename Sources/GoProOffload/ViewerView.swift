import AppKit
import AVFoundation
import AVKit
import Combine
import QuartzCore
import SwiftUI

struct ViewerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transfers: TransferManager
    @ObservedObject private var win = ViewerWindowController.shared
    @State private var slideDir = 1
    /// What the pane itself measured — the player's presentation size, or the
    /// photo once it decodes. More trustworthy than the camera's numbers, and
    /// the only source at all for stills.
    @State private var paneAspect: CGFloat?

    private var isFullScreen: Bool { win.isFullScreen }

    private var entry: MediaEntry? {
        model.viewer.flatMap { model.entry(for: $0.id) }
    }

    /// The shape to give the window, best source first.
    private var aspect: CGFloat? {
        if let paneAspect { return paneAspect }
        guard let entry, let mi = model.mediaInfo[entry.id],
              let w = mi.width, let h = mi.height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    var body: some View {
        let entry = entry
        ZStack {
            Color.black
            if let entry {
                content(entry)
                    .id("pane-\(entry.id)")
                    .transition(.asymmetric(
                        insertion: .move(edge: slideDir >= 0 ? .trailing : .leading),
                        removal: .move(edge: slideDir >= 0 ? .leading : .trailing)
                    ))
            } else {
                Text("This item is no longer on the camera.")
                    .foregroundStyle(.white)
            }
        }
        .clipped()
        // Every control floats over the media, so the media itself fills the
        // window edge to edge. The fade goes on each control, never on the
        // stack — that would take the picture with it.
        .overlay(alignment: .top) { topChrome(entry).chromeFade() }
        .overlay(alignment: .leading) { navButton(-1).padding(.leading, 20).chromeFade() }
        .overlay(alignment: .trailing) { navButton(1).padding(.trailing, 20).chromeFade() }
        // The window hides its titlebar but SwiftUI still insets for it,
        // which would letterbox the media inside an exactly-fitted window.
        .ignoresSafeArea()
        .background(navShortcuts)
        .onReceive(win.swipe) { navigate($0) }
        .onAppear { refit() }
        .onChange(of: aspect) { refit() }
        // Two same-shape items don't change `aspect`, but the window should
        // still return to its centered spot when stepping between them.
        .onChange(of: entry?.id) { refit() }
        .onChange(of: entry?.displayName) { win.setTitle(entry?.displayName ?? "Preview") }
    }

    private func navigate(_ delta: Int) {
        slideDir = delta
        // The new item measures itself; until it does, the camera's numbers
        // (usually already cached) shape the window.
        paneAspect = nil
        withAnimation(.easeOut(duration: 0.28)) {
            model.viewerNeighbor(delta)
        }
    }

    /// Hands the media's shape to the window, which resizes to match it.
    private func refit() {
        guard let aspect else { return }
        win.fit(aspect: aspect)
    }

    private func toggleFullScreen() { win.toggleFullScreen() }

    /// ← / → and `,` / `.` step through the library, and `<` / `>` do the
    /// same with shift held — a shortcut matches modifiers exactly, so each
    /// needs saying. Seeking lives on ⇧← / ⇧→ so the bare arrows can
    /// navigate.
    private var navShortcuts: some View {
        Group {
            Button("") { navigate(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { navigate(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { navigate(-1) }.keyboardShortcut(",", modifiers: [])
            Button("") { navigate(1) }.keyboardShortcut(".", modifiers: [])
            Button("") { navigate(-1) }.keyboardShortcut(",", modifiers: .shift)
            Button("") { navigate(1) }.keyboardShortcut(".", modifiers: .shift)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Floating chrome

    /// Actions only. What the file is and everything about it belongs to the
    /// grid's inspector, next to the thumbnails.
    private func topChrome(_ entry: MediaEntry?) -> some View {
        actionPill(entry)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20)
            .padding(.top, 18)
    }

    private func actionPill(_ entry: MediaEntry?) -> some View {
        HStack(spacing: 18) {
            if let entry, !model.downloadedIDs.contains(entry.id) {
                Button { model.download(entry) } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Copies only the item shown here — use the sidebar's Copy button for a selection")
                .disabled(transfers.isActive)
                .opacity(transfers.isActive ? 0.35 : 1)
            }
            Button(action: toggleFullScreen) {
                Image(systemName: isFullScreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .help(isFullScreen ? "Leave full screen" : "Full screen")
            Button { model.viewer = nil } label: {
                Image(systemName: "xmark")
            }
            .help("Close (Esc)")
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.white)
        .frame(height: 22)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPill()
    }

    /// Previous / next, floating against the left and right edges.
    private func navButton(_ delta: Int) -> some View {
        let p = model.viewerPosition()
        let off = delta < 0 ? (p?.0 ?? 1) <= 1 : (p.map { $0.0 >= $0.1 } ?? true)
        return Button { navigate(delta) } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .glassPill()
        .opacity(off ? 0.25 : 1)
        .disabled(off)
        .help(delta < 0 ? "Previous (← or ,) — or swipe" : "Next (→ or .) — or swipe")
    }

    /// Panes report their measured shape tagged with their own item, because
    /// the outgoing pane of a slide transition is still alive: a departing
    /// video's time observer gets one more tick in and would otherwise
    /// overwrite the incoming photo's shape — leaving the photo pillarboxed
    /// in a window fitted to the video.
    private func setPaneAspect(_ a: CGFloat, from id: String) {
        guard id == entry?.id else { return }
        paneAspect = a
    }

    @ViewBuilder
    private func content(_ entry: MediaEntry) -> some View {
        switch entry.kind {
        case .video:
            VideoPane(entry: entry, onAspect: { setPaneAspect($0, from: entry.id) }).id(entry.id)
        case .photo(let f), .photoGroup(let f):
            PhotoPane(file: f, onAspect: { setPaneAspect($0, from: entry.id) }).id(entry.id)
        case .other(let f):
            VStack(spacing: 10) {
                Image(systemName: "doc").font(.largeTitle)
                Text(f.name)
            }
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Floating chrome

/// The blurred capsule behind every floating control in the viewer — Tahoe's
/// glass where it exists, a material capsule everywhere else. Always dark, so
/// the white glyphs read the same over any frame.
private struct GlassPill: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: Capsule())
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            }
        }
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}

/// Fades floating controls out together while full screen sits idle, and
/// stops them catching clicks they can't be seen to catch.
private struct ChromeFade: ViewModifier {
    @ObservedObject private var win = ViewerWindowController.shared

    func body(content: Content) -> some View {
        content
            .opacity(win.chromeVisible ? 1 : 0)
            .allowsHitTesting(win.chromeVisible)
            .animation(.easeInOut(duration: 0.28), value: win.chromeVisible)
    }
}

extension View {
    /// Wraps a floating viewer control in the shared blurred pill.
    fileprivate func glassPill() -> some View { modifier(GlassPill()) }

    /// Ties a floating control to the viewer's show/hide state.
    fileprivate func chromeFade() -> some View { modifier(ChromeFade()) }
}

// MARK: - Video

extension Color {
    /// The camera's HiLight tags, everywhere they appear.
    static let hiLight = Color(red: 1.0, green: 0.78, blue: 0.25)
}

/// The video's playback bar, ours rather than AVKit's. AVPlayerView's own
/// scrub bar takes no annotations — there is no public API for marks — so the
/// controls are switched off (see PlayerView) and the camera's HiLight tags
/// ride the real timeline here, in gold. Click or drag anywhere to seek; a
/// click landing within ~7pt of a tag snaps exactly to it.
private struct TransportBar: View {
    let isPlaying: Bool
    let position: Double
    let duration: Double
    let hilights: [Double]
    let playPause: () -> Void
    let seek: (Double) -> Void

    /// Set while dragging, so the readout follows the finger instead of the
    /// player — seeking a camera stream on every drag tick is far too costly.
    @State private var scrub: Double?

    private let knob: CGFloat = 14
    private let tickWidth: CGFloat = 3.5

    private var shown: Double { scrub ?? position }

    private func frac(_ sec: Double) -> CGFloat {
        duration > 0 ? CGFloat(min(1, max(0, sec / duration))) : 0
    }

    private func target(_ x: CGFloat, span: CGFloat) -> Double {
        let raw = Double(min(span, max(0, x - knob / 2)) / span) * duration
        let tolerance = Double(7 / span) * duration
        guard let near = hilights.min(by: { abs($0 - raw) < abs($1 - raw) }) else { return raw }
        return abs(near - raw) <= tolerance ? near : raw
    }

    private var track: some View {
        GeometryReader { geo in
            let span = max(1, geo.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                    .frame(height: 6)
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: frac(shown) * span + knob / 2, height: 6)
                ForEach(Array(hilights.enumerated()), id: \.offset) { _, sec in
                    RoundedRectangle(cornerRadius: 1.75)
                        .fill(Color.hiLight)
                        .frame(width: tickWidth, height: 17)
                        .offset(x: frac(sec) * span + (knob - tickWidth) / 2)
                        .help("HiLight at \(Fmt.duration(sec))")
                }
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .offset(x: frac(shown) * span)
                    .shadow(radius: 1)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = target(v.location.x, span: span) }
                    .onEnded { v in
                        let t = target(v.location.x, span: span)
                        scrub = nil
                        seek(t)
                    }
            )
        }
        .frame(height: 20)
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: playPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(isPlaying ? "Pause (space)" : "Play (space)")
            Text(Fmt.duration(shown))
                .font(.callout.monospacedDigit())
            track
            Text(Fmt.duration(duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .glassPill()
    }
}

/// AppKit AVPlayerView wrapper. SwiftUI's VideoPlayer is off-limits here: its
/// _AVKit_SwiftUI implementation fails to resolve AVPlayerView metadata at
/// runtime in this SwiftPM build and aborts the process (see repro in repo
/// history: "failed to demangle superclass of VideoPlayerView").
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        // TransportBar replaces these: AVKit's scrub bar can't carry the
        // HiLight marks, and two playback bars would be one too many.
        v.controlsStyle = .none
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct VideoPane: View {
    let entry: MediaEntry
    /// Reports the real picture shape once the asset loads, so the window can
    /// take it and drop the letterbox.
    let onAspect: (CGFloat) -> Void
    @EnvironmentObject var model: AppModel
    @State private var player: AVQueuePlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var timeObserver: Any?
    @State private var position: Double = 0
    @State private var itemDuration: Double = 0
    @State private var isPlaying = false

    private var chapters: [CameraFile] {
        if case .video(let c) = entry.kind { return c }
        return []
    }

    /// HiLight offsets are on the combined timeline, but AVQueuePlayer seeks
    /// don't cross chapter boundaries — so marks are single-chapter only. A
    /// chaptered clip still gets the bar, scrubbing the chapter it's playing.
    private var marks: [Double] {
        guard entry.chapterCount == 1, let mi = model.mediaInfo[entry.id],
              let d = mi.duration, d > 0, !mi.hilights.isEmpty else { return [] }
        return mi.hilights
    }

    /// The player knows the real duration once the asset loads; until then the
    /// camera's own figure keeps the timeline honest.
    private var timelineDuration: Double {
        if itemDuration.isFinite, itemDuration > 0 { return itemDuration }
        if entry.chapterCount == 1, let d = model.mediaInfo[entry.id]?.duration { return d }
        return 0
    }

    /// ⇧←/⇧→ seek 5 seconds — the bare arrows step between items now. A
    /// zero-size button is the only way to carry a shortcut with no glyph.
    private var seekShortcuts: some View {
        Group {
            Button("") { step(-5) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { step(5) }.keyboardShortcut(.rightArrow, modifiers: .shift)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    var body: some View {
        ZStack {
            if let player {
                PlayerView(player: player)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            seekShortcuts
        }
        .overlay(alignment: .bottom) {
            TransportBar(isPlaying: isPlaying,
                         position: position,
                         duration: timelineDuration,
                         hilights: marks,
                         playPause: playPause,
                         seek: seek)
                .frame(maxWidth: 880)
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
                .chromeFade()
        }
        // AVKit's controls are off, so the bar's play/pause glyph tracks the
        // player's own rate rather than what we last asked for.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayer.rateDidChangeNotification)) { _ in
            isPlaying = (player?.rate ?? 0) != 0
        }
        .onAppear {
            rebuild()
            // The grid usually fetched this already; do it here too so the
            // rail and the info line fill in for a clip whose cell never
            // appeared.
            model.fetchInfo(for: entry)
        }
        .onDisappear {
            player?.pause()
            dropObservers()
        }
    }

    private func dropObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func rebuild(autoplay: Bool = true) {
        dropObservers()
        player?.pause()
        position = 0
        itemDuration = 0
        guard !chapters.isEmpty else { return }
        // Always the camera's real file: the grid's thumbnails are the
        // low-quality view of a clip, and opening one is the ask for the
        // real thing. (The .LRV proxy is still what gets transferred when
        // Settings says to include proxies.)
        let items: [AVPlayerItem] = chapters.compactMap { ch in
            guard let url = model.mediaURL(ch) else { return nil }
            let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
            return AVPlayerItem(asset: asset)
        }
        guard !items.isEmpty else { return }
        let p = AVQueuePlayer(items: items)
        // When the last chapter finishes, AVQueuePlayer empties its queue and
        // the inline controls vanish — rebuild paused on the first frame so
        // the play button comes back and the clip can be replayed.
        if let last = items.last {
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: last, queue: .main
            ) { _ in
                rebuild(autoplay: false)
            }
        }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { t in
            position = t.seconds.isFinite ? t.seconds : 0
            let d = p.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 { itemDuration = d }
            // presentationSize already has the preferred transform applied,
            // so a vertical clip reports vertical.
            if let s = p.currentItem?.presentationSize, s.width > 0, s.height > 0 {
                onAspect(s.width / s.height)
            }
        }
        player = p
        isPlaying = autoplay
        if autoplay { p.play() }
    }

    private func playPause() {
        guard let player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
        isPlaying = player.rate != 0
    }

    private func step(_ delta: Double) {
        guard let player else { return }
        seek(to: player.currentTime().seconds + delta)
    }

    private func seek(to sec: Double) {
        let t = max(0, timelineDuration > 0 ? min(sec, timelineDuration) : sec)
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        position = t
    }
}

// MARK: - Photo

enum ZoomAction { case zoomIn, zoomOut, fit }

struct ZoomCommand: Equatable {
    let id: UUID
    let action: ZoomAction

    static func make(_ action: ZoomAction) -> ZoomCommand { ZoomCommand(id: UUID(), action: action) }
}

/// Keeps a document view smaller than the visible area centered instead of
/// pinned to the bottom-left corner (NSScrollView's default).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// An image view that resamples smoothly when it is drawn at anything other
/// than 1:1 — which is most of the time, since the camera's preview JPEG is
/// smaller than the window it fills.
final class SmoothImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        super.draw(dirtyRect)
    }
}

/// Scroll view that keeps the photo fitted — flush with the window's edges —
/// until the user zooms. Fit is a standing mode, not a one-shot
/// magnify(toFit:) on arrival: the window resizes itself to the photo's shape
/// asynchronously (ViewerWindowController.fit) and the pane slides in inside
/// a transition, so a single fit races both. Losing that race could run the
/// fit against a not-yet-laid-out scroll view, clamp magnification to the
/// minimum, and strand the photo tiny in the middle of the window for good.
/// Re-fitting on every layout pass makes the end state deterministic whatever
/// the order — and keeps the photo edge to edge through full screen and
/// window resizes too.
final class FitScrollView: NSScrollView {
    var fitMode = true

    override func layout() {
        super.layout()
        fitIfNeeded()
    }

    func fitIfNeeded() {
        guard fitMode, let doc = documentView,
              doc.frame.width > 0, doc.frame.height > 0 else { return }
        let box = contentView.frame.size
        guard box.width > 1, box.height > 1 else { return }
        let target = min(box.width / doc.frame.width, box.height / doc.frame.height)
        if abs(magnification - target) > 0.0005 { magnify(toFit: doc.frame) }
    }

    // A pinch (or a two-finger double-tap) is the user taking over; stop
    // re-fitting underneath their fingers.
    override func magnify(with event: NSEvent) {
        fitMode = false
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        fitMode = false
        super.smartMagnify(with: event)
    }
}

/// NSScrollView-backed image view: native trackpad pinch magnification,
/// scroll-to-pan, and programmatic zoom for the toolbar buttons.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let command: ZoomCommand?

    final class Coordinator {
        var lastImage: NSImage?
        var lastCommand: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FitScrollView {
        let sv = FitScrollView()
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .black
        sv.contentView = clip
        sv.allowsMagnification = true
        sv.minMagnification = 0.02
        sv.maxMagnification = 12
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = .black
        let iv = SmoothImageView()
        iv.imageScaling = .scaleNone
        // Magnification scales this view's layer rather than redrawing it, so
        // the filter has to be set on the layer as well as in draw(_:).
        iv.wantsLayer = true
        iv.layer?.magnificationFilter = .linear
        iv.layer?.minificationFilter = .trilinear
        sv.documentView = iv
        return sv
    }

    func updateNSView(_ sv: FitScrollView, context: Context) {
        guard let iv = sv.documentView as? NSImageView else { return }
        let co = context.coordinator

        if co.lastImage !== image {
            let oldSize = co.lastImage?.size
            co.lastImage = image
            iv.image = image
            iv.frame = NSRect(origin: .zero, size: image.size)
            if sv.fitMode {
                // layout() re-fits; ask for a pass now so the new image
                // never draws at the old one's scale.
                sv.needsLayout = true
                sv.fitIfNeeded()
            } else if let oldSize, oldSize.width > 0, image.size.width > 0 {
                // Swapping preview for full-res mid-zoom: keep the on-screen
                // size stable.
                let center = NSPoint(x: sv.contentView.bounds.midX, y: sv.contentView.bounds.midY)
                let scale = oldSize.width / image.size.width
                sv.setMagnification(sv.magnification * scale,
                                    centeredAt: NSPoint(x: center.x / scale, y: center.y / scale))
            }
        }

        if let command, co.lastCommand != command.id {
            co.lastCommand = command.id
            let center = NSPoint(x: sv.contentView.bounds.midX, y: sv.contentView.bounds.midY)
            switch command.action {
            case .zoomIn, .zoomOut:
                sv.fitMode = false
                let mag = command.action == .zoomIn ? sv.magnification * 1.5
                                                    : sv.magnification / 1.5
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    sv.animator().setMagnification(mag, centeredAt: center)
                }
            case .fit:
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    sv.animator().magnify(toFit: iv.frame)
                }, completionHandler: {
                    // Re-arm only once the animation lands, or the next
                    // layout pass would snap straight past it.
                    sv.fitMode = true
                })
            }
        }
    }
}

struct PhotoPane: View {
    let file: CameraFile
    let onAspect: (CGFloat) -> Void
    @EnvironmentObject var model: AppModel
    @State private var image: NSImage?
    @State private var fullLoaded = false
    @State private var loadingFull = false
    @State private var zoom: ZoomCommand?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImageView(image: image, command: zoom)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .bottom) { controls }
        .task(id: file.path) {
            if image == nil {
                switch model.source {
                case .mac:
                    // The file is on this disk; there is no reason to show a
                    // downscaled preview and a button to ask for the rest.
                    let url = URL(fileURLWithPath: file.path)
                    if let full = await Task.detached(priority: .userInitiated, operation: {
                        NSImage(contentsOf: url)
                    }).value {
                        image = full
                        fullLoaded = true
                    } else {
                        image = await model.thumbs.localImage(url: url, maxPixel: 2048,
                                                              sizeTag: file.size)
                    }
                case .camera:
                    if let client = model.client {
                        image = await model.thumbs.screennail(client: client, path: file.path,
                                                              sizeTag: file.size)
                    }
                }
            }
            if let s = image?.size, s.width > 0, s.height > 0 { onAspect(s.width / s.height) }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button { zoom = .make(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
            Button { zoom = .make(.fit) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .keyboardShortcut("0", modifiers: .command)
                .help("Fit to window (⌘0)")
            Button { zoom = .make(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+) — trackpad pinch works too")
            Divider().frame(height: 20)
            // Nothing to say once the real thing is on screen.
            if !fullLoaded {
                Button(loadingFull ? "Loading…" : "Load full resolution") { loadFull() }
                    .font(.system(size: 13))
                    .disabled(loadingFull || image == nil)
                    .opacity(loadingFull || image == nil ? 0.4 : 1)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.white)
        .frame(height: 22)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassPill()
        .padding(.bottom, 26)
        .chromeFade()
    }

    private func loadFull() {
        if model.source == .mac {
            // The file is right here; no need for the camera round trip.
            if let img = NSImage(contentsOf: URL(fileURLWithPath: file.path)) {
                image = img
                fullLoaded = true
            }
            return
        }
        guard let client = model.client else { return }
        loadingFull = true
        Task {
            if let data = try? await client.fileData(path: file.path),
               let img = NSImage(data: data) {
                image = img
                fullLoaded = true
            }
            loadingFull = false
        }
    }
}
