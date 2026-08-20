import Foundation

/// HTTP client for the Open GoPro wired API (camera at 172.2X.1YZ.51:8080
/// over the USB NCM network interface).
final class GoProClient: @unchecked Sendable {
    let ip: String
    let base: URL
    /// Used to namespace the on-disk thumbnail cache; set to the camera serial once known.
    var cacheKey: String

    private let api: URLSession
    private let media: URLSession
    /// Ranged reads of the media files themselves (telemetry extraction).
    /// Its own session for the resource timeout: if a firmware ever ignored
    /// the Range header and started sending a whole clip, that cap is what
    /// stops us buffering gigabytes.
    private let meta: URLSession

    init(ip: String) {
        self.ip = ip
        self.base = URL(string: "http://\(ip):8080")!
        self.cacheKey = ip

        let apiCfg = URLSessionConfiguration.ephemeral
        apiCfg.timeoutIntervalForRequest = 6
        apiCfg.waitsForConnectivity = false
        api = URLSession(configuration: apiCfg)

        let mediaCfg = URLSessionConfiguration.ephemeral
        mediaCfg.timeoutIntervalForRequest = 20
        mediaCfg.waitsForConnectivity = false
        mediaCfg.httpMaximumConnectionsPerHost = 6
        media = URLSession(configuration: mediaCfg)

        let metaCfg = URLSessionConfiguration.ephemeral
        // Generous: the camera occasionally stalls ten-odd seconds on a range
        // request deep inside a multi-gigabyte clip. The resource cap is the
        // real guard — it bounds what a firmware that ignored Range could cost.
        metaCfg.timeoutIntervalForRequest = 30
        metaCfg.timeoutIntervalForResource = 90
        metaCfg.waitsForConnectivity = false
        metaCfg.httpMaximumConnectionsPerHost = 6
        meta = URLSession(configuration: metaCfg)
    }

    // MARK: Requests

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    private func get(_ path: String, _ query: [String: String] = [:], session: URLSession? = nil,
                     what: String) async throws -> Data {
        let (data, resp) = try await (session ?? api).data(from: url(path, query))
        guard let http = resp as? HTTPURLResponse else { throw GoProError.badResponse(what) }
        guard http.statusCode == 200 else { throw GoProError.http(http.statusCode, what) }
        return data
    }

    // MARK: API

    enum ProbeResult { case ok, denied, unreachable }

