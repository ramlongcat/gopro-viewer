import SwiftUI
import UniformTypeIdentifiers

struct FolderPickerButton: View {
    var title = "Change…"
    @AppStorage(Prefs.kDestination) private var destinationPath = ""
    @State private var showing = false

    var body: some View {
        Button(title) { showing = true }
            .fileImporter(isPresented: $showing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    destinationPath = url.path
                }
            }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.kDestination) private var destinationPath = ""
    @AppStorage(Prefs.kOrganize) private var organizeByDay = true
    @AppStorage(Prefs.kFolderPattern) private var folderPattern = "YYYYMMDD"

    private func radioRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(label)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func destinationDetail(buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(displayPath)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .foregroundStyle(.secondary)
            HStack {
                FolderPickerButton(title: buttonTitle)
                Button("Reveal") {
                    try? FileManager.default.createDirectory(at: Prefs.destination, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([Prefs.destination])
                }
            }
            .controlSize(.small)
        }
        .padding(.leading, 22)
        .opacity(0.8)
    }

    /// Auto mode shows base + pattern as one path ("~/Desktop/YYYYMMDD");
    /// custom mode shows the picked folder as-is.
    private var displayPath: String {
        var p = Prefs.destination.path
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        if organizeByDay {
            let pat = folderPattern.trimmingCharacters(in: .whitespaces)
            p += "/" + (pat.isEmpty ? "YYYYMMDD" : pat)
        }
        return p
    }

    private func count(_ f: MediaFilter) -> Int {
        model.entries.filter { f.matches($0) }.count
    }

    private func icon(_ f: MediaFilter) -> String {
        switch f {
        case .all: return "square.grid.2x2"
        case .videos: return "video"
        case .photos: return "photo"
        }
    }

    private func batterySymbol(_ pct: Int?) -> String {
        switch pct ?? 0 {
        case 85...: return "battery.100percent"
        case 60..<85: return "battery.75percent"
        case 35..<60: return "battery.50percent"
        case 12..<35: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var body: some View {
        List {
            Section("Camera") { cameraCard }
            Section("Show") {
                ForEach(MediaFilter.allCases) { f in
                    HStack {
                        Label(f.rawValue, systemImage: icon(f))
                        Spacer()
                        if model.filter == f {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        } else {
                            Text("\(count(f))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.filter = f }
                }
            }
            Section("Destination") {
                VStack(alignment: .leading, spacing: 8) {
                    radioRow("Auto — organize by day", selected: organizeByDay) { organizeByDay = true }
                    if organizeByDay {
                        destinationDetail(buttonTitle: "Change Base…")
                    }
                    radioRow("Custom folder", selected: !organizeByDay) { organizeByDay = false }
                    if !organizeByDay {
                        destinationDetail(buttonTitle: "Choose Folder…")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: destinationPath) { Task { await model.refreshDownloaded() } }
        .onChange(of: organizeByDay) { Task { await model.refreshDownloaded() } }
        .onChange(of: folderPattern) { Task { await model.refreshDownloaded() } }
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "web.camera")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.info?.modelName ?? "GoPro")
                        .font(.headline)
                    if let fw = model.info?.firmware, !fw.isEmpty {
                        Text(fw)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let s = model.status {
                HStack(spacing: 6) {
                    Image(systemName: batterySymbol(s.batteryPercent))
                    if let pct = s.batteryPercent {
                        Text("\(pct)%")
                            .font(.callout)
                    }
                    if s.encoding {
                        Label("REC", systemImage: "record.circle")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                    } else if s.busy {
                        Text("Busy")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let rem = s.sdRemainingKB {
                    VStack(alignment: .leading, spacing: 4) {
                        if let cap = s.sdCapacityKB, cap > 0 {
                            ProgressView(value: Double(cap - rem) / Double(cap))
                                .controlSize(.small)
                            Text("\(Fmt.size(rem * 1024)) free of \(Fmt.size(cap * 1024))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(Fmt.size(rem * 1024)) free")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
