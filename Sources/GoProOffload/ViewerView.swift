import AVFoundation
import AVKit
import QuartzCore
import SwiftUI

struct ViewerView: View {
    let targetID: String
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transfers: TransferManager
    @State private var slideDir = 1

    var body: some View {
        let entry = model.entry(for: targetID)
        VStack(spacing: 0) {
            header(entry)
            Divider()
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
        }
        .frame(minWidth: 980, minHeight: 640)
        // Arrows stay free for the video player's seeking; navigation lives on < >.
        .onKeyPress { press in
            switch press.characters {
            case ",", "<": navigate(-1); return .handled
            case ".", ">": navigate(1); return .handled
            default: return .ignored
            }
        }
    }

    private func navigate(_ delta: Int) {
        slideDir = delta
        withAnimation(.easeOut(duration: 0.28)) {
            model.viewerNeighbor(delta)
        }
    }

    private func header(_ entry: MediaEntry?) -> some View {
        HStack(spacing: 10) {
            Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous (< or ,)")
                .disabled(model.viewerPosition()?.0 == 1)
            Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                .help("Next (> or .)")
                .disabled({ let p = model.viewerPosition(); return p == nil || p!.0 == p!.1 }())
            if let p = model.viewerPosition() {
                Text("\(p.0) of \(p.1)")
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let entry {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName).font(.headline)
                    Text(Fmt.full.string(from: entry.created))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let line = infoLine(entry), !line.isEmpty {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 6)
            }
            Spacer()
            if let entry {
                if let s = entry.totalSize {
                    Text(Fmt.size(s))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.downloadedIDs.contains(entry.id) {
                    Label("Transferred", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                Button {
                    model.download(entry)
                } label: {
                    Label("Transfer This File", systemImage: "square.and.arrow.down")
                }
                .help("Transfers only the item shown here — use the grid's Transfer button for a selection")
                .disabled(transfers.isActive)
            }
            Button("Done") { model.viewer = nil }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    @ViewBuilder
    private func content(_ entry: MediaEntry) -> some View {
        switch entry.kind {
        case .video:
            VideoPane(entry: entry).id(entry.id)
        case .photo(let f):
            PhotoPane(file: f, note: nil).id(entry.id)
        case .photoGroup(let f):
            PhotoPane(file: f, note: groupNote(f)).id(entry.id)
        case .other(let f):
            VStack(spacing: 10) {
                Image(systemName: "doc").font(.largeTitle)
                Text(f.name)
            }
            .foregroundStyle(.white)
        }
    }

    private func groupNote(_ f: CameraFile) -> String {
        let g = f.group
        return "\(g?.typeName ?? "Group") of \(g?.count ?? 0) — showing the first frame; Download fetches every shot"
    }

    private func infoLine(_ entry: MediaEntry) -> String? {
        guard entry.isVideo, let mi = model.mediaInfo[entry.id] else { return nil }
        var parts: [String] = []
        if let w = mi.width, let h = mi.height { parts.append("\(w)×\(h)") }
        if let f = mi.fps { parts.append(String(format: "%.2f fps", f)) }
        if let e = mi.eis { parts.append(e ? "HyperSmooth on" : "HyperSmooth off") }
        if !mi.hilights.isEmpty {
            parts.append("★ \(mi.hilights.count) HiLight\(mi.hilights.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Video

/// AppKit AVPlayerView wrapper. SwiftUI's VideoPlayer is off-limits here: its
/// _AVKit_SwiftUI implementation fails to resolve AVPlayerView metadata at
/// runtime in this SwiftPM build and aborts the process (see repro in repo
/// history: "failed to demangle superclass of VideoPlayerView").
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct VideoPane: View {
    let entry: MediaEntry
    @EnvironmentObject var model: AppModel
    @State private var player: AVQueuePlayer?
    @State private var useProxy = Prefs.preferProxy

    private var chapters: [CameraFile] {
        if case .video(let c) = entry.kind { return c }
        return []
    }

    private var proxyAvailable: Bool {
        chapters.contains { $0.lrvSize != nil && $0.lrvName != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let player {
                PlayerView(player: player)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if proxyAvailable {
                    Picker("", selection: $useProxy) {
                        Text("Proxy").tag(true)
                        Text("Full quality").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .help("Proxy streams the camera's low-res .LRV — smoother over USB")
                }
                if entry.chapterCount > 1 {
                    Text("\(entry.chapterCount) chapters play in sequence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // HiLight jump chips (single-chapter only: AVQueuePlayer seeks
                // don't cross chapter boundaries).
                if entry.chapterCount == 1,
                   let hilights = model.mediaInfo[entry.id]?.hilights, !hilights.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        ForEach(Array(hilights.prefix(10).enumerated()), id: \.offset) { _, sec in
                            Button(Fmt.duration(sec)) {
                                player?.seek(to: CMTime(seconds: sec, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                            .buttonStyle(.link)
                            .font(.caption.monospacedDigit())
                        }
                    }
                    .help("HiLight tags — click to jump to the tagged moment")
                }
                Spacer()
                Text("Streaming from camera")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(.black)
        }
        .onAppear { rebuild() }
        .onChange(of: useProxy) { rebuild() }
        .onDisappear { player?.pause() }
    }

    private func rebuild() {
        player?.pause()
        guard let client = model.client else { return }
        let proxy = useProxy && proxyAvailable
        let items: [AVPlayerItem] = chapters.map { ch in
            var path = ch.path
            if proxy, let lrv = ch.lrvName, ch.lrvSize != nil {
                path = "\(ch.folder)/\(lrv)"
            }
            // LRV files are plain MP4; the extension confuses AVFoundation without a MIME hint.
            let asset = AVURLAsset(url: client.downloadURL(path: path),
                                   options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
            return AVPlayerItem(asset: asset)
        }
        let p = AVQueuePlayer(items: items)
        player = p
        p.play()
    }
}

// MARK: - Photo

enum ZoomAction { case zoomIn, zoomOut, fit }

struct ZoomCommand: Equatable {
    let id: UUID
    let action: ZoomAction

    static func make(_ action: ZoomAction) -> ZoomCommand { ZoomCommand(id: UUID(), action: action) }
}

/// NSScrollView-backed image view: native trackpad pinch magnification,
/// scroll-to-pan, and programmatic zoom for the toolbar buttons.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let command: ZoomCommand?

    final class Coordinator {
        var lastImage: NSImage?
        var lastCommand: UUID?
        var didInitialFit = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.allowsMagnification = true
        sv.minMagnification = 0.02
        sv.maxMagnification = 12
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = .black
        let iv = NSImageView()
        iv.imageScaling = .scaleNone
        sv.documentView = iv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let iv = sv.documentView as? NSImageView else { return }
        let co = context.coordinator

        if co.lastImage !== image {
            let oldSize = co.lastImage?.size
            co.lastImage = image
            iv.image = image
            iv.frame = NSRect(origin: .zero, size: image.size)
            if !co.didInitialFit {
                co.didInitialFit = true
                DispatchQueue.main.async { sv.magnify(toFit: iv.frame) }
            } else if let oldSize, oldSize.width > 0, image.size.width > 0 {
                // Swapping preview for full-res: keep the on-screen size stable.
                let center = NSPoint(x: sv.contentView.bounds.midX, y: sv.contentView.bounds.midY)
                let scale = oldSize.width / image.size.width
                sv.setMagnification(sv.magnification * scale,
                                    centeredAt: NSPoint(x: center.x / scale, y: center.y / scale))
            }
        }

        if let command, co.lastCommand != command.id {
            co.lastCommand = command.id
            let center = NSPoint(x: sv.contentView.bounds.midX, y: sv.contentView.bounds.midY)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                switch command.action {
                case .zoomIn: sv.animator().setMagnification(sv.magnification * 1.5, centeredAt: center)
                case .zoomOut: sv.animator().setMagnification(sv.magnification / 1.5, centeredAt: center)
                case .fit: sv.animator().magnify(toFit: iv.frame)
                }
            }
        }
    }
}

struct PhotoPane: View {
    let file: CameraFile
    let note: String?
    @EnvironmentObject var model: AppModel
    @State private var image: NSImage?
    @State private var fullLoaded = false
    @State private var loadingFull = false
    @State private var zoom: ZoomCommand?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    ZoomableImageView(image: image, command: zoom)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ControlGroup {
                    Button { zoom = .make(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                        .keyboardShortcut("-", modifiers: .command)
                        .help("Zoom out (⌘−)")
                    Button { zoom = .make(.fit) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .keyboardShortcut("0", modifiers: .command)
                        .help("Fit to window (⌘0)")
                    Button { zoom = .make(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                        .keyboardShortcut("=", modifiers: .command)
                        .help("Zoom in (⌘+) — trackpad pinch works too")
                }
                .frame(width: 130)
                if fullLoaded {
                    Text("Full resolution")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(loadingFull ? "Loading…" : "Load full resolution") { loadFull() }
                        .disabled(loadingFull || image == nil)
                }
            }
            .padding(8)
            .background(.black)
        }
        .task(id: file.path) {
            if image == nil, let client = model.client {
                image = await model.thumbs.screennail(client: client, path: file.path, sizeTag: file.size)
            }
        }
    }

    private func loadFull() {
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
