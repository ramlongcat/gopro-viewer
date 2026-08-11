import AppKit
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

    private func fetch(key: String, cachedOnDisk: Bool, request: () async throws -> Data) async -> NSImage? {
        if let img = mem.object(forKey: key as NSString) { return img }
        let file = diskURL(key)
        if cachedOnDisk, let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            mem.setObject(img, forKey: key as NSString)
            return img
        }
        while await isPaused() {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await gate.acquire()
        var image: NSImage?
        if !Task.isCancelled,
           let data = try? await request(), data.count > 100,
           let img = NSImage(data: data) {
            if cachedOnDisk { try? data.write(to: file) }
            mem.setObject(img, forKey: key as NSString)
            image = img
        }
        await gate.release()
        return image
    }

    func thumbnail(client: GoProClient, path: String, sizeTag: Int64) async -> NSImage? {
        await fetch(key: "t|\(client.cacheKey)|\(path)|\(sizeTag)", cachedOnDisk: true) {
            try await client.thumbnail(path: path)
        }
    }

    /// Larger preview for the viewer; memory-cached only.
    func screennail(client: GoProClient, path: String, sizeTag: Int64) async -> NSImage? {
        await fetch(key: "s|\(client.cacheKey)|\(path)|\(sizeTag)", cachedOnDisk: false) {
            try await client.screennail(path: path)
        }
    }
}
