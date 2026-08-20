import Foundation

/// Installs/removes the per-user launchd agent behind "Open GoProViewer when a
/// GoPro is plugged in". The agent fires on USB attach of GoPro's vendor ID
/// (0x2672) and runs the GoProUSBLauncher helper embedded in this bundle. The
/// plist is re-written at every launch while enabled, so it keeps pointing at
/// the right copy even if the app moves (dist build vs /Applications).
enum AutoLaunch {
    private static let label = "com.rama.gopro-offload.usb-launch"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/GoProUSBLauncher").path
    }

    static func syncAtLaunch() {
        if Prefs.autoLaunchOnConnect { install() }
    }

    static func setEnabled(_ on: Bool) {
        on ? install() : remove()
    }

    // Two match dictionaries: modern IOUSBHostDevice nubs plus the legacy
    // IOUSBDevice compatibility nubs, so the event fires on every macOS.
    private static var plistXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(helperPath)</string></array>
            <key>LaunchEvents</key>
            <dict>
                <key>com.apple.iokit.matching</key>
                <dict>
                    <key>gopro-usb</key>
                    <dict>
                        <key>IOProviderClass</key><string>IOUSBDevice</string>
                        <key>idVendor</key><integer>9842</integer>
                        <key>IOMatchLaunchStream</key><true/>
                    </dict>
                    <key>gopro-usb-host</key>
                    <dict>
                        <key>IOProviderClass</key><string>IOUSBHostDevice</string>
                        <key>IOPropertyMatch</key>
                        <dict><key>idVendor</key><integer>9842</integer></dict>
                        <key>IOMatchLaunchStream</key><true/>
                    </dict>
                </dict>
            </dict>
        </dict>
        </plist>
        """
    }

    private static func install() {
        let desired = plistXML
        let current = try? String(contentsOf: agentURL, encoding: .utf8)
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if current != desired {
                try desired.write(to: agentURL, atomically: true, encoding: .utf8)
                launchctl("bootout", "gui/\(getuid())/\(label)") // reload on content change
            }
            launchctl("bootstrap", "gui/\(getuid())", agentURL.path)
            AppLog.log("autolaunch: agent installed -> \(helperPath)")
        } catch {
            AppLog.log("autolaunch: install failed: \(error.localizedDescription)")
        }
    }

    private static func remove() {
        launchctl("bootout", "gui/\(getuid())/\(label)")
        try? FileManager.default.removeItem(at: agentURL)
        AppLog.log("autolaunch: agent removed")
    }

    /// bootstrap fails benignly when the job is already loaded, bootout when it
    /// isn't; both are safe to ignore.
    private static func launchctl(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
