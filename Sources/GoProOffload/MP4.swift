import Foundation

/// Pulls the GoPro telemetry track out of an MP4 by reading only the handful
/// of byte ranges it actually occupies.
///
/// This exists because `/gopro/media/gpmf` does not return telemetry. On
/// HERO13 that endpoint answers a fixed 25600-byte blob holding the global
/// metadata header and the HiLight table, and nothing else — no GPS, no
/// sensor streams, whatever the clip contains. The real telemetry only ever
/// exists inside the file, in a track the camera serves over plain HTTP with
/// Range support, so we go and get it ourselves.
enum MP4 {
    /// Every `gpmd` sample of the telemetry track, concatenated.
    ///
    /// Each sample is a self-contained GPMF payload — one `DEVC` per second or
    /// so of recording — which is what makes both the concatenation and the
    /// sampling below safe: `GPMF` walks the result as a run of siblings.
    ///
    /// `read` is handed an offset and a byte count and must return exactly
    /// that range. `maxChunks` bounds the work: telemetry is stored one chunk
    /// per second, interleaved through the file, and each chunk costs its own
    /// ranged request — 1460 of them on a 90-minute clip, two minutes of
    /// round-trips. All the inspector wants is where the clip was shot, so
    /// past the budget we read an even spread across the recording: enough
    /// fixes to place it, and enough coverage to still find a lock that only
    /// happened during part of it.
    static func gpmdTrack(length: Int64,
                          maxChunks: Int = 60,
                          read: @escaping @Sendable (Int64, Int) async throws -> Data) async throws -> Data {
        let moov = try await moovBody(length: length, read: read)
        guard let trak = children(moov).first(where: {
            $0.type == "trak" && isTelemetryTrack($0.body)
        }) else { throw GoProError.badResponse("Telemetry: no gpmd track") }

        guard let stbl = box(trak.body, ["mdia", "minf", "stbl"]),
              let stsz = box(stbl, ["stsz"]),
              let stsc = box(stbl, ["stsc"]),
              let offsets = chunkOffsets(stbl) else {
            throw GoProError.badResponse("Telemetry: unreadable sample table")
        }

        let sizes = sampleSizes(stsz)
        let perChunk = samplesPerChunk(stsc, chunks: offsets.count)
        var spans: [(offset: Int64, size: Int)] = []
        var sample = 0
        for (i, offset) in offsets.enumerated() {
            let n = i < perChunk.count ? perChunk[i] : 0
            guard n > 0, sample + n <= sizes.count else { break }
            let bytes = sizes[sample..<(sample + n)].reduce(0, +)
            if bytes > 0 { spans.append((offset, bytes)) }
            sample += n
        }
        guard !spans.isEmpty else { throw GoProError.badResponse("Telemetry: empty track") }

        var picks = spans
        if spans.count > maxChunks {
            let step = (spans.count + maxChunks - 1) / maxChunks
            picks = Swift.stride(from: 0, to: spans.count, by: step).map { spans[$0] }
        }

        var parts = [Data?](repeating: nil, count: picks.count)
        await withTaskGroup(of: (Int, Data?).self) { group in
            var next = 0
            // Matches the media session's per-host connection cap; queueing
            // more just moves the wait.
            let width = min(6, picks.count)
            // A read that fails is dropped rather than thrown: the camera
            // stalls on a range request now and then, and one missing chunk
            // costs a second of track where giving up costs the whole map.
            while next < width {
                let i = next, span = picks[i]
                group.addTask { (i, try? await read(span.offset, span.size)) }
                next += 1
            }
            while let (i, data) = await group.next() {
                parts[i] = data
                if next < picks.count {
                    let j = next, span = picks[j]
                    group.addTask { (j, try? await read(span.offset, span.size)) }
                    next += 1
                }
            }
        }
        return parts.compactMap { $0 }.reduce(into: Data()) { $0.append($1) }
    }

    /// Same extraction against a clip already copied to this Mac.
    static func gpmdTrack(fileURL: URL, maxChunks: Int = 240) async throws -> Data {
        let handle = try Handle(url: fileURL)
        return try await gpmdTrack(length: handle.size, maxChunks: maxChunks) { offset, count in
            try handle.read(at: offset, count: count)
        }
    }

    /// One open file, read from several tasks at once.
    private final class Handle: @unchecked Sendable {
        let size: Int64
        private let file: FileHandle
        private let lock = NSLock()

        init(url: URL) throws {
            file = try FileHandle(forReadingFrom: url)
            size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        deinit { try? file.close() }

        func read(at offset: Int64, count: Int) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            try file.seek(toOffset: UInt64(offset))
            return try file.read(upToCount: count) ?? Data()
        }
    }

    // MARK: Atoms

