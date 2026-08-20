import Foundation

enum Prefs {
    static let kDestination = "destinationPath"
    static let kOrganize = "organizeByDay"
    static let kIncludeRaw = "includeRaw"
    static let kIncludeProxies = "includeProxies"
    static let kFolderPattern = "folderDatePattern"
    static let kOverrideIP = "overrideIP"
    static let kLastIP = "lastCameraIP"
    static let kAutoLaunch = "autoLaunchOnConnect"
    static let kSortOrder = "gridSortOrder"
    static let kShowScope = "gridShowScope"
    static let kGoogleClientID = "googleClientID"
    static let kGoogleClientSecret = "googleClientSecret"
    static let kGoogleAccount = "googleAccount"
    static let kGoogleAutoUpload = "googleAutoUpload"

    /// The OAuth client this app ships with. It identifies the app, not a
    /// person — installed-app client IDs are public by design — and anyone
    /// who prefers their own Google Cloud project can replace it in Settings.
    static let defaultGoogleClientID =
        "911350370520-34s54eva59p0g1enso7s41jt0ef76kue.apps.googleusercontent.com"
    /// Its secret. Google's token endpoint refuses a desktop-client exchange
    /// without one even under PKCE, and Google's own docs concede installed-app
    /// secrets "are not treated as confidential" — every shipping desktop app
    /// embeds one. The real value rides in the built app's Info.plist, stamped
    /// by build.sh from the git-ignored `.google-client-secret` file, so the
    /// public repo never carries it; this constant is only a last-resort slot
    /// for plain `swift build` runs.
    static let defaultGoogleClientSecret = ""
    static let kGridShowInfo = "gridShowInfo"

    static func register() {
        UserDefaults.standard.register(defaults: [
            kOrganize: true,
            kIncludeRaw: true,
            kIncludeProxies: false,
            kFolderPattern: "YYYYMMDD",
            kAutoLaunch: false,
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
    static var googleClientID: String {
        let s = (UserDefaults.standard.string(forKey: kGoogleClientID) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? defaultGoogleClientID : s
    }
    static var googleClientSecret: String {
        let s = (UserDefaults.standard.string(forKey: kGoogleClientSecret) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { return s }
        // The bundled secret pairs with the bundled client ID; someone using
        // their own client brings their own secret (or their client is a type
        // that takes none), so never cross the pairs.
        guard googleClientID == defaultGoogleClientID else { return "" }
        let baked = Bundle.main.object(forInfoDictionaryKey: "GoogleClientSecret") as? String
            ?? defaultGoogleClientSecret
        return baked.trimmingCharacters(in: .whitespaces)
    }
    static var googleAutoUpload: Bool { UserDefaults.standard.bool(forKey: kGoogleAutoUpload) }

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
    static var sortOrder: String { UserDefaults.standard.string(forKey: kSortOrder) ?? "" }
    static var showScope: String { UserDefaults.standard.string(forKey: kShowScope) ?? "" }
    static var autoLaunchOnConnect: Bool { UserDefaults.standard.bool(forKey: kAutoLaunch) }
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

/// Home-relative rendering of a path, for display ("~/Movies/GoPro/20260817").
func homeRelativePath(_ url: URL) -> String {
    let p = url.path
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

/// Local path a camera file lands at, honoring the per-day folder preference.
func destinationURL(for tf: TransferFile) -> URL {
    var d = Prefs.destination
    if Prefs.organizeByDay {
        d.appendPathComponent(folderName(for: tf.created, pattern: Prefs.folderPattern))
    }
    return d.appendingPathComponent(tf.name)
}
