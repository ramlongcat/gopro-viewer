import AppKit
import Foundation
import CryptoKit
import SwiftUI

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

    /// "Which calendar day is it here", for comparison against the camera's
    /// UTC-formatted day keys.
    private static let localDayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Grid section heading — "Today — Tuesday, Aug 18 2026" when it applies.
    static func daySection(_ date: Date) -> String {
        let full = dayTitle.string(from: date)
        let key = dayKey.string(from: date)
        let now = Date()
        if key == localDayKey.string(from: now) { return "Today — " + full }
        if key == localDayKey.string(from: now.addingTimeInterval(-86_400)) { return "Yesterday — " + full }
        return full
    }

    /// Deliberately vague: a charge estimate from a handful of samples doesn't
    /// deserve minute precision.
    static func roughDuration(_ seconds: Double) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 2 { return "under a minute" }
        if mins < 60 { return "about \(mins) min" }
        let h = mins / 60, rest = mins % 60
        return rest == 0 ? "about \(h) h" : "about \(h) h \(rest) min"
    }
    static let time: DateFormatter = utcFormatter("h:mm a")
    static let dayKey: DateFormatter = utcFormatter("yyyy-MM-dd")
    static let full: DateFormatter = utcFormatter("MMM d yyyy, h:mm:ss a")
}

func shortHash(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

enum AppInfo {
    /// App version (semver). Stamped into Info.plist by build.sh from the
    /// VERSION file; "dev" when running the bare binary outside a bundle.
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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


/// Text and glyphs drawn on top of the accent colour have to flip: a lime or
/// yellow accent needs dark ink, a blue or purple one needs white. Contrast
/// then never depends on which accent the user picked.
enum Accent {
    static var isBright: Bool {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }

    static var ink: Color { isBright ? .black : .white }
}
