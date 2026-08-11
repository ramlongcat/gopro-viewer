import Foundation
import CryptoKit

/// GoPro media-list numbers arrive as JSON strings ("s":"140087814") on some
/// firmware versions and as bare numbers on others — accept both.
struct FlexInt: Decodable, Hashable {
    let value: Int64
    init(_ v: Int64) { value = v }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = Int64(d) }
        else if let s = try? c.decode(String.self) { value = Int64(s) ?? Int64(Double(s) ?? 0) }
        else { value = 0 }
    }
}

extension Optional where Wrapped == FlexInt {
    var i64: Int64? { self?.value }
}

enum Fmt {
    static func size(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func speed(_ bytesPerSec: Double) -> String {
        String(format: "%.1f MB/s", bytesPerSec / 1_000_000)
    }

    // Camera timestamps encode the camera's local wall time as if it were UTC,
    // so all display formatting uses UTC to show what the camera clock showed.
    private static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    static let dayTitle: DateFormatter = utcFormatter("EEEE, MMM d yyyy")
    static let time: DateFormatter = utcFormatter("HH:mm")
    static let dayKey: DateFormatter = utcFormatter("yyyy-MM-dd")
    static let full: DateFormatter = utcFormatter("MMM d yyyy, HH:mm:ss")
}

func shortHash(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

enum GoProError: LocalizedError {
    case http(Int, String)
    case badResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .http(let code, let what): return "\(what): camera returned HTTP \(code)"
        case .badResponse(let what): return "\(what): unexpected response from camera"
        case .cancelled: return "Cancelled"
        }
    }
}
