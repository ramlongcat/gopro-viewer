import Foundation
import SwiftUI
import SystemConfiguration

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case videos = "Videos"
    case photos = "Photos"
    var id: String { rawValue }

    func matches(_ e: MediaEntry) -> Bool {
        switch self {
        case .all: return true
        case .videos: return e.isVideo
        case .photos: return e.isPhoto
        }
    }
}

/// Grid ordering. `buildEntries` hands back newest-first, so ascending is a
/// reverse rather than a re-sort.
enum SortOrder: String, CaseIterable, Identifiable {
    case dateDescending = "Date descending"
    case dateAscending = "Date ascending"
    var id: String { rawValue }
}

/// Which items the grid shows, independent of the videos/photos tabs.
enum ShowScope: String, CaseIterable, Identifiable {
    case all = "All items"
    case notCopied = "Only items not copied yet"
    var id: String { rawValue }
}

struct ViewerTarget: Identifiable, Equatable {
    let id: String
}

struct DaySection: Identifiable {
    let id: String
    let title: String
    let entries: [MediaEntry]
}

@MainActor
final class AppModel: ObservableObject {
    enum ConnState: Equatable {
        case searching
        case linkAsleep(String)     // USB network port exists but camera isn't answering
        case linkBlocked(String)    // camera reachable but macOS denies Local Network access
        case connecting(String)
        case connected
    }

