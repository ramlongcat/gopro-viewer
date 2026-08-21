import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// AppKit-backed click handling: SwiftUI's TapGesture can't reliably see
/// modifier keys, and Finder-style selection needs them.
///
/// Because this view sits on top of the whole cell, AppKit resolves the
/// cursor and the tooltip against it — `.help()` and cursor modifiers on the
/// SwiftUI views underneath never get a look in, so both live here. `hotRect`
/// is a sub-region (the transferred badge) that gets a tooltip of its own.
private struct ClickCatcher: NSViewRepresentable {
    var tooltip: String?
    var hotTooltip: String?
    var hotRect: CGRect = .zero
    /// Hover lives here too, for the same reason clicks and tooltips do: this
    /// view is on top, so SwiftUI's .onHover underneath is unreliable.
    var onHover: (Bool) -> Void = { _ in }
    let onClick: (NSEvent.ModifierFlags, Int, CGPoint, CGSize) -> Void

    final class CatcherView: NSView, NSViewToolTipOwner {
        var onClick: ((NSEvent.ModifierFlags, Int, CGPoint, CGSize) -> Void)?
        var onHover: ((Bool) -> Void)?
        var tooltip: String?
        var hotTooltip: String?
        var hotRect: CGRect = .zero
        private var hoverArea: NSTrackingArea?
        private var hovering = false
        override var isFlipped: Bool { true }

        override func mouseEntered(with event: NSEvent) { setHover(true) }

        override func mouseExited(with event: NSEvent) { setHover(false) }

        private func setHover(_ inside: Bool) {
            guard hovering != inside else { return }
            hovering = inside
            onHover?(inside)
        }

        /// The scroll-settle path must not trust `hovering`: tracking areas
        /// fire off NSView frames that SwiftUI's scrolling doesn't keep
        /// current, so a scroll strews phantom enters across cells while the
        /// scroll monitor stops their playback behind the flag's back —
        /// leaving the flag true and the preview dead. Reassert from
        /// scratch; re-entering a genuinely playing cell is a no-op
        /// (HoverPlayback.start guards a live player).
        func settleEnter() {
            hovering = true
            onHover?(true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A recycled cell must not keep a hover alive.
            if window == nil { setHover(false) } else { Self.live.add(self) }
        }

        /// Every attached cell, so scroll-settle can reconcile them all.
        static let live = NSHashTable<CatcherView>.weakObjects()

        /// After the last scroll event settles, the pointer may be resting on
        /// a different cell than the one it entered — and with no mouse
        /// movement, AppKit will never say so. One window hit-test picks the
        /// cell truly under the pointer: it routes through SwiftUI's own
        /// geometry, the only account of a scrolled layout that proved
        /// truthful (the NSView frames underneath once had 25 cells all
        /// claiming the pointer). Every other cell is reconciled to
        /// not-hovered, clearing the stale flags and pending starts a
        /// scroll's phantom enters leave behind — reconciliation lands
        /// inside the preview's 400 ms start delay, so a phantom can never
        /// reach playback.
        static let settleMonitor: Void = {
            var pending: Timer?
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                pending?.invalidate()
                let window = event.window
                let t = Timer(timeInterval: 0.25, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        guard let window, window.isKeyWindow else { return }
                        var hit = window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream)
                        while let view = hit, !(view is CatcherView) { hit = view.superview }
                        let target = hit as? CatcherView
                        for cell in live.allObjects where cell !== target {
                            cell.setHover(false)
                        }
                        target?.settleEnter()
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                pending = t
                return event
            }
            return ()
        }()

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onClick?(event.modifierFlags, event.clickCount, p, bounds.size)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            // .inVisibleRect keeps the area right as the grid scrolls under
            // a pointer that never moves.
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
            refresh()
        }

        /// One tooltip rect over the whole cell; the string is chosen per
        /// point so the badge can differ from the rest of the cell.
        func refresh() {
            removeAllToolTips()
            if tooltip != nil || hotTooltip != nil {
                addToolTip(bounds, owner: self, userData: nil)
            }
            window?.invalidateCursorRects(for: self)
        }

        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                  point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
            (hotRect.contains(point) ? hotTooltip : nil) ?? tooltip ?? ""
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        _ = CatcherView.settleMonitor
        let v = CatcherView()
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to v: CatcherView) {
        v.onClick = onClick
        v.onHover = onHover
        v.tooltip = tooltip
        v.hotTooltip = hotTooltip
        v.hotRect = hotRect
        v.refresh()
    }
}

struct MediaBrowserView: View {
    @EnvironmentObject var model: AppModel
    /// In the Mac library the "not copied yet" scope filters on what Google
    /// Photos holds, so a finished upload must re-run the grid's filter.
    @ObservedObject private var google = GooglePhotos.shared

