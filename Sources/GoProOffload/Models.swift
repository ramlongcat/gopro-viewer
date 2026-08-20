import Foundation

// MARK: - Raw media list JSON (GET /gopro/media/list)

private struct RawMediaList: Decodable {
    let id: String?
    let media: [RawDirectory]?
}

private struct RawDirectory: Decodable {
    let d: String
    let fs: [RawFile]?
}

private struct RawFile: Decodable {
    let n: String
    let cre: FlexInt?
    let mod: FlexInt?
    let s: FlexInt?
    let glrv: FlexInt?
    let ls: FlexInt?
    let raw: String?
    let g: FlexInt?
    let b: FlexInt?
    let l: FlexInt?
    let m: [FlexInt]?
    let t: String?
}

// MARK: - Clean model

struct GroupInfo: Hashable {
    let id: Int
    let first: Int
    let last: Int
    let missing: Set<Int>
    let type: String   // b=burst, c=continuous, n=night lapse, t=time lapse

    var memberIDs: [Int] { (first...max(first, last)).filter { !missing.contains($0) } }
    var count: Int { memberIDs.count }

    var typeName: String {
        switch type {
        case "b": return "Burst"
        case "c": return "Continuous"
        case "n": return "Night lapse"
        case "t": return "Time lapse"
        default: return "Group"
        }
    }
}

struct CameraFile: Identifiable, Hashable {
    let folder: String
    let name: String
    let size: Int64
    let created: Date
    let modified: Date
    let lrvSize: Int64?
    let hasRaw: Bool
    let group: GroupInfo?

    var id: String { path }
    var path: String { "\(folder)/\(name)" }
    var ext: String { (name as NSString).pathExtension.uppercased() }
    var base: String { (name as NSString).deletingPathExtension }
    var isVideo: Bool { ext == "MP4" || ext == "360" }
    var isPhoto: Bool { ext == "JPG" || ext == "GPR" }

    /// GoPro video names: G + codec letter + 2-digit chapter + 4-digit number,
    /// e.g. GX010023.MP4 is chapter 01 of video 0023 (HEVC).
    var videoNameParts: (prefix: String, chapter: Int, number: String)? {
        guard isVideo, name.count >= 12, name.hasPrefix("G") else { return nil }
        let b = base
        guard b.count == 8 else { return nil }
        let prefix = String(b.prefix(2))
        let chapterStr = String(b.dropFirst(2).prefix(2))
        let number = String(b.suffix(4))
        guard let chapter = Int(chapterStr), Int(number) != nil else { return nil }
        return (prefix, chapter, number)
    }

    var lrvName: String? {
        guard let p = videoNameParts else { return nil }
        return "GL" + String(format: "%02d", p.chapter) + p.number + ".LRV"
    }
    var thmName: String? { isVideo ? base + ".THM" : nil }
    var gprName: String? { hasRaw ? base + ".GPR" : nil }
}

/// One physical file to fetch from the camera.
struct TransferFile: Hashable {
    let folder: String
    let name: String
    let size: Int64?
    let created: Date
    let modified: Date

    var cameraPath: String { "\(folder)/\(name)" }
}

// MARK: - Display entry (groups chapters and burst/lapse groups into one card)

struct MediaEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case video(chapters: [CameraFile])
        case photo(CameraFile)
        case photoGroup(CameraFile)
        case other(CameraFile)
    }

    let id: String
    let kind: Kind
    let created: Date

    var primary: CameraFile {
        switch kind {
        case .video(let chapters): return chapters[0]
        case .photo(let f), .photoGroup(let f), .other(let f): return f
        }
    }

    var isVideo: Bool { if case .video = kind { return true }; return false }
    var isPhoto: Bool {
        switch kind {
        case .photo, .photoGroup: return true
        default: return false
        }
    }

    /// The camera's low-res copy of the first chapter, for hover previews.
    /// Nil when the camera didn't make one (photos, and some video modes).
    var proxyPath: String? {
        guard case .video(let chapters) = kind, let ch = chapters.first,
              let lrv = ch.lrvName, (ch.lrvSize ?? 0) > 0 else { return nil }
        return "\(ch.folder)/\(lrv)"
    }

    var chapterCount: Int {
        if case .video(let c) = kind { return c.count }
        return 1
    }

    var groupCount: Int? {
        if case .photoGroup(let f) = kind { return f.group?.count }
        return nil
    }

    var displayName: String {
        switch kind {
        case .video(let chapters):
            if let p = chapters[0].videoNameParts, chapters.count > 1 {
                return "\(p.prefix)··\(p.number).\(chapters[0].ext)"
            }
            return chapters[0].name
        case .photoGroup(let f):
            return "\(f.group?.typeName ?? "Group") \(f.base.suffix(4))"
        case .photo(let f), .other(let f):
            return f.name
        }
    }

    /// Total bytes when knowable (videos/photos); nil for synthesized group members.
    var totalSize: Int64? {
        switch kind {
        case .video(let chapters): return chapters.reduce(0) { $0 + $1.size }
        case .photo(let f), .other(let f): return f.size
        case .photoGroup: return nil
        }
    }

    /// Physical camera files this entry expands to for transfer.
    func transferFiles(includeRaw: Bool, includeProxies: Bool) -> [TransferFile] {
        var out: [TransferFile] = []
        func add(_ folder: String, _ name: String, _ size: Int64?, _ c: Date, _ m: Date) {
            out.append(TransferFile(folder: folder, name: name, size: size, created: c, modified: m))
        }
        switch kind {
        case .video(let chapters):
            for ch in chapters {
                add(ch.folder, ch.name, ch.size, ch.created, ch.modified)
                if includeProxies {
                    if let lrv = ch.lrvName, (ch.lrvSize ?? 0) > 0 {
                        add(ch.folder, lrv, ch.lrvSize, ch.created, ch.modified)
                    }
                    if let thm = ch.thmName {
                        add(ch.folder, thm, nil, ch.created, ch.modified)
                    }
                }
            }
        case .photo(let f):
            add(f.folder, f.name, f.size, f.created, f.modified)
            if includeRaw, let gpr = f.gprName {
                add(f.folder, gpr, nil, f.created, f.modified)
            }
        case .photoGroup(let f):
            guard let g = f.group else {
                add(f.folder, f.name, f.size, f.created, f.modified)
                break
            }
            let suffix = String(f.base.suffix(4))
            let ext = f.ext
            for i in g.memberIDs {
                let member = String(format: "G%03d", i) + suffix + "." + ext
                add(f.folder, member, nil, f.created, f.modified)
                if includeRaw, f.hasRaw {
                    add(f.folder, String(format: "G%03d", i) + suffix + ".GPR", nil, f.created, f.modified)
                }
            }
        case .other(let f):
            add(f.folder, f.name, f.size, f.created, f.modified)
        }
        return out
    }

    /// Files whose presence at the destination marks this entry as transferred
    /// (main media only — raw/proxy toggles shouldn't flip the badge).
    var mainFiles: [TransferFile] {
        switch kind {
        case .video(let chapters):
            return chapters.map { TransferFile(folder: $0.folder, name: $0.name, size: $0.size, created: $0.created, modified: $0.modified) }
        default:
            return transferFiles(includeRaw: false, includeProxies: false)
        }
    }
}

