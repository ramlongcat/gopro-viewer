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
    @Published var viewer: ViewerTarget?
    @Published var mediaInfo: [String: MediaInfoLite] = [:]
    @Published var downloadedIDs = Set<String>()

    let transfers = TransferManager()
    let thumbs = ThumbnailLoader()

    private var loopTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var infoFetches = Set<String>()

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
                    // Idle means idle: no camera traffic at all. Unplugging is
                    // noticed by watching (locally) for the USB interface.
                    if !self.transfers.isActive, goProUSBPortName() == nil {
                        self.disconnect()
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
        if let s = try? await client.state() { status = s }
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
        return out
    }

    private func scan() async {
        var sawDenied = false
        let candidates = candidateIPs()
        for ip in candidates {
            switch await GoProClient.probe(ip: ip) {
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

    var filteredEntries: [MediaEntry] {
        entries.filter { filter.matches($0) }
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
            DaySection(id: key, title: Fmt.dayTitle.string(from: byDay[key]![0].created), entries: byDay[key]!)
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
              let client, !transfers.isActive,
              case .video(let chapters) = entry.kind else { return }
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
    private(set) var destIndex: [String: Set<Int64>] = [:]

    func rebuildDestIndex() async {
        let base = Prefs.destination
        destIndex = await Task.detached(priority: .utility) {
            func scan() -> [String: Set<Int64>] {
                var idx: [String: Set<Int64>] = [:]
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
                    idx[url.lastPathComponent, default: []].insert(Int64(size))
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
        let fm = FileManager.default
        for e in entries {
            let files = e.mainFiles
            guard !files.isEmpty else { continue }
            let all = files.allSatisfy { tf in
                if let sizes = idx[tf.name] {
                    if let size = tf.size {
                        if sizes.contains(size) { return true }
                    } else if !sizes.isEmpty {
                        return true
                    }
                }
                let url = destinationURL(for: tf)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return false }
                guard let size = tf.size else { return true }
                return (attrs[.size] as? NSNumber)?.int64Value == size
            }
            if all { done.insert(e.id) }
        }
        downloadedIDs = done
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
        } else {
            selection = [id]
            selectionAnchor = id
            shiftBase = [id]
        }
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