    /// Walks the top-level boxes by their headers alone — 16 bytes per hop,
    /// three or four hops, because GoPro writes `moov` last.
    private static func moovBody(length: Int64,
                                 read: @Sendable (Int64, Int) async throws -> Data) async throws -> Data {
        var offset: Int64 = 0
        var hops = 0
        while offset < length, hops < 64 {
            hops += 1
            let head = try await read(offset, 16)
            guard head.count >= 8 else { break }
            var size = Int64(be32(head, 0))
            var header: Int64 = 8
            if size == 1 {
                guard head.count >= 16 else { break }
                size = Int64(bitPattern: be64(head, 8))
                header = 16
            } else if size == 0 {
                size = length - offset
            }
            guard size >= header else { break }
            if ascii(head, 4) == "moov" {
                // 64 MB is far past any real moov — 1.4 MB on a 5.5 GB clip —
                // and stops a corrupt header from asking for the whole disk.
                return try await read(offset + header, Int(min(size - header, 64 << 20)))
            }
            offset += size
        }
        throw GoProError.badResponse("Telemetry: no moov")
    }

    /// GoPro's telemetry track is the one whose handler names itself
    /// "GoPro MET" — the handler type alone (`meta`) isn't unique, a clip has
    /// several metadata tracks.
    private static func isTelemetryTrack(_ trak: Data) -> Bool {
        guard let hdlr = box(trak, ["mdia", "hdlr"]),
              let name = String(data: hdlr, encoding: .isoLatin1) else { return false }
        return name.contains("GoPro MET")
    }

    private static func children(_ d: Data) -> [(type: String, body: Data)] {
        var out: [(String, Data)] = []
        var o = 0
        while o + 8 <= d.count {
            var size = Int(be32(d, o))
            var header = 8
            if size == 1 {
                guard o + 16 <= d.count else { break }
                size = Int(be64(d, o + 8))
                header = 16
            } else if size == 0 {
                size = d.count - o
            }
            guard size >= header, o + size <= d.count else { break }
            out.append((ascii(d, o + 4), d.subdata(in: (o + header)..<(o + size))))
            o += size
        }
        return out
    }

    /// First box at a nested path, e.g. ["mdia", "minf", "stbl"].
    private static func box(_ d: Data, _ path: [String]) -> Data? {
        var current = d
        for want in path {
            guard let hit = children(current).first(where: { $0.type == want }) else { return nil }
            current = hit.body
        }
        return current
    }

    // MARK: Sample table

    private static func sampleSizes(_ stsz: Data) -> [Int] {
        guard stsz.count >= 12 else { return [] }
        let uniform = Int(be32(stsz, 4))
        let count = Int(be32(stsz, 8))
        if uniform > 0 { return Array(repeating: uniform, count: count) }
        guard stsz.count >= 12 + 4 * count else { return [] }
        return (0..<count).map { Int(be32(stsz, 12 + 4 * $0)) }
    }

    private static func chunkOffsets(_ stbl: Data) -> [Int64]? {
        if let stco = box(stbl, ["stco"]), stco.count >= 8 {
            let n = Int(be32(stco, 4))
            guard stco.count >= 8 + 4 * n else { return nil }
            return (0..<n).map { Int64(be32(stco, 8 + 4 * $0)) }
        }
        if let co64 = box(stbl, ["co64"]), co64.count >= 8 {
            let n = Int(be32(co64, 4))
            guard co64.count >= 8 + 8 * n else { return nil }
            return (0..<n).map { Int64(bitPattern: be64(co64, 8 + 8 * $0)) }
        }
        return nil
    }

    /// `stsc` stores runs — "from chunk N on, this many samples each" — so
    /// expand it to one count per chunk.
    private static func samplesPerChunk(_ stsc: Data, chunks: Int) -> [Int] {
        guard stsc.count >= 8, chunks > 0 else { return [] }
        let n = Int(be32(stsc, 4))
        guard n > 0, stsc.count >= 8 + 12 * n else { return [] }
        let runs: [(first: Int, per: Int)] = (0..<n).map {
            (Int(be32(stsc, 8 + 12 * $0)), Int(be32(stsc, 12 + 12 * $0)))
        }
        var out = [Int](repeating: 0, count: chunks)
        for (i, run) in runs.enumerated() where run.first >= 1 {
            let last = i + 1 < runs.count ? runs[i + 1].first - 1 : chunks
            guard last >= run.first else { continue }
            for chunk in run.first...last where chunk <= chunks { out[chunk - 1] = run.per }
        }
        return out
    }

    // MARK: Big-endian reads

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
    private static func be64(_ d: Data, _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(d[o + $1]) }
    }
    private static func ascii(_ d: Data, _ o: Int) -> String {
        String(bytes: d[o..<(o + 4)], encoding: .ascii) ?? ""
    }
}
