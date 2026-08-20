import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// Where one item was shot — a place, not a route. A clip gets it from the
/// many fixes in its telemetry, a photo from the single one in its EXIF.
struct GPSSummary {
    let coordinate: CLLocationCoordinate2D
    let altitude: Double?
    let fixes: Int   // how many GPS samples stand behind it; 1 for a photo
}

/// Trailing inspector in the viewer (ⓘ / ⌘I): everything the camera reports
/// about the current item, plus the GPS track pulled from GPMF telemetry.
struct MediaDetailView: View {
    let entry: MediaEntry
    @EnvironmentObject var model: AppModel
    @State private var raw: [String: String]?
    @State private var photo: PhotoGPS.Details?
    @State private var gps: GPSSummary?
    @State private var loadingGPS = false
    @State private var gpsPaused = false
    /// The position data couldn't be read at all — distinct from reading it
    /// and finding the camera never had a lock, which is the common case.
    @State private var gpsUnreadable = false
    /// The track carried GPS rows but none of them were locked on: the
    /// receiver was running and never saw satellites, which is a different
    /// story from GPS having been switched off.
    @State private var gpsNeverLocked = false

    var body: some View {
        Form {
            fileSection
            if entry.isVideo { videoSection }
            if entry.isPhoto { photoSection }
            // The GPS track lives inside the clip, so it reads the same
            // whether the file is still on the camera or already copied here.
            // The camera's own metadata is an endpoint, so it stays camera-only.
            locationSection
            if model.source == .camera { rawSection }
        }
        .formStyle(.grouped)
        .task(id: entry.id) { await load() }
    }

    // MARK: Sections

