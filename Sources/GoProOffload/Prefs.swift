import Foundation

enum Prefs {
    static let kDestination = "destinationPath"
    static let kOrganize = "organizeByDay"
    static let kIncludeRaw = "includeRaw"
    static let kIncludeProxies = "includeProxies"
    static let kFolderPattern = "folderDatePattern"
    static let kOverrideIP = "overrideIP"
    static let kLastIP = "lastCameraIP"
    static let kPreferProxy = "preferProxyPlayback"

    static func register() {
        UserDefaults.standard.register(defaults: [
            kOrganize: true,
            kIncludeRaw: true,
            kIncludeProxies: false,
            kFolderPattern: "YYYYMMDD",
            kPreferProxy: true,
        ])
    }

    static var destination: URL {
        if let s = UserDefaults.standard.string(forKey: kDestination), !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Movies/GoPro")
    }

    static var organizeByDay: Bool { UserDefaults.standard.bool(forKey: kOrganize) }
    static var includeRaw: Bool { UserDefaults.standard.bool(forKey: kIncludeRaw) }
    static var includeProxies: Bool { UserDefaults.standard.bool(forKey: kIncludeProxies) }
    static var folderPattern: String {
        let s = (UserDefaults.standard.string(forKey: kFolderPattern) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "YYYYMMDD" : s
    }
    static var overrideIP: String {
        (UserDefaults.standard.string(forKey: kOverrideIP) ?? "").trimmingCharacters(in: .whitespaces)
    }
    static var lastCameraIP: String { UserDefaults.standard.string(forKey: kLastIP) ?? "" }

    static let kDidStripDatedDest = "didStripDatedDestination"

    /// One-time: a destination that was picked as a literal dated folder
    /// (~/Desktop/20260810) becomes its parent, so the dynamic day-folder
    /// pattern takes over and the path displays as ~/Desktop/YYYYMMDD.
    static func migrateDatedDestination() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: kDidStripDatedDest) else { return }
        d.set(true, forKey: kDidStripDatedDest)
        let dest = destination
        let last = dest.lastPathComponent
        if last.count == 8, last.allSatisfy(\.isNumber), organizeByDay {
            d.set(dest.deletingLastPathComponent().path, forKey: kDestination)
        }
    }
    static var preferProxy: Bool { UserDefaults.standard.bool(forKey: kPreferProxy) }
}

private let folderFormatterLock = NSLock()
private var folderFormatters: [String: DateFormatter] = [:]

/// Renders the user's day-folder pattern for a capture date. "Y" and "D" are
/// normalized to calendar year/day-of-month so "YYYYMMDD" means what people
/// expect, not ISO week-year / day-of-year.
func folderName(for date: Date, pattern: String) -> String {
    let normalized = String(pattern.map { $0 == "Y" ? "y" : ($0 == "D" ? "d" : $0) })
    folderFormatterLock.lock()
    let f: DateFormatter
    if let cached = folderFormatters[normalized] {
        f = cached
    } else {
        f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")   // camera wall time, like all display dates
        f.dateFormat = normalized
        folderFormatters[normalized] = f
    }
    folderFormatterLock.unlock()
    return f.string(from: date)
}

/// Local path a camera file lands at, honoring the per-day folder preference.
func destinationURL(for tf: TransferFile) -> URL {
    var d = Prefs.destination
    if Prefs.organizeByDay {
        d.appendPathComponent(folderName(for: tf.created, pattern: Prefs.folderPattern))
    }
    return d.appendingPathComponent(tf.name)
}
