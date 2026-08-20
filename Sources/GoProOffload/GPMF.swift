import Foundation

struct GPSPoint: Sendable {
    let lat: Double
    let lon: Double
    let alt: Double     // meters
    let speed: Double   // m/s (2D)
    let fix: Int        // -1 unknown, 0 no lock, 2 = 2D, 3 = 3D
    let dop: Double     // dilution of precision (-1 unknown; < 5 is good)
}

/// Just enough GPMF (GoPro Metadata Format) to pull the GPS track out of the
/// gpmd stream served by GET gopro/media/gpmf. Layout is big-endian KLV:
/// FourCC + 1-byte type + 1-byte struct size + 2-byte repeat count, payloads
/// padded to 4 bytes, type 0 nests. GPS arrives as GPS5 samples with sibling
/// SCAL/GPSF/GPSP, or as self-contained GPS9 rows on HERO11 and later.
enum GPMF {
    static func gpsTrack(from data: Data) -> [GPSPoint] {
        var points: [GPSPoint] = []
        data.withUnsafeBytes { buf in
            parse(buf, 0, buf.count, &points)
        }
        return points
    }

    private static func parse(_ b: UnsafeRawBufferPointer, _ start: Int, _ length: Int,
                              _ points: inout [GPSPoint]) {
        var off = start
        let end = min(start + length, b.count)
        // Per-container stream state: SCAL/GPSF/GPSP precede GPS5 in a STRM.
        var scal: [Double] = []
        var fix = -1
        var dop = -1.0
        while off + 8 <= end {
            guard isKeyChar(b[off]), isKeyChar(b[off + 1]),
                  isKeyChar(b[off + 2]), isKeyChar(b[off + 3]) else { break }
            let key = String(bytes: [b[off], b[off + 1], b[off + 2], b[off + 3]], encoding: .ascii)!
            let type = b[off + 4]
            let ssize = Int(b[off + 5])
            let count = Int(b[off + 6]) << 8 | Int(b[off + 7])
            let payload = ssize * count
            let body = off + 8
            let next = body + ((payload + 3) & ~3)

            if type == 0 {
                parse(b, body, min(payload, max(0, end - body)), &points)
            } else if body + payload <= end {
                switch key {
                case "SCAL":
                    scal = (0..<count).compactMap { i in
                        switch ssize {
                        case 4: return Double(i32(b, body + i * 4))
                        case 2: return Double(i16(b, body + i * 2))
                        default: return nil
                        }
                    }
                case "GPSF" where payload >= 4:
                    fix = Int(u32(b, body))
                case "GPSP" where payload >= 2:
                    dop = Double(u16(b, body)) / 100
                case "GPS5" where ssize == 20:
                    let s = scal.count >= 5 ? scal : [10_000_000, 10_000_000, 1000, 1000, 100]
                    for i in 0..<count {
                        let o = body + i * 20
                        points.append(GPSPoint(
                            lat: Double(i32(b, o)) / nz(s[0]),
                            lon: Double(i32(b, o + 4)) / nz(s[1]),
                            alt: Double(i32(b, o + 8)) / nz(s[2]),
                            speed: Double(i32(b, o + 12)) / nz(s[3]),
                            fix: fix, dop: dop))
                    }
                case "GPS9" where ssize >= 32:   // lat, lon, alt, 2D, 3D, days, secs, DOP, fix
                    let s = scal.count >= 5 ? scal : [10_000_000, 10_000_000, 1000, 1000, 100]
                    for i in 0..<count {
                        let o = body + i * ssize
                        points.append(GPSPoint(
                            lat: Double(i32(b, o)) / nz(s[0]),
                            lon: Double(i32(b, o + 4)) / nz(s[1]),
                            alt: Double(i32(b, o + 8)) / nz(s[2]),
                            speed: Double(i32(b, o + 12)) / nz(s[3]),
                            fix: Int(i16(b, o + 30)),
                            dop: Double(i16(b, o + 28)) / 100))
                    }
                default:
                    break
                }
            }
            guard next > off else { break }   // corrupt zero-size item
            off = next
        }
    }

    private static func isKeyChar(_ c: UInt8) -> Bool { c >= 0x20 && c < 0x7F }
    private static func nz(_ v: Double) -> Double { v == 0 ? 1 : v }

    private static func u32(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    private static func i32(_ b: UnsafeRawBufferPointer, _ o: Int) -> Int32 {
        Int32(bitPattern: u32(b, o))
    }
    private static func u16(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt16 {
        UInt16(b[o]) << 8 | UInt16(b[o + 1])
    }
    private static func i16(_ b: UnsafeRawBufferPointer, _ o: Int) -> Int16 {
        Int16(bitPattern: u16(b, o))
    }
}