    var body: some View {
        Group {
            if model.loadingMedia && model.entries.isEmpty {
                ProgressView("Reading media list…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = model.mediaError, model.entries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't read media", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Retry") { Task { await model.loadMedia() } }
                }
            } else if model.filteredEntries.isEmpty {
                // "Only items not copied yet" emptying the grid is good news,
                // not an empty card — say so, and say how to get back.
                if model.showScope == .notCopied, !model.typeFilteredEntries.isEmpty {
                    if model.source == .mac {
                        ContentUnavailableView("Everything is uploaded", systemImage: "checkmark.circle",
                                               description: Text("Every item here is already in Google Photos. Pick View ▸ Show ▸ All items to see them again."))
                    } else {
                        ContentUnavailableView("Everything is copied", systemImage: "checkmark.circle",
                                               description: Text("Every item here is already at the destination. Pick View ▸ Show ▸ All items to see them again."))
                    }
                } else {
                    ContentUnavailableView("No media", systemImage: "camera",
                                           description: Text("Nothing on the card matches this filter."))
                }
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 250), spacing: 12)],
                      spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            MediaCell(entry: entry)
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                                .font(.headline)
                            Spacer()
                            Text("\(section.entries.count) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        // Same backdrop as the toolbar strip above, so the
                        // pinned band reads as one piece with it. Bleeds into
                        // the grid's 14pt gutters: uncovered edge strips would
                        // let thumbnails scroll past beside the band.
                        .background {
                            Rectangle()
                                .fill(.headerBackdrop)
                                .padding(.horizontal, -14)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }
}

/// Muted, looping playback of a clip's proxy behind a grid cell, while the
/// pointer rests on it. The .LRV is the camera's own low-res copy — small
/// enough to start almost at once over USB, which is what makes a hover
/// preview feel instant. Opening the item is the ask for full quality.
@MainActor
final class HoverPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    /// Only revealed once a frame exists, so the thumbnail never blinks black.
    @Published private(set) var ready = false

    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var startTask: Task<Void, Never>?

    /// Every live instance, so one scroll can silence them all.
    private static let live = NSHashTable<HoverPlayback>.weakObjects()

    /// Scrolling ends every hover preview, straight from the event stream.
    /// This is deliberately blunt: hover is a relationship between a resting
    /// pointer and a cell, and scrolling moves the cell — but every polite
    /// way of noticing that from inside SwiftUI's scroller (tracking areas,
    /// clip-view notifications, AppKit view geometry) proved to lag or never
    /// fire, leaving previews playing on tiles the pointer had left.
    private static let scrollStops: Void = {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                for p in live.allObjects { p.stop() }
            }
            return event
        }
        return ()
    }()

    init() {
        _ = Self.scrollStops
        Self.live.add(self)
    }

    /// The delay is what keeps a cursor crossing the grid from opening a
    /// stream in every cell it passes over.
    func start(url: URL, after delay: Duration = .milliseconds(400)) {
        guard player == nil, startTask == nil else { return }
        startTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.begin(url: url)
        }
    }

    private func begin(url: URL) {
        // LRV files are plain MP4; the extension confuses AVFoundation
        // without a MIME hint.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { _ in
            p.seek(to: .zero)
            p.play()
        }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            if let err = item.error {
                AppLog.log("hover: \(url.lastPathComponent) failed — \(err.localizedDescription)")
            }
            if t.seconds > 0, self?.ready == false { self?.ready = true }
        }
        player = p
        p.play()
    }

    func stop() {
        // Every visible cell calls this on every scroll tick (geometry
        // change); publishing `player = nil` over and over would invalidate
        // the whole grid for nothing.
        guard startTask != nil || player != nil else { return }
        startTask?.cancel()
        startTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        ready = false
    }
}

