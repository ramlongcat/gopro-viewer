import SwiftUI

@main
struct GoProOffloadApp: App {
    @StateObject private var model: AppModel
    @StateObject private var transfers: TransferManager
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false

    init() {
        Prefs.register()
        Prefs.migrateDatedDestination()
        AutoLaunch.syncAtLaunch()
        let m = AppModel()
        _model = StateObject(wrappedValue: m)
        _transfers = StateObject(wrappedValue: m.transfers)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(transfers)
                .task { model.start() }
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About GoProViewer") { model.showAbout = true }
            }
            // The default Help item opens a help book this app doesn't ship,
            // so macOS answers "help isn't available". Point it somewhere real.
            CommandGroup(replacing: .help) {
                Button("GoProViewer on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ramlongcat/gopro-viewer")!)
                }
                Button("Report an Issue") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ramlongcat/gopro-viewer/issues")!)
                }
            }
            CommandGroup(after: .sidebar) {
                Button(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    withAnimation(.easeOut(duration: 0.2)) { sidebarCollapsed.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(after: .sidebar) {
                Button("Show All") { model.filter = .all }
                    .keyboardShortcut("1")
                Button("Show Videos") { model.filter = .videos }
                    .keyboardShortcut("2")
                Button("Show Photos") { model.filter = .photos }
                    .keyboardShortcut("3")
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Media") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                    .disabled(model.source == .camera && model.connState != .connected)
                Button("Select All Media") {
                    // ⌘A must keep working inside text fields: forward to the
                    // focused editor when there is one, else select the grid.
                    if let responder = NSApp.keyWindow?.firstResponder,
                       responder is NSTextView || responder is NSTextField {
                        NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: responder, from: nil)
                    } else {
                        model.selectAllVisible()
                    }
                }
                .keyboardShortcut("a")
                // No connection gate: with no camera the list is empty and the
                // emptiness disables it, while the Mac library needs none.
                Button("Select Missing Items") { model.selectMissing() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.missingEntries.isEmpty)
                Button("Deselect All") { model.deselectAll() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
