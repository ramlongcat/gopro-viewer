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
    @EnvironmentObject var transfers: TransferManager
    @AppStorage(Prefs.kDestination) private var destinationPath = ""
    @AppStorage(Prefs.kOrganize) private var organizeByDay = true
    @AppStorage(Prefs.kFolderPattern) private var folderPattern = "YYYYMMDD"
    @AppStorage("sidebarWidth") private var sidebarWidth = 255.0
    @State private var macPower: LocalLibrary.MacPower?
    @ObservedObject private var google = GooglePhotos.shared

    private func batterySymbol(_ pct: Int?, charging: Bool) -> String {
        // Only the full symbol has a bolt variant, so a charging camera below
        // 100% keeps its level glyph and says "Charging" underneath instead.
        if charging, (pct ?? 0) >= 85 { return "battery.100percent.bolt" }
        switch pct ?? 0 {
        case 85...: return "battery.100percent"
        case 60..<85: return "battery.75percent"
        case 35..<60: return "battery.50percent"
        case 12..<35: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var body: some View {
        // Flat, App Store-style sidebar: the picker, then a stack of cards on
        // the sidebar material — no List chrome or divider lines.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sourcePicker
                    // The picker is a control, not a card; the extra air keeps
                    // it from reading as the first card of the stack.
                    .padding(.bottom, 10)
                SidebarCalendar()
                deviceCard
                syncCard
            }
            .padding(.horizontal, 12)   // same inset as the action slot below
            .padding(.bottom, 12)
            .padding(.top, 58)   // clear the standard traffic lights, plus breathing room
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Actions only — progress and gauges live in the cards. A fixed
            // height keeps the button pinned in place whether or not a
            // selection has summoned one.
            actionSlot
                .frame(height: 68)
                .padding(12)
        }
        .task {
            // Power state changes don't publish anything on their own.
            while !Task.isCancelled {
                macPower = LocalLibrary.power()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onChange(of: destinationPath) { Task { await model.refreshDownloaded() } }
        .onChange(of: organizeByDay) { Task { await model.refreshDownloaded() } }
        .onChange(of: folderPattern) { Task { await model.refreshDownloaded() } }
    }

    /// Whatever the current selection makes possible, in a slot that is
    /// always the same height.
    @ViewBuilder private var actionSlot: some View {
        if model.source == .mac {
            uploadActions
        } else if !pendingSelection.isEmpty, !transfers.isActive {
            // While a copy runs the Sync Status card tells the story; a
            // disabled button under it was just noise.
            copyBlock
        } else {
            Color.clear
        }
    }

    /// Local files that Google Photos hasn't been sent yet.
    private func pendingUploads(_ entries: [MediaEntry]) -> [(url: URL, size: Int64)] {
        entries.flatMap(GooglePhotos.sendables(of:))
            .filter { !google.uploaded.contains(GooglePhotos.key(name: $0.name, size: $0.size)) }
            .map { (URL(fileURLWithPath: $0.path), $0.size) }
    }

    /// The Sync Status card's live state while a batch is going up: the file
    /// in flight, its bar, and a cancel.
    private var uploadProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Same spinner as the location panel while it reads GPS.
                ProgressView()
                    .controlSize(.small)
                Text("Uploading \(min(google.sentCount + 1, google.sendTotal)) of \(google.sendTotal)")
                    .font(.callout)
                Spacer(minLength: 4)
                Button { google.cancelUpload() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop uploading")
            }
            Text(google.sendingName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            // Whole files done plus the fraction of the one in flight,
            // so the bar moves during a long clip instead of per file.
            ProgressView(value: min(Double(max(1, google.sendTotal)),
                                    Double(google.sentCount) + google.sendingFraction),
                         total: Double(max(1, google.sendTotal)))
                .controlSize(.small)
        }
    }

    /// The local source's primary action: send what's selected to Google
    /// Photos, or offer the folder when there's nothing to send. Actions
    /// only — while a batch runs the slot stays empty, because the Sync
    /// Status card already carries the progress and the cancel.
    @ViewBuilder private var uploadActions: some View {
        let pending = pendingUploads(model.selectedEntries)
        if google.sending {
            Color.clear
        } else if !google.isSignedIn {
            VStack(spacing: 7) {
                Button {
                    Task { await google.signIn() }
                } label: {
                    Label(google.busy ? "Signing in…" : "Connect Google Photos",
                          systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(google.busy)
                // The action slot has a fixed height, so a failure takes the
                // caption's place rather than growing the sidebar. Without
                // this the browser said "signed in" while the app showed the
                // same button again and nothing else.
                if let err = google.lastError, !google.busy {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(err)
                } else {
                    Text("Then selected items can be uploaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !pending.isEmpty {
            VStack(spacing: 7) {
                Button {
                    google.beginUpload(pending)
                } label: {
                    (Text("\(Image(systemName: "arrow.up.circle"))  ")
                        + Text("Upload \(pending.count) File\(pending.count == 1 ? "" : "s")"))
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if let err = google.lastError {
                    // A failed upload used to vanish without a word — the bar
                    // just stopped and reset. Say what went wrong, where the
                    // user is looking.
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(err)
                } else {
                    Text("to Google Photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([Prefs.destination])
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    /// Selected items that aren't at the destination yet — the only ones a
    /// copy would actually fetch, so the button hides when there are none.
    private var pendingSelection: [MediaEntry] {
        model.selectedEntries.filter { !model.downloadedIDs.contains($0.id) }
    }

    /// Wide primary action pinned at the sidebar bottom, with a caption that
    /// says what a click will do. Never rendered while a copy runs — the
    /// action slot hides it in favour of the Sync Status card.
    private var copyBlock: some View {
        let pending = pendingSelection
        let bytes = pending.compactMap(\.totalSize).reduce(0, +)
        let n = pending.count
        return VStack(spacing: 7) {
            Button {
                model.downloadSelected()
            } label: {
                (Text("\(Image(systemName: "square.and.arrow.down"))  ")
                    + Text("Copy \(n) Item\(n == 1 ? "" : "s")"))
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(bytes > 0 ? "\(Fmt.size(bytes)) to this Mac" : "to this Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var charging: Bool {
        (model.poweredOverUSB || model.batteryRising) && (model.status?.batteryPercent ?? 100) < 100
    }

    /// Battery and storage for whichever device is the source, in one card.
    /// Hidden entirely when there is nothing to report — an empty card reads
    /// as a bug.
    @ViewBuilder private var deviceCard: some View {
        if hasDeviceRows {
            SidebarCard(title: "Device") {
                VStack(alignment: .leading, spacing: 14) {
                    if model.source == .mac { macMetrics } else { cameraMetrics }
                }
            }
        }
    }

    private var hasDeviceRows: Bool {
        model.source == .mac
            ? macPower != nil || model.localSpace != nil
            : model.status?.batteryPercent != nil || model.status?.sdRemainingKB != nil
    }

    /// How much of what's here has reached the other side — copied to this
    /// Mac, or sent to Google Photos — joined by the live progress while a
    /// copy or upload is actually running.
    @ViewBuilder private var syncCard: some View {
        if model.source == .mac {
            if google.isSignedIn {
                SidebarCard(title: "Sync Status") {
                    VStack(alignment: .leading, spacing: 12) {
                        googleMetric
                        if google.sending { uploadProgress }
                    }
                }
            }
        } else if model.connState == .connected {
            SidebarCard(title: "Sync Status") {
                VStack(alignment: .leading, spacing: 12) {
                    copyMetric
                    if transfers.phase != .idle { SidebarTransferStatus() }
                }
            }
        }
    }

    @ViewBuilder private var cameraMetrics: some View {
        if let s = model.status {
            if let pct = s.batteryPercent {
                SidebarMetric(icon: batterySymbol(pct, charging: charging),
                              title: "Battery",
                              value: "\(pct)%",
                              fraction: Double(pct) / 100,
                              tint: pct <= 15 && !charging ? .red : .accentColor,
                              subtitle: batteryNote(pct))
            }
            if let rem = s.sdRemainingKB, let cap = s.sdCapacityKB, cap > 0 {
                // Free space and capacity come from two separate camera
                // status fields and don't have to agree — firmware can
                // report more free than the card holds. Clamp, or the
                // gauge reads "103% used" and "-248 MB free".
                let free = max(0, min(rem, cap))
                let used = Double(cap - free) / Double(cap)
                SidebarMetric(icon: "sdcard",
                              title: "Memory Card",
                              value: "\(Int((used * 100).rounded()))% used",
                              fraction: used,
                              subtitle: "\(Fmt.size(free * 1024)) free of \(Fmt.size(cap * 1024))")
            } else if let rem = s.sdRemainingKB, rem > 0 {
                SidebarMetric(icon: "sdcard", title: "Memory Card", value: "",
                              fraction: 0, subtitle: "\(Fmt.size(rem * 1024)) free")
            }
        }
    }

    /// This Mac has no battery or card to report on; what matters is the
    /// volume the library sits on and how much of it the library takes.
    @ViewBuilder private var macMetrics: some View {
        if let p = macPower {
            SidebarMetric(icon: batterySymbol(p.percent, charging: p.charging),
                          title: "Battery",
                          value: "\(p.percent)%",
                          fraction: Double(p.percent) / 100,
                          tint: p.percent <= 15 && !p.charging ? .red : .accentColor,
                          subtitle: macBatteryNote(p))
        }
        if let space = model.localSpace {
            SidebarMetric(icon: "internaldrive",
                          title: "Disk",
                          value: "\(Int((Double(space.total - space.free) / Double(space.total) * 100).rounded()))% used",
                          fraction: Double(space.total - space.free) / Double(space.total),
                          subtitle: "\(Fmt.size(space.free)) free of \(Fmt.size(space.total))")
        }
    }

    private func batteryNote(_ pct: Int) -> String {
        if pct >= 100 { return model.poweredOverUSB ? "Fully charged" : "Full" }
        guard charging else { return "On its own battery" }
        if let secs = model.batteryTimeToFull {
            return "Charging — \(Fmt.roughDuration(secs)) to full"
        }
        // The estimate comes from watching the percentage climb, so it can't
        // exist until it has climbed once.
        return "Charging — estimating time to full…"
    }

    /// How much of what's here has been sent to Google Photos.
    @ViewBuilder private var googleMetric: some View {
        // Nothing to report until an account is connected; an "Off" row was
        // just clutter.
        if google.isSignedIn {
            let all = model.entries.flatMap(GooglePhotos.sendables(of:))
            let done = all.filter {
                google.uploaded.contains(GooglePhotos.key(name: $0.name, size: $0.size))
            }.count
            let fraction = all.isEmpty ? 0 : Double(done) / Double(all.count)
            // Floored, not rounded: 999 of 1000 is not "100%", and a gauge
            // that says everything is up while an item is missing is a lie.
            // A cloud rather than the provider's logo, so another photo
            // service can join Google Photos without the UI changing.
            SidebarMetric(icon: "cloud",
                          title: "Uploaded to Google Photos",
                          value: "\(Int(fraction * 100))%",
                          fraction: fraction,
                          subtitle: "\(done) of \(all.count) files")
        }
    }

    private func macBatteryNote(_ p: LocalLibrary.MacPower) -> String {
        if p.charged || (p.onAC && p.percent >= 100) { return "Fully charged" }
        if p.charging {
            if let secs = p.toFull { return "Charging — \(Fmt.roughDuration(secs)) to full" }
            return "Charging — estimating time to full…"
        }
        if p.onAC { return "Plugged in" }
        if let secs = p.toEmpty { return "On battery — \(Fmt.roughDuration(secs)) left" }
        return "On battery"
    }

    /// Scope follows the selection when there is one, like the old status line.
    private var copyMetric: some View {
        let selected = model.selectedEntries
        let scope = selected.isEmpty ? model.typeFilteredEntries : selected
        let copied = scope.filter { model.downloadedIDs.contains($0.id) }.count
        let fraction = scope.isEmpty ? 0 : Double(copied) / Double(scope.count)
        let left = scope.filter { !model.downloadedIDs.contains($0.id) }
            .compactMap(\.totalSize).reduce(0, +)
        let done = copied == scope.count && !scope.isEmpty
        var note = "\(copied) of \(scope.count) \(selected.isEmpty ? "in the library" : "selected")"
        if left > 0 { note += " · \(Fmt.size(left)) left" }
        // Deliberately the accent colour whether or not it is finished: the
        // old green-when-complete made the same gauge look like two different
        // things depending on the source you happened to be looking at.
        // Floored like the Google gauge: only a truly complete copy says 100%.
        return SidebarMetric(icon: done ? "checkmark.circle.fill" : "internaldrive",
                             title: "Copied to this Mac",
                             value: "\(Int(fraction * 100))%",
                             fraction: fraction,
                             subtitle: note)
    }

    /// The pill is ordinary views — icon, name, chevron over a .quinary
    /// fill — with an invisible Menu stretched across it purely to catch the
    /// click. Styling a Menu's own label is a dead end: the bordered style
    /// hugs its content and ignores frames, and the borderless style strips
    /// backgrounds and extra glyphs, which is how this control kept losing
    /// its chrome no matter what was written here.
    @State private var pickerHovered = false

    private var sourcePicker: some View {
        // The styled row IS the menu's label. It used to be a decorative
        // HStack with a transparent .borderlessButton Menu stretched across
        // it in a ZStack — and that overlay quietly stopped hit-testing:
        // hover reached the row while a click never opened the menu. Making
        // the row the label is the shape the control actually supports, so
        // there is no invisible view to lose.
        Menu {
            Picker("Source", selection: Binding(get: { model.source },
                                                set: { model.switchTo($0) })) {
                Label(cameraName, systemImage: MediaSource.camera.symbol)
                    .tag(MediaSource.camera)
                Label(macName, systemImage: MediaSource.mac.symbol)
                    .tag(MediaSource.mac)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: model.source.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .padding(.trailing, 12)
                Text(model.source == .camera ? cameraName : macName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // A capsule's ends curve in ~24pt, so the content sits a little
            // deeper than it did in the 12pt-cornered box.
            .padding(.horizontal, 20)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(Capsule()
            .fill(pickerHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)))
        .onHover { inside in
            pickerHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeOut(duration: 0.12), value: pickerHovered)
    }

    private var cameraName: String { model.info?.modelName ?? "GoPro" }

    private var macName: String { Host.current().localizedName ?? "This Mac" }


}

/// The sidebar's building block: a title row and content on the same rounded
/// slab, so the column under the source picker reads as a stack of cards.
/// The calendar supplies its month stepper through `accessory`.
struct SidebarCard<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(title: String,
         @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }

    init(title: String,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 4)
                accessory
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
    }
}

/// The glass a sidebar control wears on Tahoe, with a material fallback.
struct GlassControl: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        }
    }
}

/// Icon, title and value on one line; a bar; a caption. Every sidebar gauge
/// uses it, so they stay legible as a column.
struct SidebarMetric: View {
    let icon: String
    let title: String
    let value: String
    /// Nil where there is nothing to be a fraction of — the row keeps the
    /// family shape, minus the bar.
    let fraction: Double?
    var tint: Color = .accentColor
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(value)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
                    .controlSize(.small)
                    .tint(tint)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
