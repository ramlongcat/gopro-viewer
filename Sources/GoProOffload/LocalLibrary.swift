import AVFoundation
import AppKit
import Foundation
import IOKit.ps

/// Where the grid is looking. Both sources produce the same `CameraFile`
/// values, so everything downstream — chapter/burst folding, filters, the
/// grid, the viewer — works without knowing which one it is.
enum MediaSource: String, CaseIterable, Identifiable, Hashable {
    case camera, mac

    var id: String { rawValue }

    var symbol: String { self == .camera ? "web.camera" : "apple.logo" }
}

/// Reads media already copied to this Mac. `CameraFile.folder` holds a real
/// directory path here rather than a camera folder name, which makes
/// `CameraFile.path` a filesystem path the viewer can open directly.
enum LocalLibrary {
    private static let listed: Set<String> = ["MP4", "360", "JPG"]
    private static let sidecars: Set<String> = ["LRV", "THM", "GPR"]

    /// Walks the destination once and folds each directory's files together,
    /// so a clip finds its own proxy and a JPEG finds its RAW.
    static func scan(_ root: URL) -> [CameraFile] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey,
                                         .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        struct Stat {
            let size: Int64
            let created: Date
            let modified: Date
        }
        var byFolder: [String: [String: Stat]] = [:]
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            // Same guards as the copied-file index: a destination pointed at a
            // huge tree shouldn't hang the app.
            if seen > 200_000 { break }
            if walk.level > 6 { walk.skipDescendants(); continue }
            let ext = url.pathExtension.uppercased()
            guard listed.contains(ext) || sidecars.contains(ext),
                  let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey,
                                                           .contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, let size = v.fileSize else { continue }
            let modified = v.contentModificationDate ?? .distantPast
            byFolder[url.deletingLastPathComponent().path, default: [:]][url.lastPathComponent] =
                Stat(size: Int64(size), created: v.creationDate ?? modified, modified: modified)
        }

        var out: [CameraFile] = []
        for (folder, files) in byFolder {
            for (name, stat) in files {
                let ext = (name as NSString).pathExtension.uppercased()
                guard listed.contains(ext) else { continue }
                let base = (name as NSString).deletingPathExtension
                // The proxy is named GLxxyyyy.LRV beside GXxxyyyy.MP4; if the
                // copy included proxies, hover previews work here too.
                var lrvSize: Int64?
                if base.count == 8, ext == "MP4" || ext == "360" {
                    lrvSize = files["GL" + base.dropFirst(2) + ".LRV"]?.size
                }
                out.append(CameraFile(folder: folder,
                                      name: name,
                                      size: stat.size,
                                      created: stat.created,
                                      modified: stat.modified,
                                      lrvSize: lrvSize,
                                      hasRaw: files[base + ".GPR"] != nil,
                                      // Burst grouping lives in the camera's
                                      // list, not on disk — local shots stand
                                      // alone.
                                      group: nil))
            }
        }
        return out.sorted { $0.created > $1.created }
    }

    /// Duration, resolution and frame rate straight off the file, so local
    /// clips get the same badges and inspector rows as camera ones.
    static func info(for url: URL) async -> MediaInfoLite? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        var info = MediaInfoLite()
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            info.duration = d.seconds
        }
        if let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let shown = size.applying(transform)
            info.width = Int(abs(shown.width))
            info.height = Int(abs(shown.height))
        }
        if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
            info.fps = Double(fps)
        }
        return info == MediaInfoLite() ? nil : info
    }

    /// A JPEG rendition of any local item, for the grid and the viewer. Video
    /// frames come from AVFoundation; stills go through ImageIO, which uses
    /// the embedded preview when the file has one.
    static func preview(of url: URL, maxPixel: Int) async throws -> Data {
        let cg: CGImage
        if ["MP4", "360", "LRV"].contains(url.pathExtension.uppercased()) || !url.isFileURL {
            // The MIME hint is what lets an .LRV — a plain MP4 by another
            // name — be read straight off the camera over HTTP.
            let gen = AVAssetImageGenerator(asset: AVURLAsset(
                url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            // Any nearby keyframe will do; an exact seek would decode a whole
            // GOP for a thumbnail.
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            cg = try await gen.image(at: .zero).image
        } else {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  ] as CFDictionary)
            else { throw CocoaError(.fileReadCorruptFile) }
            cg = img
        }
        guard let data = NSBitmapImageRep(cgImage: cg)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// This Mac's own battery, so the sidebar can show the same gauge for it
    /// as for the camera. Nil on a desktop, which has none.
    struct MacPower {
        let percent: Int
        let charging: Bool
        let charged: Bool
        let onAC: Bool
        /// Seconds, when the system is willing to estimate one yet.
        let toFull: TimeInterval?
        let toEmpty: TimeInterval?
    }

    static func power() -> MacPower? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let now = d[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = d[kIOPSMaxCapacityKey as String] as? Int, max > 0 else { continue }
            // These come back in minutes, and -1 means "not yet known".
            func minutes(_ key: String) -> TimeInterval? {
                guard let m = d[key] as? Int, m > 0 else { return nil }
                return TimeInterval(m) * 60
            }
            return MacPower(percent: Int((Double(now) / Double(max) * 100).rounded()),
                            charging: d[kIOPSIsChargingKey as String] as? Bool ?? false,
                            charged: d[kIOPSIsChargedKey as String] as? Bool ?? false,
                            onAC: (d[kIOPSPowerSourceStateKey as String] as? String)
                                == (kIOPSACPowerValue as String),
                            toFull: minutes(kIOPSTimeToFullChargeKey as String),
                            toEmpty: minutes(kIOPSTimeToEmptyKey as String))
        }
        return nil
    }

    /// Free and total bytes of the volume holding the destination.
    static func volumeSpace(at url: URL) -> (free: Int64, total: Int64)? {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage,
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return (Int64(free), Int64(total))
    }
}
