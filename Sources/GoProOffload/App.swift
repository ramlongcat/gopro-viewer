import SwiftUI

@main
struct GoProOffloadApp: App {
    @StateObject private var model: AppModel
    @StateObject private var transfers: TransferManager

    init() {
        Prefs.register()
        Prefs.migrateDatedDestination()
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
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Media") { Task { await model.loadMedia() } }
                    .keyboardShortcut("r")
                    .disabled(model.connState != .connected)
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
                Button("Deselect All") { model.deselectAll() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