    private var fileSection: some View {
        Section("File") {
            row("Name", entry.displayName)
            if case .video(let chapters) = entry.kind, chapters.count > 1 {
                row("Chapters", chapters.map(\.name).joined(separator: ", "))
            }
            if model.source == .mac {
                // On this Mac the path is a real place; clicking goes there.
                linkRow("Folder", entry.primary.folder) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.primary.path)])
                }
            } else {
                row("Folder", entry.primary.folder)
            }
            if let s = entry.totalSize { row("Size", Fmt.size(s)) }
            row("Created", Fmt.full.string(from: entry.created))
            row("Modified", Fmt.full.string(from: entry.primary.modified))
        }
    }

    private var videoSection: some View {
        Section("Video") {
            if let mi = model.mediaInfo[entry.id] {
                if let d = mi.duration { row("Duration", Fmt.duration(d)) }
                if let w = mi.width, let h = mi.height { row("Resolution", "\(w) × \(h)") }
                if let f = mi.fps { row("Frame rate", String(format: "%.2f fps", f)) }
                if let e = mi.eis { row("HyperSmooth", e ? "On" : "Off") }
                if !mi.hilights.isEmpty {
                    row("HiLights", mi.hilights.map { Fmt.duration($0) }.joined(separator: ", "))
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
    }

    /// What the camera wrote into the picture — resolution and the exposure
    /// story. Read from the file's own EXIF, so it's the same panel whether
    /// the photo is still on the camera or already here.
    private var photoSection: some View {
        Section("Photo") {
            if let d = photo {
                if let w = d.width, let h = d.height { row("Resolution", "\(w) × \(h)") }
                if let f = d.fNumber { row("Aperture", String(format: "ƒ/%.1f", f)) }
                if let t = d.exposureSeconds { row("Shutter", Self.shutter(t)) }
                if let i = d.iso { row("ISO", "\(i)") }
                if let mm = d.focalMM {
                    row("Focal length", String(format: "%.2f mm", mm)
                        + (d.focal35MM.map { " (\($0) mm equivalent)" } ?? ""))
                }
                if let b = d.exposureBias, b != 0 {
                    row("Exposure bias", String(format: "%+.1f EV", b))
                }
                if let auto = d.whiteBalanceAuto { row("White balance", auto ? "Auto" : "Manual") }
                if let m = d.metering { row("Metering", m) }
                if let p = d.colorProfile { row("Color profile", p) }
            } else if loadingGPS {
                Text("Loading…").foregroundStyle(.secondary)
            } else if gpsPaused {
                Text("Paused while a copy is running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No capture details in this file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Photographers read exposure as a fraction; nobody says "0.001 s".
    private static func shutter(_ t: Double) -> String {
        guard t > 0 else { return "—" }
        return t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t)
    }

    @ViewBuilder
    private var locationSection: some View {
        Section("Location") {
            if let gps {
                Map(initialPosition: .region(region(for: gps))) {
                    Marker(entry.displayName, coordinate: gps.coordinate)
                }
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .id(entry.id)   // re-center when flipping between items
                row("Coordinates", String(format: "%.5f, %.5f",
                                          gps.coordinate.latitude, gps.coordinate.longitude))
                if let altitude = gps.altitude {
                    row("Altitude", String(format: "%.0f m", altitude))
                }
                if gps.fixes > 1 { row("From", "\(gps.fixes) GPS fixes") }
                Button {
                    openInMaps(gps)
                } label: {
                    Label("Open in Maps", systemImage: "map")
                }
            } else if loadingGPS {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading location…").foregroundStyle(.secondary)
                }
            } else {
                Text(noLocationReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rawSection: some View {
        Section("Camera metadata") {
            if let raw {
                ForEach(Self.fields.filter { raw[$0.key] != nil }, id: \.key) { field in
                    row(field.label, field.display(raw[field.key] ?? ""))
                }
                let known = Set(Self.fields.map(\.key))
                let rest = raw.keys.filter { !known.contains($0) && !Self.shownAbove.contains($0) }.sorted()
                if !rest.isEmpty {
                    DisclosureGroup("Unrecognised fields (\(rest.count))") {
                        ForEach(rest, id: \.self) { key in
                            row(key, raw[key] ?? "", mono: true)
                        }
                        Text("Keys this camera sends that aren't in GoPro's own SDK — shown exactly as sent rather than guessed at.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if entry.chapterCount > 1 {
                    Text("These fields describe chapter 1.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
    }

    /// The camera answers /gopro/media/info with terse keys. GoPro never
    /// documented them in the HTTP spec, but their own Kotlin SDK names every
    /// one (wsdk .../entity/operation/Media.kt), enums included — that is
    /// where these labels and value mappings come from. Anything a future
    /// firmware adds that isn't here still shows, verbatim, under the
    /// disclosure.
    private struct NamedField {
        let key: String
        let label: String
        let display: (String) -> String
    }

    /// Already spelled out by the File and Video sections above.
    private static let shownAbove: Set<String> =
        ["cre", "s", "dur", "w", "h", "fps", "fps_denom", "eis", "hi", "hc"]

    /// Deliberately ordered — what the shot was, then how it was captured,
    /// then bookkeeping — rather than alphabetical.
    private static let fields: [NamedField] = [
        NamedField(key: "ct", label: "Captured as", display: contentType),
        NamedField(key: "lc", label: "Lens") { $0 == "1" ? "Rear" : "Front" },
        NamedField(key: "prjn", label: "Lens projection", display: projection),
        NamedField(key: "fov", label: "Field of view") { $0.capitalized },
        NamedField(key: "ao", label: "Audio") { $0.capitalized },
        NamedField(key: "pta", label: "Protune audio", display: onOff),
        NamedField(key: "ls", label: "Proxy (.LRV) size", display: size),
        NamedField(key: "glrv", label: "Proxy (.LRV) size", display: size),
        NamedField(key: "avc_profile", label: "Codec profile", display: codec),
        NamedField(key: "profile", label: "Codec level", display: codec),
        NamedField(key: "raw", label: "RAW alongside the JPEG", display: yesNo),
        NamedField(key: "wdr", label: "Wide Dynamic Range", display: onOff),
        NamedField(key: "hdr", label: "HDR", display: onOff),
        NamedField(key: "mahs", label: "Best auto-HiLight score") { $0 },
        NamedField(key: "subsample", label: "Frames subsampled", display: yesNo),
        NamedField(key: "cl", label: "Clipped", display: yesNo),
        NamedField(key: "prog", label: "Progressive scan", display: yesNo),
        NamedField(key: "tr", label: "Transcoded by the camera", display: yesNo),
        NamedField(key: "mp", label: "Metadata track", display: presentAbsent),
        NamedField(key: "gumi", label: "Media ID") { $0 },
        NamedField(key: "pgumi", label: "Parent media ID") { $0 },
        NamedField(key: "mos", label: "Offloaded to") { v in
            let s = v.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? "Nothing yet" : s.uppercased()
        },
        NamedField(key: "us", label: "Uploaded", display: yesNo),
        // GoPro's SDK marks this one deprecated; the camera still sends it.
        NamedField(key: "rot", label: "Rotation (unused)") { $0 },
    ]

    private static func onOff(_ v: String) -> String { v == "1" ? "On" : "Off" }
    private static func yesNo(_ v: String) -> String { v == "1" ? "Yes" : "No" }
    private static func presentAbsent(_ v: String) -> String { v == "1" ? "Present" : "None" }

    private static func size(_ v: String) -> String {
        guard let n = Int64(v), n > 0 else { return "None" }
        return Fmt.size(n)
    }

    /// 255 is the camera's "not applicable" for these two.
    private static func codec(_ v: String) -> String { v == "255" ? "—" : v }

    private static func contentType(_ v: String) -> String {
        switch v {
        case "0": return "Video"
        case "1": return "Looping video"
        case "2": return "Chaptered video"
        case "3": return "Time-lapse video"
        case "4": return "Single photo"
        case "5": return "Burst photo"
        case "6": return "Time-lapse photo"
        case "8": return "Night-lapse photo"
        case "9": return "Night photo"
        case "10": return "Continuous photo"
        case "11": return "RAW photo"
        case "12": return "Live burst"
        default: return v
        }
    }

    /// How a 360 camera's spheres were laid into the frame. GoPro's enum calls
    /// 9 "error"; a HERO13 reports it for every ordinary clip, so it reads as
    /// "none" here rather than as a fault.
    private static func projection(_ v: String) -> String {
        switch v {
        case "0": return "Equi-angular cubemap"
        case "1": return "Equirectangular"
        case "2": return "Equi-angular cubemap, split"
        case "3": return "Equirectangular, cropped panorama"
        case "4": return "Adjacent circles, unstitched"
        case "5": return "Offline, unstitched"
        case "6": return "Unstitched"
        case "7": return "Cubemap, unsplit"
        case "8": return "Hemispheric"
        case "9": return "None"
        default: return v
        }
    }

    /// Deliberately not LabeledContent: when a value doesn't fit beside its
    /// label that drops it onto a second line, which a 32-character media ID
    /// always does. An HStack lets the value shrink and ellipsise instead —
    /// the whole string stays on the tooltip, and is still what a copy takes.
    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .callout.monospaced() : nil)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    /// A row whose value is a place on this Mac: the label column of `row`,
    /// with the value as a link that reveals the file in Finder.
    private func linkRow(_ label: String, _ value: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Button(action: action) {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("Reveal in Finder")
        }
    }

    /// Why the panel is empty. Worth spelling out: most clips have no
    /// position at all, and "the camera never locked on" is a different
    /// answer from "GPS was off" or "the read failed".
    private var noLocationReason: String {
        if gpsPaused { return "Paused while a copy is running." }
        if gpsUnreadable { return "Couldn't read this one — the camera may have gone to sleep." }
        if entry.isVideo {
            return gpsNeverLocked
                ? "The camera's GPS was on but never locked on during this clip."
                : "No GPS was recorded with this clip."
        }
        if entry.isPhoto { return "No location was saved with this photo." }
        return "Location is read from videos and photos."
    }

    // MARK: Data

    private func load() async {
        raw = nil
        photo = nil
        gps = nil
        gpsPaused = false
        gpsUnreadable = false
        gpsNeverLocked = false
        model.fetchInfo(for: entry)   // fills the Video section (no-op if cached)
        let path = entry.primary.path
        if model.source == .camera, let client = model.client {
            raw = try? await client.mediaInfoRaw(path: path)
        }
        guard entry.isVideo || entry.isPhoto else { return }
        // Reading a clip's telemetry costs dozens of ranged requests. During a
        // copy the camera is saturated — and turbo transfer makes it ignore
        // most else anyway — so stand down like the thumbnail loader does.
        if model.source == .camera, model.transfers.isActive {
            gpsPaused = true
            return
        }
        loadingGPS = true
        defer { loadingGPS = false }
        if entry.isVideo {
            gps = await clipLocation(path)
        } else {
            await loadPhoto(path)
        }
        // Most items simply never had a lock, so "nothing here" is the normal
        // answer, not a fault — the log is where the difference is visible.
        AppLog.log("location: \(path) — " + (gps.map { "\($0.fixes) fix(es)" }
                                             ?? (gpsUnreadable ? "unreadable"
                                                 : gpsNeverLocked ? "never locked" : "no GPS recorded")))
    }

    /// A clip's location is the median of the fixes in its telemetry track.
    private func clipLocation(_ path: String) async -> GPSSummary? {
        let track: Data?
        switch model.source {
        case .camera:
            guard let client = model.client else { return nil }
            track = try? await client.gpmdTrack(path: path)
        case .mac:
            track = try? await MP4.gpmdTrack(fileURL: URL(fileURLWithPath: path))
        }
        guard let track else { gpsUnreadable = true; return nil }
        let points = await Task.detached(priority: .userInitiated) {
            GPMF.gpsTrack(from: track)
        }.value
        let summary = Self.summarize(points)
        gpsNeverLocked = summary == nil && !points.isEmpty
        return summary
    }

    /// Everything a photo can tell about itself lives in EXIF at the front of
    /// the file, so one header read serves both the capture details and the
    /// location — the camera is never asked for the whole JPEG.
    private func loadPhoto(_ path: String) async {
        let hit: (coordinate: CLLocationCoordinate2D, altitude: Double?)?
        switch model.source {
        case .camera:
            guard let client = model.client,
                  let head = try? await client.fileHeader(path: path, bytes: PhotoGPS.headerBytes)
            else { gpsUnreadable = true; return }
            photo = PhotoGPS.details(fromHeader: head)
            hit = PhotoGPS.location(fromHeader: head)
        case .mac:
            let url = URL(fileURLWithPath: path)
            photo = PhotoGPS.details(fileURL: url)
            hit = PhotoGPS.location(fileURL: url)
        }
        guard let hit else { return }
        gps = GPSSummary(coordinate: hit.coordinate, altitude: hit.altitude, fixes: 1)
    }

    /// Keep plausible fixes only; -1 fix means the stream carried no GPSF, in
    /// which case sane coordinates are trusted.
    ///
    /// The place is the median of what's left, not the mean: a camera that
    /// half-loses its lock drifts, sometimes for hundreds of metres, and one
    /// runaway stretch drags an average with it while leaving a median where
    /// the camera actually spent the clip.
    static func summarize(_ points: [GPSPoint]) -> GPSSummary? {
        let valid = points.filter {
            ($0.fix >= 2 || $0.fix == -1)
                && abs($0.lat) <= 90 && abs($0.lon) <= 180
                && !($0.lat == 0 && $0.lon == 0)
        }
        guard !valid.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return GPSSummary(
            coordinate: CLLocationCoordinate2D(latitude: median(valid.map(\.lat)),
                                               longitude: median(valid.map(\.lon))),
            altitude: median(valid.map(\.alt)),
            fixes: valid.count)
    }

    /// About a kilometre across — close enough to place the shot on a street,
    /// wide enough that a rough fix doesn't look like a precise one.
    private func region(for gps: GPSSummary) -> MKCoordinateRegion {
        MKCoordinateRegion(center: gps.coordinate,
                           span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    }

    private func openInMaps(_ gps: GPSSummary) {
        var comps = URLComponents(string: "maps://")!
        comps.queryItems = [
            URLQueryItem(name: "ll", value: "\(gps.coordinate.latitude),\(gps.coordinate.longitude)"),
            URLQueryItem(name: "q", value: entry.displayName)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}
