import AppKit
import SwiftUI

/// AppKit-backed click handling: SwiftUI's TapGesture can't reliably see
/// modifier keys, and Finder-style selection needs them.
private struct ClickCatcher: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags, Int, CGPoint, CGSize) -> Void

    final class CatcherView: NSView {
        var onClick: ((NSEvent.ModifierFlags, Int, CGPoint, CGSize) -> Void)?
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onClick?(event.modifierFlags, event.clickCount, p, bounds.size)
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onClick = onClick
    }
}

struct MediaBrowserView: View {
    @EnvironmentObject var model: AppModel

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
                ContentUnavailableView("No media", systemImage: "camera",
                                       description: Text("Nothing on the card matches this filter."))
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
                        .background(.background.opacity(0.94))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }
}

struct MediaCell: View {
    let entry: MediaEntry
    @EnvironmentObject var model: AppModel
    @State private var thumb: NSImage?
    @State private var hovering = false

    private var selected: Bool { model.selection.contains(entry.id) }
    private var downloaded: Bool { model.downloadedIDs.contains(entry.id) }

    private var sizeText: String {
        if let s = entry.totalSize { return Fmt.size(s) }
        if let n = entry.groupCount { return "\(n) shots" }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            thumbBox
            HStack {
                Text(entry.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Fmt.time.string(from: entry.created))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            HStack {
                Text(sizeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(ClickCatcher { modifiers, clickCount, point, size in
            handleClick(modifiers: modifiers, clickCount: clickCount, point: point, size: size)
        })
        .contextMenu {
            Button("Open") { model.viewer = ViewerTarget(id: entry.id) }
            Button("Transfer This File") { model.download(entry) }
                .disabled(model.transfers.isActive)
            if model.selection.count > 1 && model.selection.contains(entry.id) {
                Button("Transfer All Selected Files (\(model.selection.count))") { model.downloadSelected() }
                    .disabled(model.transfers.isActive)
            }
        }
        .task(id: entry.id) {
            if thumb == nil, let client = model.client {
                thumb = await model.thumbs.thumbnail(client: client,
                                                    path: entry.primary.path,
                                                    sizeTag: entry.primary.size)
            }
            model.fetchInfo(for: entry)
        }
    }

    private func handleClick(modifiers: NSEvent.ModifierFlags, clickCount: Int, point: CGPoint, size: CGSize) {
        if clickCount >= 2 {
            model.viewer = ViewerTarget(id: entry.id)
            return
        }
        // The top-right selection circle toggles (Photos-style) instead of replacing.
        let inCircle = point.x > size.width - 38 && point.y < 38
        if inCircle && modifiers.isDisjoint(with: [.command, .shift]) {
            model.handleCellClick(entry.id, modifiers: .command)
        } else {
            model.handleCellClick(entry.id, modifiers: modifiers)
        }
    }

    private var thumbBox: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.14))
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: entry.isVideo ? "video" : "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .bottomLeading) { badges }
        .overlay(alignment: .topTrailing) { selectionMark }
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
                if let stars = model.mediaInfo[entry.id]?.hilights.count, stars > 0 {
                    badge { Text("★\(stars)") }
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

    private func badge(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
    }

    @ViewBuilder
    private var selectionMark: some View {
        if selected || hovering {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : .white)
                .background(Circle().fill(.white.opacity(selected ? 0.9 : 0.001)).padding(2))
                .shadow(radius: 2)
                .padding(6)
        }
    }

    @ViewBuilder
    private var downloadedMark: some View {
        if downloaded {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.white, .green)
                .shadow(radius: 1)
                .padding(6)
                .help("Already at destination")
        }
    }
}