    @Published var connState: ConnState = .searching
    @Published private(set) var client: GoProClient?
    @Published var info: CameraInfo?
    @Published var status: CameraStatus?
    @Published var entries: [MediaEntry] = []
    @Published var loadingMedia = false
    @Published var mediaError: String?
    @Published var selection = Set<String>()
    @Published var selectionAnchor: String?
    /// Selection as it was when the anchor was set — shift-clicks rebuild from
    /// this so successive range clicks retarget (Finder) instead of accumulating.
    private var shiftBase: Set<String> = []
    @Published var filter: MediaFilter = .all
    @Published var showAbout = false
    /// A day key from the sidebar calendar, or nil for the whole library.
    @Published var dayFilter: String?
    @Published var sortOrder = SortOrder(rawValue: Prefs.sortOrder) ?? .dateDescending {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: Prefs.kSortOrder) }
    }
    @Published var showScope = ShowScope(rawValue: Prefs.showScope) ?? .all {
        didSet { UserDefaults.standard.set(showScope.rawValue, forKey: Prefs.kShowScope) }
    }
    /// Camera or this Mac. Switching reloads the grid from the other side.
    @Published var source: MediaSource = .camera
    @Published var viewer: ViewerTarget?
    @Published var mediaInfo: [String: MediaInfoLite] = [:]
    @Published var downloadedIDs = Set<String>()
    /// Where each copied entry was actually found — the badge tooltip names
    /// it, and a name+size match can live anywhere under the destination, not
    /// just in the folder this run would have written to.
    @Published var downloadedFolders: [String: URL] = [:]
    /// A GoPro on the USB link is drawing power from the Mac, so a camera
    /// that isn't full is charging.
    @Published private(set) var poweredOverUSB = false
    /// Seconds to a full battery, extrapolated from how fast the reported
    /// percentage has been climbing. Nil until it has climbed at least once.
    @Published private(set) var batteryTimeToFull: TimeInterval?
    /// The percentage has gone up while we watched — proof of charging that
    /// doesn't depend on guessing from the kind of connection.
    @Published private(set) var batteryRising = false
    /// One entry per percentage change: (when it was first seen, percentage).
    private var batterySamples: [(at: Date, pct: Int)] = []

    let transfers = TransferManager()
    let thumbs = ThumbnailLoader()

    private var loopTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var infoFetches = Set<String>()
    /// Whether the live connection came in over the camera's USB network
    /// interface. Only then does "GoPro USB port gone" mean unplugged —
    /// override/LAN/emulator connections must not be dropped by that check.
    private var usbLinked = false

    init() {
        transfers.model = self
        thumbs.transfers = transfers
    }

    func start() {
        guard loopTask == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshState() }
        }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.connState == .connected {
                    if !self.transfers.isActive {
                        if self.usbLinked {
                            // Idle means idle on USB: no camera traffic at all.
                            // Unplugging is noticed locally via the interface.
                            if goProUSBPortName() == nil { self.disconnect() }
                        } else if let ip = self.client?.ip,
                                  await GoProClient.probe(ip: ip) == .unreachable {
                            // Emulator/LAN links have no interface to watch; a
                            // light ping notices the peer going away.
                            self.disconnect()
                        }
                    }
                    try? await Task.sleep(for: .seconds(5))
                } else {
                    if !self.transfers.isActive { await self.scan() }
                    try? await Task.sleep(for: .seconds(2.5))
                }
            }
        }
    }

    /// One-shot status fetch on connect, app activation, refresh, and after
    /// transfers — the app never polls an idle camera.
    func refreshState() async {
        guard let client, connState == .connected, !transfers.isActive else { return }
        if let s = try? await client.state() {
            status = s
            if let pct = s.batteryPercent { noteBattery(pct) }
        }
    }

    /// Charge rate from the percentages seen so far. Only changes are recorded,
    /// so the rate is measured between the first sighting of two levels; older
    /// samples age out so a slowing charge is reflected rather than averaged
    /// away forever.
    private func noteBattery(_ pct: Int) {
        let now = Date()
        if batterySamples.last?.pct != pct { batterySamples.append((now, pct)) }
        batterySamples.removeAll { now.timeIntervalSince($0.at) > 45 * 60 }
        guard let first = batterySamples.first, let last = batterySamples.last,
              last.pct > first.pct, last.pct < 100 else {
            batteryRising = false
            batteryTimeToFull = nil
            return
        }
        batteryRising = true
        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed > 30 else { batteryTimeToFull = nil; return }
        let perSecond = Double(last.pct - first.pct) / elapsed
        batteryTimeToFull = Double(100 - last.pct) / perSecond
    }

    private func infoCacheFile(_ c: GoProClient) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoProOffload/mediainfo-\(c.cacheKey).json")
    }

    // MARK: Discovery

    /// Wired GoPros live at 172.2X.1YZ.51 on their own USB NCM interface, so
    /// every local 172.2x.x.x interface implies a .51 candidate.
    private func candidateIPs() -> [String] {
        var out: [String] = []
        let override = Prefs.overrideIP
        if !override.isEmpty { out.append(override) }
        for ip in ipv4InterfaceAddresses() {
            let parts = ip.split(separator: ".").map(String.init)
            guard parts.count == 4, parts[0] == "172", let second = Int(parts[1]),
                  (20...29).contains(second) else { continue }
            let candidate = "\(parts[0]).\(parts[1]).\(parts[2]).51"
            if !out.contains(candidate) { out.append(candidate) }
        }
        let last = Prefs.lastCameraIP
        if !last.isEmpty, !out.contains(last) { out.append(last) }
        // Last resort so the dev emulator (tools/gopro_emulator.py) is found
        // the moment it starts, like plugging a camera in. Real cameras come
        // first, and the localhost probe is strict.
        if !out.contains(Self.emulatorIP) { out.append(Self.emulatorIP) }
        return out
    }

    static let emulatorIP = "127.0.0.1"

    private func scan() async {
        var sawDenied = false
        let candidates = candidateIPs()
        for ip in candidates {
            switch await GoProClient.probe(ip: ip, strict: ip == Self.emulatorIP) {
            case .ok:
                await connect(ip)
                return
            case .denied:
                sawDenied = true
            case .unreachable:
                break
            }
        }
        let port = goProUSBPortName()
        let newState: ConnState
        if let port {
            newState = sawDenied ? .linkBlocked(port) : .linkAsleep(port)
        } else {
            newState = .searching
        }
        if newState != connState {
            AppLog.log("discovery: candidates=\(candidates) denied=\(sawDenied) port=\(port ?? "none") -> \(newState)")
            connState = newState
        }
    }

    private func connect(_ ip: String) async {
        connState = .connecting(ip)
        let octets = ip.split(separator: ".")
        usbLinked = octets.count == 4 && octets[0] == "172"
        poweredOverUSB = usbLinked
            && (Int(octets[1]).map { (20...29).contains($0) } ?? false)
        let c = GoProClient(ip: ip)
        try? await c.enableWiredControl()
        if let info = try? await c.cameraInfo() {
            self.info = info
            if !info.serial.isEmpty { c.cacheKey = info.serial }
        }
        status = try? await c.state()
        client = c
        connState = .connected
        UserDefaults.standard.set(ip, forKey: Prefs.kLastIP)
        AppLog.log("connected: \(ip) \(info?.modelName ?? "") fw \(info?.firmware ?? "")")
        if let data = try? Data(contentsOf: infoCacheFile(c)),
           let cached = try? JSONDecoder().decode([String: MediaInfoLite].self, from: data) {
            mediaInfo = cached
        }
        await loadMedia()
    }

    private func disconnect() {
        client = nil
        info = nil
        status = nil
        entries = []
        selection = []
        mediaInfo = [:]
        infoFetches = []
        viewer = nil
        connState = .searching
    }

    // MARK: Media

    func loadMedia() async {
        guard let client else { return }
        loadingMedia = true
        mediaError = nil
        do {
            let files = try await client.mediaList()
            entries = buildEntries(files)
            selection = selection.filter { id in entries.contains { $0.id == id } }
            await refreshDownloaded()
        } catch {
            mediaError = error.localizedDescription
        }
        loadingMedia = false
    }

    func switchTo(_ newSource: MediaSource) {
        guard newSource != source else { return }
        source = newSource
        selection = []
        selectionAnchor = nil
        viewer = nil
        entries = []
        dayFilter = nil
        mediaError = nil
        Task { await reload() }
    }

    func reload() async {
        switch source {
        case .camera: await loadMedia()
        case .mac: await loadLocalMedia()
        }
    }

    /// Everything already copied under the destination, folded by the same
    /// rules the camera list goes through.
    func loadLocalMedia() async {
        loadingMedia = true
        mediaError = nil
        let base = Prefs.destination
        let files = await Task.detached(priority: .userInitiated) { LocalLibrary.scan(base) }.value
        entries = buildEntries(files)
        selection = selection.filter { id in entries.contains { $0.id == id } }
        // "Already copied" is what this source *is*; every item counts.
        downloadedIDs = Set(entries.map(\.id))
        loadingMedia = false
    }

    /// Where a file's bytes live for the source in view — an HTTP URL on the
    /// camera, a file URL on this Mac.
    func mediaURL(_ file: CameraFile) -> URL? {
        switch source {
        case .camera: return client?.downloadURL(path: file.path)
        case .mac: return URL(fileURLWithPath: file.path)
        }
    }

    /// What a grid hover preview should play.
    func hoverURL(_ entry: MediaEntry) -> URL? {
        switch source {
        case .camera:
            // The proxy or nothing: pulling a full-quality stream over USB
            // for a thumbnail would starve the grid and the camera both.
            guard let proxy = entry.proxyPath else { return nil }
            return client?.downloadURL(path: proxy)
        case .mac:
            // No link to protect here. Use the proxy if it happens to have
            // been copied, otherwise the clip itself plays perfectly well.
            if let proxy = entry.proxyPath, FileManager.default.fileExists(atPath: proxy) {
                return URL(fileURLWithPath: proxy)
            }
            guard case .video(let chapters) = entry.kind, let first = chapters.first else { return nil }
            return URL(fileURLWithPath: first.path)
        }
    }

    var localSpace: (free: Int64, total: Int64)? {
        LocalLibrary.volumeSpace(at: Prefs.destination)
    }

    /// Entries matching the videos/photos tabs only — the copy-progress
    /// summary needs a denominator that doesn't shrink when the View menu
    /// hides copied items.
    var typeFilteredEntries: [MediaEntry] {
        entries.filter { filter.matches($0) }
    }

    /// What the grid shows: tabs, then the View menu's scope and sort order.
    var filteredEntries: [MediaEntry] {
        var list = typeFilteredEntries
        if let dayFilter {
            list = list.filter { Fmt.dayKey.string(from: $0.created) == dayFilter }
        }
        if showScope == .notCopied {
            list = list.filter { !downloadedIDs.contains($0.id) }
        }
        // buildEntries already sorts newest-first.
        if sortOrder == .dateAscending { list.reverse() }
        return list
    }

    var sections: [DaySection] {
        var order: [String] = []
        var byDay: [String: [MediaEntry]] = [:]
        for e in filteredEntries {
            let key = Fmt.dayKey.string(from: e.created)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(e)
        }
        return order.map { key in
            DaySection(id: key, title: Fmt.daySection(byDay[key]![0].created), entries: byDay[key]!)
        }
    }

    var selectedEntries: [MediaEntry] {
        filteredEntries.filter { selection.contains($0.id) }
    }

    func entry(for id: String) -> MediaEntry? {
        entries.first { $0.id == id }
    }

    func fetchInfo(for entry: MediaEntry) {
        guard entry.isVideo, mediaInfo[entry.id] == nil,
              !infoFetches.contains(entry.id),
              case .video(let chapters) = entry.kind else { return }
        if source == .mac {
            infoFetches.insert(entry.id)
            Task {
                var combined = MediaInfoLite()
                for ch in chapters {
                    guard let mi = await LocalLibrary.info(for: URL(fileURLWithPath: ch.path)) else { continue }
                    if combined == MediaInfoLite() { combined = mi }
                    else { combined.duration = (combined.duration ?? 0) + (mi.duration ?? 0) }
                }
                if combined != MediaInfoLite() { mediaInfo[entry.id] = combined }
            }
            return
        }
        guard let client, !transfers.isActive else { return }
        infoFetches.insert(entry.id)
        Task {
            var combined = MediaInfoLite()
            var offset: Double = 0
            for (i, ch) in chapters.enumerated() {
                guard let mi = await client.mediaInfoLite(path: ch.path) else { continue }
                if i == 0 {
                    combined.width = mi.width
                    combined.height = mi.height
                    combined.fps = mi.fps
                    combined.eis = mi.eis
                }
                combined.hilights += mi.hilights.map { $0 + offset }
                offset += mi.duration ?? 0
            }
            if offset > 0 { combined.duration = offset }
            if combined != MediaInfoLite() {
                mediaInfo[entry.id] = combined
                saveInfoCache()
            }
        }
    }

    private func saveInfoCache() {
        guard let client else { return }
        let snapshot = mediaInfo
        let url = infoCacheFile(client)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url)
        }
    }

    /// Filename -> sizes of media files found anywhere under the destination
    /// base, so "already copied" is recognized even after the folder naming
    /// scheme changes or files get reorganized by hand.
    struct DestHit: Sendable {
        let size: Int64
        let url: URL
    }

    private(set) var destIndex: [String: [DestHit]] = [:]

    func rebuildDestIndex() async {
        let base = Prefs.destination
        destIndex = await Task.detached(priority: .utility) {
            func scan() -> [String: [DestHit]] {
                var idx: [String: [DestHit]] = [:]
                let exts: Set<String> = ["MP4", "JPG", "LRV", "THM", "GPR", "360"]
                guard let en = FileManager.default.enumerator(
                    at: base,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return idx }
                var seen = 0
                for case let url as URL in en {
                    seen += 1
                    if seen > 200_000 { break }
                    if en.level > 6 { en.skipDescendants(); continue }
                    guard exts.contains(url.pathExtension.uppercased()),
                          let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          vals.isRegularFile == true, let size = vals.fileSize else { continue }
                    idx[url.lastPathComponent, default: []].append(DestHit(size: Int64(size), url: url))
                }
                return idx
            }
            return scan()
        }.value
    }

    /// Re-check which entries already exist at the destination (exact expected
    /// path, or same name+size anywhere under the base).
    func refreshDownloaded() async {
        await rebuildDestIndex()
        let idx = destIndex
        var done = Set<String>()
        var folders: [String: URL] = [:]
        let fm = FileManager.default

        /// Where this file already sits on disk, or nil if it doesn't.
        func located(_ tf: TransferFile) -> URL? {
            if let hits = idx[tf.name] {
                if let size = tf.size {
                    if let hit = hits.first(where: { $0.size == size }) { return hit.url }
                } else if let hit = hits.first {
                    return hit.url
                }
            }
            let url = destinationURL(for: tf)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            guard let size = tf.size else { return url }
            return (attrs[.size] as? NSNumber)?.int64Value == size ? url : nil
        }

        for e in entries {
            let files = e.mainFiles
            guard !files.isEmpty else { continue }
            let found = files.compactMap(located)
            if found.count == files.count {
                done.insert(e.id)
                folders[e.id] = found[0].deletingLastPathComponent()
            }
        }
        downloadedIDs = done
        downloadedFolders = folders
    }

    /// Tooltip for the copied badge, naming the folder the file is in.
    /// What the tick on a tile means: copied here, when looking at the
    /// camera; sent to Google Photos, when looking at what's already here.
    func isMarked(_ entry: MediaEntry) -> Bool {
        switch source {
        case .camera:
            return downloadedIDs.contains(entry.id)
        case .mac:
            let sendable = GooglePhotos.sendables(of: entry)
            guard !sendable.isEmpty else { return false }
            return sendable.allSatisfy {
                GooglePhotos.shared.uploaded.contains(GooglePhotos.key(name: $0.name, size: $0.size))
            }
        }
    }

    func markNote(for entry: MediaEntry) -> String {
        source == .mac ? "Uploaded to Google Photos" : copiedNote(for: entry.id)
    }

    func copiedNote(for id: String) -> String {
        let folder = downloadedFolders[id] ?? Prefs.destination
        return "Already copied to \(homeRelativePath(folder))"
    }

    /// Live per-entry completion from the transfer queue; the full disk
    /// rescan still runs when the batch ends.
    func entryCopied(_ id: String) {
        downloadedIDs.insert(id)
    }

    func transfersFinished() {
        Task {
            await refreshDownloaded()
            await refreshState()
        }
    }

    // MARK: Actions

    func selectAllVisible() {
        selection = Set(filteredEntries.map(\.id))
        shiftBase = selection
    }

    func deselectAll() {
        selection = []
        selectionAnchor = nil
        shiftBase = []
    }

    /// Finder-style selection: plain click selects just that item, ⌘ toggles
    /// membership, ⇧ selects everything between the anchor and the clicked
    /// item — re-shift-clicking retargets the range rather than accumulating.
    func handleCellClick(_ id: String, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
            shiftBase = selection
        } else if modifiers.contains(.shift), let anchor = selectionAnchor {
            let list = filteredEntries.map(\.id)
            if let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: id) {
                selection = shiftBase.union(list[min(a, b)...max(a, b)])
            } else {
                selection = [id]
                selectionAnchor = id
                shiftBase = [id]
            }
        } else if selection.contains(id) {
            // Plain click on an already-selected item unselects it.
            selection.remove(id)
            if selection.isEmpty { selectionAnchor = nil }
            shiftBase = selection
        } else {
            selection = [id]
            selectionAnchor = id
            shiftBase = [id]
        }
    }

    /// Entries not yet found at the destination — drives "Select N Missing
    /// Items" in the Select menus.
    var missingEntries: [MediaEntry] {
        entries.filter { !downloadedIDs.contains($0.id) }
    }

    /// Selects everything not yet transferred; drops any active filter so the
    /// selection is fully visible and the toolbar Transfer count matches.
    func selectMissing() {
        filter = .all
        selection = Set(missingEntries.map(\.id))
        selectionAnchor = nil
        shiftBase = selection
        AppLog.log("selectMissing: \(selection.count)")
    }

    func downloadSelected() {
        guard let client else { return }
        let targets = selectedEntries
        AppLog.log("downloadSelected: selection=\(selection.count) targets=\(targets.count) [\(targets.map(\.primary.name).joined(separator: " "))]")
        guard !targets.isEmpty else { return }
        transfers.start(entries: targets, client: client)
    }

    func download(_ entry: MediaEntry) {
        guard let client else { return }
        transfers.start(entries: [entry], client: client)
    }

    // MARK: Viewer navigation

    func viewerNeighbor(_ delta: Int) {
        guard let current = viewer?.id else { return }
        let list = filteredEntries
        guard let idx = list.firstIndex(where: { $0.id == current }) else { return }
        let next = idx + delta
        guard list.indices.contains(next) else { return }
        viewer = ViewerTarget(id: list[next].id)
    }

    func viewerPosition() -> (Int, Int)? {
        guard let current = viewer?.id else { return nil }
        let list = filteredEntries
        guard let idx = list.firstIndex(where: { $0.id == current }) else { return nil }
        return (idx + 1, list.count)
    }
}

// MARK: - Interface enumeration

private func ipv4InterfaceAddresses() -> [String] {
    var out: [String] = []
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0 else { return out }
    defer { freeifaddrs(addrs) }
    var cursor = addrs
    while let cur = cursor {
        defer { cursor = cur.pointee.ifa_next }
        guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            out.append(String(cString: host))
        }
    }
    return out
}

/// Name of a network port that looks like a GoPro USB link (e.g. "HERO13 Black"),
/// used to tell "camera asleep" apart from "no camera".
private func goProUSBPortName() -> String? {
    guard let ifs = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
    for iface in ifs {
        if let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
            let lower = name.lowercased()
            if lower.contains("hero") || lower.contains("gopro") {
                return name
            }
        }
    }
    return nil
}
