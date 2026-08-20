import AppKit
import CoreGraphics
import Foundation

/// Limits concurrent camera requests so thumbnail bursts don't starve the link.
actor Gate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ n: Int) { available = n }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Fetches and caches camera thumbnails (memory + disk). Waits politely while
/// a batch transfer owns the camera (turbo mode makes it unresponsive anyway).
final class ThumbnailLoader: @unchecked Sendable {
    private let mem = NSCache<NSString, NSImage>()
    private let gate = Gate(4)
    private let dir: URL
    @MainActor weak var transfers: TransferManager?

    init() {
        mem.countLimit = 800
        // Grid images are the camera's screennails, several megabytes each
        // once decoded — cap the cache by weight, not just by count.
        mem.totalCostLimit = 320 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = caches.appendingPathComponent("GoProOffload/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func diskURL(_ key: String) -> URL {
        dir.appendingPathComponent(shortHash(key) + ".jpg")
    }

    private func isPaused() async -> Bool {
        await MainActor.run { transfers?.isActive ?? false }
    }

    private func fetch(key: String, cachedOnDisk: Bool, trim: Bool,
                       waitsForCamera: Bool = true,
                       request: () async throws -> Data) async -> NSImage? {
        if let img = mem.object(forKey: key as NSString) { return img }
        let file = diskURL(key)
        if cachedOnDisk, let data = try? Data(contentsOf: file), let img = decode(data, trim: trim) {
            mem.setObject(img, forKey: key as NSString, cost: cost(img))
            return img
        }
        while waitsForCamera, await isPaused() {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await gate.acquire()
        var image: NSImage?
        if !Task.isCancelled,
           let data = try? await request(), data.count > 100,
           let img = decode(data, trim: trim) {
            if cachedOnDisk { try? data.write(to: file) }
            mem.setObject(img, forKey: key as NSString, cost: cost(img))
            image = img
        }
        await gate.release()
        return image
    }

    /// Rough decoded weight, for the memory cache's cost limit.
    private func cost(_ img: NSImage) -> Int {
        Int(img.size.width * img.size.height) * 4
    }

    private func decode(_ data: Data, trim: Bool) -> NSImage? {
        guard let img = NSImage(data: data) else { return nil }
        return trim ? trimLetterbox(img) : img
    }

    private func isVideo(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.uppercased()
        return ext == "MP4" || ext == "360"
    }

    func thumbnail(client: GoProClient, path: String, sizeTag: Int64) async -> NSImage? {
        await fetch(key: "t|\(client.cacheKey)|\(path)|\(sizeTag)",
                    cachedOnDisk: true, trim: isVideo(path)) {
            try await client.thumbnail(path: path)
        }
    }

    /// The grid's sharp pass: a camera thumbnail is smaller than a Retina
    /// cell, so it always looks soft. This is the same screennail the viewer
    /// uses, cached to disk because the grid comes back to it constantly.
    func gridImage(client: GoProClient, path: String, sizeTag: Int64) async -> NSImage? {
        await fetch(key: "g|\(client.cacheKey)|\(path)|\(sizeTag)",
                    cachedOnDisk: true, trim: isVideo(path)) {
            try await client.screennail(path: path)
        }
    }

    /// A frame lifted from a clip's proxy, for grid tiles.
    ///
    /// The camera's own video thumbnail is 160x120 — a 16:9 frame letterboxed
    /// into a 4:3 box — and `screennail` answers 400 for videos, so there is
    /// nothing sharper to ask it for. Decoding a frame out of the .LRV gives
    /// the real shape at a usable size, and no padding to trim.
    func videoFrame(url: URL, maxPixel: Int, sizeTag: Int64, cacheKey: String) async -> NSImage? {
        await fetch(key: "v|\(cacheKey)|\(url.lastPathComponent)|\(sizeTag)|\(maxPixel)",
                    cachedOnDisk: true, trim: false) {
            try await LocalLibrary.preview(of: url, maxPixel: maxPixel)
        }
    }

    /// Larger preview for the viewer; memory-cached only.
    func screennail(client: GoProClient, path: String, sizeTag: Int64) async -> NSImage? {
        await fetch(key: "s|\(client.cacheKey)|\(path)|\(sizeTag)",
                    cachedOnDisk: false, trim: isVideo(path)) {
            try await client.screennail(path: path)
        }
    }

    /// Grid tile or viewer preview for a file already on this Mac. Nothing
    /// here touches the camera, so it neither waits for a running copy nor
    /// trims letterbox padding (local files have none).
    func localImage(url: URL, maxPixel: Int, sizeTag: Int64) async -> NSImage? {
        await fetch(key: "l|\(url.path)|\(sizeTag)|\(maxPixel)",
                    cachedOnDisk: true, trim: false, waitsForCamera: false) {
            try await LocalLibrary.preview(of: url, maxPixel: maxPixel)
        }
    }
}

/// Camera firmware renders a video thumbnail into a fixed box and pads what's
/// left with black, so a 16:9 clip comes back with bars baked into the JPEG.
/// The grid fills its 4:3 cell with the image, and baked-in bars survive that
/// crop — so trim them off the decoded frame instead. (The emulator builds its
/// thumbnails with QuickLook, which pads nothing; that's why the two looked
/// different.) Only symmetric, genuinely black borders go: a dark frame keeps
/// its own edges.
func trimLetterbox(_ image: NSImage) -> NSImage {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          cg.width > 16, cg.height > 16 else { return image }
    let w = cg.width, h = cg.height
    let rowBytes = w * 4
    var buf = [UInt8](repeating: 0, count: rowBytes * h)
    let ok: Bool = buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return image }

    // Not zero: JPEG ringing along the edge of the frame never lands on pure
    // black. Every other pixel is enough to spot a bar.
    let limit: UInt8 = 20
    func lit(_ i: Int) -> Bool { buf[i] > limit || buf[i + 1] > limit || buf[i + 2] > limit }
    func rowIsBlack(_ y: Int) -> Bool {
        !stride(from: 0, to: w, by: 2).contains { lit(y * rowBytes + $0 * 4) }
    }
    func colIsBlack(_ x: Int) -> Bool {
        !stride(from: 0, to: h, by: 2).contains { lit($0 * rowBytes + x * 4) }
    }

    var top = 0, bottom = 0, left = 0, right = 0
    while top < h / 2, rowIsBlack(top) { top += 1 }
    while bottom < h / 2, rowIsBlack(h - 1 - bottom) { bottom += 1 }
    while left < w / 2, colIsBlack(left) { left += 1 }
    while right < w / 2, colIsBlack(w - 1 - right) { right += 1 }

    // Padding is symmetric; a one-sided black edge is the picture itself.
    if top == 0 || bottom == 0 || abs(top - bottom) > max(2, h / 40) { top = 0; bottom = 0 }
    if left == 0 || right == 0 || abs(left - right) > max(2, w / 40) { left = 0; right = 0 }
    guard top + bottom + left + right > 0 else { return image }

    // CGImage crops from the top-left, the same corner the bitmap starts at.
    let rect = CGRect(x: left, y: top, width: w - left - right, height: h - top - bottom)
    guard rect.width > 16, rect.height > 16, let cut = cg.cropping(to: rect) else { return image }
    return NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
}