/// AVPlayerLayer rather than AVPlayerView: only the layer can be told to fill
/// the cell the way the thumbnail behind it does.
struct HoverVideoView: NSViewRepresentable {
    let player: AVPlayer

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.magnificationFilter = .linear
            playerLayer.minificationFilter = .trilinear
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // A sublayer added by hand does not inherit the window's backing
        // scale, so on a Retina display the video would decode into a
        // half-resolution layer and arrive visibly pixelated.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyBackingScale()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            applyBackingScale()
        }

        private func applyBackingScale() {
            let scale = window?.backingScaleFactor ?? 2
            layer?.contentsScale = scale
            playerLayer.contentsScale = scale
        }

        override func layout() {
            super.layout()
            // The frame follows the cell; the implicit animation would let it
            // lag a resize by a beat.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView(frame: .zero)
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

struct MediaCell: View {
    let entry: MediaEntry
    @EnvironmentObject var model: AppModel
    // Observed directly: nested ObservableObjects don't republish through
    // AppModel, and the activity badge needs their per-chunk progress.
    @EnvironmentObject var transfers: TransferManager
    @ObservedObject private var google = GooglePhotos.shared
    @StateObject private var hover = HoverPlayback()
    @AppStorage(Prefs.kGridShowInfo) private var showInfo = false
    @State private var thumb: NSImage?
    /// Frame of the transferred badge, in cell coordinates, so the click
    /// catcher on top can give that corner its own tooltip.
    @State private var markRect: CGRect = .zero

    private static let space = "media-cell"

    private var selected: Bool { model.selection.contains(entry.id) }
    private var downloaded: Bool { model.isMarked(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            thumbBox
            // The name would only ever truncate at this width; it lives in
            // the cell's tooltip instead.
            HStack {
                Text(Fmt.time.string(from: entry.created))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
        }
        .coordinateSpace(name: Self.space)
        .contentShape(Rectangle())
        .overlay(ClickCatcher(tooltip: nil,
                              hotTooltip: downloaded ? model.markNote(for: entry) : nil,
                              hotRect: markRect,
                              onHover: { inside in
                                  if inside { startHoverPlay() } else { hover.stop() }
                              }) { modifiers, clickCount, _, _ in
            handleClick(modifiers: modifiers, clickCount: clickCount)
        })
        // A resting pointer can't follow a cell the scroll moves, so any
        // change to the cell's place on screen ends its hover preview. This
        // is SwiftUI's own layout talking — authoritative where the AppKit
        // overlay's frames and tracking areas lag a SwiftUI scroll, which is
        // how previews kept playing after their tile scrolled away.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
            hover.stop()
        }
        .contextMenu {
            Button("Open") { model.viewer = ViewerTarget(id: entry.id) }
            Button("Get Info") {
                model.selectionAnchor = entry.id
                withAnimation(.easeOut(duration: 0.2)) { showInfo = true }
            }
            if model.source == .mac {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.primary.path)])
                }
            }
            Button("Copy This File") { model.download(entry) }
                .disabled(model.transfers.isActive)
            if model.selection.count > 1 && model.selection.contains(entry.id) {
                Button("Copy All Selected Files (\(model.selection.count))") { model.downloadSelected() }
                    .disabled(model.transfers.isActive)
            }
            // The API can't ask the library what's already there (Google
            // closed reading in March 2025), so media that went up any other
            // way gets marked by hand.
            if model.source == .mac {
                let targets = model.selection.count > 1 && model.selection.contains(entry.id)
                    ? model.selectedEntries : [entry]
                let files = targets.flatMap { GooglePhotos.sendables(of: $0) }
                if !files.isEmpty {
                    let allUp = files.allSatisfy {
                        google.uploaded.contains(GooglePhotos.key(name: $0.name, size: $0.size))
                    }
                    let count = targets.count > 1 ? " (\(targets.count))" : ""
                    Divider()
                    Button(allUp ? "Mark as Not in Google Photos\(count)"
                                 : "Mark as Already in Google Photos\(count)") {
                        google.setUploaded(!allUp, files: files)
                    }
                }
            }
        }
        .task(id: entry.id) {
            await loadThumb()
            model.fetchInfo(for: entry)
        }
        .onDisappear { hover.stop() }
    }

    /// The camera sends a small thumbnail first and a larger preview on
    /// request; a local file is read straight off disk at tile size, then
    /// again at Retina size once the tile has stayed put.
    private func loadThumb() async {
        switch model.source {
        case .mac:
            let url = URL(fileURLWithPath: entry.primary.path)
            if thumb == nil {
                thumb = await model.thumbs.localImage(url: url, maxPixel: 480,
                                                      sizeTag: entry.primary.size)
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if let sharp = await model.thumbs.localImage(url: url, maxPixel: 1024,
                                                        sizeTag: entry.primary.size) {
                thumb = sharp
            }
        case .camera:
            guard let client = model.client else { return }
            if thumb == nil {
                thumb = await model.thumbs.thumbnail(client: client,
                                                     path: entry.primary.path,
                                                     sizeTag: entry.primary.size)
            }
            // Sharper image for a tile that stays on screen; scrolling past
            // cancels the task before it costs anything.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if entry.isVideo {
                // Videos have no screennail to ask for, so the frame comes
                // out of the proxy stream instead.
                guard let proxy = entry.proxyPath else { return }
                if let sharp = await model.thumbs.videoFrame(url: client.downloadURL(path: proxy),
                                                             maxPixel: 900,
                                                             sizeTag: entry.primary.size,
                                                             cacheKey: client.cacheKey) {
                    thumb = sharp
                }
            } else if let sharp = await model.thumbs.gridImage(client: client,
                                                               path: entry.primary.path,
                                                               sizeTag: entry.primary.size) {
                thumb = sharp
            }
        }
    }

    /// Hover-play needs the camera's attention, which a running transfer owns
    /// outright (it puts the camera in turbo mode).
    private func startHoverPlay() {
        // No proxy (photos, and some video modes) means nothing to preview.
        // On the camera a running copy owns the link outright; a local file
        // is always readable.
        guard let url = model.hoverURL(entry) else { return }
        guard model.source == .mac || !model.transfers.isActive else { return }
        hover.start(url: url)
    }

    private func handleClick(modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        if clickCount >= 2 {
            model.viewer = ViewerTarget(id: entry.id)
            return
        }
        model.handleCellClick(entry.id, modifiers: modifiers)
    }

    private var thumbBox: some View {
        // The image lives in an overlay so its size can never leak into
        // layout: a filled image of any aspect ratio (8:7 stills, vertical
        // video) would otherwise inflate the cell and overlap neighbors.
        Rectangle()
            .fill(Color.secondary.opacity(0.14))
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        // The camera's thumbnail is smaller than a Retina cell,
                        // so it is always being scaled up: say how, or it
                        // arrives blocky.
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFill()
                } else {
                    Image(systemName: entry.isVideo ? "video" : "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            // Over the thumbnail, and only once it has a frame to show, so
            // the cell never blinks black on the way in.
            .overlay {
                if let p = hover.player {
                    HoverVideoView(player: p)
                        .opacity(hover.ready ? 1 : 0)
                        .animation(.easeIn(duration: 0.2), value: hover.ready)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .bottomLeading) { badges }
            .overlay(alignment: .bottomTrailing) { downloadedMark }
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
            )
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if entry.isVideo {
                badge {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        if let d = model.mediaInfo[entry.id]?.duration {
                            Text(Fmt.duration(d))
                        }
                    }
                }
                if entry.chapterCount > 1 {
                    badge { Text("\(entry.chapterCount) ch") }
                }
            }
            if let n = entry.groupCount {
                badge {
                    HStack(spacing: 3) {
                        Image(systemName: "square.stack").font(.system(size: 8))
                        Text("\(n)")
                    }
                }
            }
            if entry.primary.hasRaw {
                badge { Text("RAW") }
            }
        }
        .padding(5)
    }

    /// Live "this very tile is moving" caption, if it is. Only the file
    /// actually in flight gets one — queued neighbours stay quiet, the
    /// sidebar already tells the batch story.
    private var activityText: String? {
        if model.source == .camera,
           let job = transfers.jobs.first(where: { $0.entryID == entry.id && $0.state == .running }) {
            guard let size = job.file.size, size > 0 else { return "Copying…" }
            return "Copying… \(Int(min(1, Double(transfers.currentFileBytes) / Double(size)) * 100))%"
        }
        if model.source == .mac, google.sending,
           GooglePhotos.sendables(of: entry)
               .contains(where: { GooglePhotos.key(name: $0.name, size: $0.size) == google.sendingKey }) {
            return "Uploading… \(Int((google.sendingFraction * 100).rounded()))%"
        }
        return nil
    }

    private func badge(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
    }

    /// Same capsule as the duration badge — a green glyph straight on the
    /// thumbnail had no contrast against bright or busy frames.
    ///
    /// While this very tile is being copied or uploaded, the capsule carries
    /// the live percentage instead — one persistent badge in one corner, so
    /// finishing reads as it settling into the tick / cloud rather than a
    /// second badge appearing elsewhere.
    @ViewBuilder
    private var downloadedMark: some View {
        let activity = activityText
        if activity != nil || downloaded {
            badge {
                if let activity {
                    Text(activity)
                        .transition(.opacity)
                } else if model.source == .mac {
                    // A cloud, not any one provider's mark: on this Mac the
                    // badge means "in your photo cloud", so another storage
                    // service can join Google Photos without the UI changing.
                    Text(Image(systemName: "cloud.fill")).fontWeight(.bold)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    // Text(Image:) rather than a bare Image: the glyph then
                    // uses the badge font's line metrics, so this capsule is
                    // exactly as tall as the duration one.
                    Text(Image(systemName: "checkmark")).fontWeight(.bold)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(5)
            .background(GeometryReader { g in
                let r = g.frame(in: .named(Self.space))
                Color.clear
                    .onAppear { markRect = r }
                    .onChange(of: r) { _, new in markRect = new }
            })
            .help(activity ?? model.markNote(for: entry))
            // One transaction for the swap, so the capsule's width glides
            // down onto the glyph instead of snapping.
            .animation(.easeOut(duration: 0.3), value: activity == nil)
        }
    }
}