// MARK: - Parsing

func parseMediaList(_ data: Data) throws -> [CameraFile] {
    let raw = try JSONDecoder().decode(RawMediaList.self, from: data)
    var files: [CameraFile] = []
    for dir in raw.media ?? [] {
        for f in dir.fs ?? [] {
            var group: GroupInfo?
            if let g = f.g.i64 {
                group = GroupInfo(
                    id: Int(g),
                    first: Int(f.b.i64 ?? 1),
                    last: Int(f.l.i64 ?? (f.b.i64 ?? 1)),
                    missing: Set((f.m ?? []).map { Int($0.value) }),
                    type: f.t ?? "b"
                )
            }
            files.append(CameraFile(
                folder: dir.d,
                name: f.n,
                size: f.s.i64 ?? 0,
                created: Date(timeIntervalSince1970: TimeInterval(f.cre.i64 ?? 0)),
                modified: Date(timeIntervalSince1970: TimeInterval(f.mod.i64 ?? f.cre.i64 ?? 0)),
                lrvSize: (f.glrv.i64 ?? f.ls.i64).flatMap { $0 > 0 ? $0 : nil },
                hasRaw: f.raw == "1",
                group: group
            ))
        }
    }
    return files
}

func buildEntries(_ files: [CameraFile]) -> [MediaEntry] {
    var entries: [MediaEntry] = []
    var videoGroups: [String: [CameraFile]] = [:]
    var videoOrder: [String] = []

    for f in files {
        if f.isVideo, let p = f.videoNameParts {
            let key = "\(f.folder)/\(p.prefix)\(p.number)"
            if videoGroups[key] == nil { videoOrder.append(key) }
            videoGroups[key, default: []].append(f)
        } else if f.group != nil {
            entries.append(MediaEntry(id: "\(f.folder)/group\(f.group!.id)-\(f.base)", kind: .photoGroup(f), created: f.created))
        } else if f.isPhoto {
            entries.append(MediaEntry(id: f.path, kind: .photo(f), created: f.created))
        } else if f.isVideo {
            entries.append(MediaEntry(id: f.path, kind: .video(chapters: [f]), created: f.created))
        } else {
            entries.append(MediaEntry(id: f.path, kind: .other(f), created: f.created))
        }
    }

    for key in videoOrder {
        let chapters = videoGroups[key]!.sorted { ($0.videoNameParts?.chapter ?? 0) < ($1.videoNameParts?.chapter ?? 0) }
        entries.append(MediaEntry(id: key, kind: .video(chapters: chapters), created: chapters[0].created))
    }

    return entries.sorted { $0.created > $1.created }
}

/// Slim per-video metadata from GET gopro/media/info, cached on disk.
/// HiLight offsets are seconds from the start (chapters get merged with a
/// running offset so tags land on the combined timeline).
struct MediaInfoLite: Codable, Equatable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
    var eis: Bool?
    var hilights: [Double] = []
}

// MARK: - Camera state / info

struct CameraStatus {
    var batteryPercent: Int?
    var sdRemainingKB: Int64?
    var sdCapacityKB: Int64?
    var busy: Bool
    var encoding: Bool

    // Open GoPro status IDs: 70 battery %, 54 SD remaining (KB), 117 SD capacity (KB),
    // 8 busy, 10 encoding.
    static func parse(_ data: Data) -> CameraStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? [String: Any] else { return nil }
        func num(_ id: String) -> Int64? {
            if let n = status[id] as? NSNumber { return n.int64Value }
            return nil
        }
        return CameraStatus(
            batteryPercent: num("70").map(Int.init),
            sdRemainingKB: num("54"),
            sdCapacityKB: num("117"),
            busy: num("8") == 1,
            encoding: num("10") == 1
        )
    }
}

struct CameraInfo {
    var modelName: String
    var serial: String
    var firmware: String

    static func parse(_ data: Data) -> CameraInfo? {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let nested = obj["info"] as? [String: Any] { obj = nested }
        let model = (obj["model_name"] as? String) ?? "GoPro"
        let serial = (obj["serial_number"] as? String) ?? ""
        let fw = (obj["firmware_version"] as? String) ?? ""
        return CameraInfo(modelName: model, serial: serial, firmware: fw)
    }
}
