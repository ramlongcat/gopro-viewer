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

    /// Quick liveness check used during discovery. Own session for a short timeout.
    static func probe(ip: String) async -> ProbeResult {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 2
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let u = URL(string: "http://\(ip):8080/gopro/version") else { return .unreachable }
        do {
            let (_, resp) = try await session.data(from: u)
            return (resp as? HTTPURLResponse)?.statusCode == 200 ? .ok : .unreachable
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