    /// Quick liveness check used during discovery. Own session for a short
    /// timeout. `strict` additionally requires the version JSON body — used
    /// for the localhost (emulator) candidate so an unrelated local server on
    /// port 8080 can't masquerade as a camera.
    static func probe(ip: String, strict: Bool = false) async -> ProbeResult {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 2
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let u = URL(string: "http://\(ip):8080/gopro/version") else { return .unreachable }
        do {
            let (data, resp) = try await session.data(from: u)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .unreachable }
            if strict {
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["version"] != nil else { return .unreachable }
            }
            return .ok
        } catch {
            // A macOS Local Network privacy denial surfaces as "offline" (-1009),
            // while an asleep/unplugged camera gives no-route or timeout errors.
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet {
                return .denied
            }
            return .unreachable
        }
    }

    func enableWiredControl() async throws {
        _ = try await get("gopro/camera/control/wired_usb", ["p": "1"], what: "Enable wired control")
    }

    func cameraInfo() async throws -> CameraInfo {
        let data = try await get("gopro/camera/info", what: "Camera info")
        guard let info = CameraInfo.parse(data) else { throw GoProError.badResponse("Camera info") }
        return info
    }

    func state() async throws -> CameraStatus {
        let data = try await get("gopro/camera/state", what: "Camera state")
        guard let st = CameraStatus.parse(data) else { throw GoProError.badResponse("Camera state") }
        return st
    }

    func mediaList() async throws -> [CameraFile] {
        let data = try await get("gopro/media/list", session: media, what: "Media list")
        return try parseMediaList(data)
    }

    /// Duration, resolution, frame rate, HyperSmooth flag, and HiLight tags
    /// from media info ("dur"/"w"/"h"/"fps"/"fps_denom"/"eis"/"hi").
    func mediaInfoLite(path: String) async -> MediaInfoLite? {
        guard let data = try? await get("gopro/media/info", ["path": path], session: media, what: "Media info"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ key: String) -> Double? {
            if let s = obj[key] as? String { return Double(s) }
            if let n = obj[key] as? NSNumber { return n.doubleValue }
            return nil
        }
        var info = MediaInfoLite()
        info.duration = num("dur")
        info.width = num("w").map(Int.init)
        info.height = num("h").map(Int.init)
        if let f = num("fps"), let d = num("fps_denom"), d > 0 { info.fps = f / d }
        info.eis = num("eis").map { $0 == 1 }
        if let hi = obj["hi"] as? [Any] {
            info.hilights = hi.compactMap { v in
                if let s = v as? String { return Double(s).map { $0 / 1000 } }
                if let n = v as? NSNumber { return n.doubleValue / 1000 }
                return nil
            }
        }
        return info
    }

    /// Full media-info JSON as display key/value pairs — the detail inspector
    /// shows everything the camera reports, not just the fields we model.
    func mediaInfoRaw(path: String) async throws -> [String: String] {
        let data = try await get("gopro/media/info", ["path": path], session: media, what: "Media info")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoProError.badResponse("Media info")
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let arr = v as? [Any] {
                out[k] = arr.map { "\($0)" }.joined(separator: ", ")
            } else {
                out[k] = "\(v)"
            }
        }
        return out
    }

    /// GPMF telemetry (the GPS track) for one video.
    ///
    /// Read out of the clip's own `gpmd` track rather than from
    /// `/gopro/media/gpmf`: that endpoint returns a fixed-size header blob
    /// carrying the HiLight table and no sensor data at all, so every map
    /// drawn from it was empty. See `MP4`.
    func gpmdTrack(path: String) async throws -> Data {
        let url = downloadURL(path: path)
        let total = try await rangedLength(url)
        return try await MP4.gpmdTrack(length: total) { offset, count in
            try await self.ranged(url, offset: offset, count: count).0
        }
    }

    /// Front of a file, without pulling the whole thing — enough for a
    /// photo's EXIF block.
    func fileHeader(path: String, bytes: Int) async throws -> Data {
        try await ranged(downloadURL(path: path), offset: 0, count: bytes).0
    }

    /// File length from a 16-byte ranged read: the reply carries
    /// "Content-Range: bytes 0-15/<total>". Cheaper than HEAD, and one less
    /// method to depend on the camera answering.
    private func rangedLength(_ url: URL) async throws -> Int64 {
        let (_, http) = try await ranged(url, offset: 0, count: 16)
        guard let header = http.value(forHTTPHeaderField: "Content-Range"),
              let total = header.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 else {
            throw GoProError.badResponse("Telemetry: file length")
        }
        return total
    }

    private func ranged(_ url: URL, offset: Int64, count: Int) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await meta.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GoProError.badResponse("Telemetry") }
        // 200 means the Range header was ignored and the whole clip is coming.
        guard http.statusCode == 206 else { throw GoProError.http(http.statusCode, "Telemetry") }
        return (data, http)
    }

    func thumbnail(path: String) async throws -> Data {
        try await get("gopro/media/thumbnail", ["path": path], session: media, what: "Thumbnail")
    }

    func screennail(path: String) async throws -> Data {
        try await get("gopro/media/screennail", ["path": path], session: media, what: "Preview")
    }

    /// Turbo transfer speeds up bulk USB downloads; the camera may ignore other
    /// commands while enabled, so it's only used around batch transfers.
    func setTurbo(_ on: Bool) async {
        _ = try? await get("gopro/media/turbo_transfer", ["p": on ? "1" : "0"], what: "Turbo")
    }

    func keepAlive() async {
        _ = try? await get("gopro/camera/keep_alive", what: "Keep alive")
    }

    // The camera's media-delete endpoints are deliberately not implemented:
    // this app must never be able to delete files from the GoPro.

    /// Direct download URL (supports HTTP Range).
    func downloadURL(path: String) -> URL {
        base.appendingPathComponent("videos/DCIM").appendingPathComponent(path)
    }

    /// Whole-file fetch into memory; used for full-resolution photo previews.
    func fileData(path: String) async throws -> Data {
        let (data, resp) = try await media.data(from: downloadURL(path: path))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoProError.badResponse("File \(path)")
        }
        return data
    }
}
