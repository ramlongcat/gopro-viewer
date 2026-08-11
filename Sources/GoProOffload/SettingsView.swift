import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.kDestination) private var destinationPath = ""
    @AppStorage(Prefs.kOrganize) private var organizeByDay = true
    @AppStorage(Prefs.kIncludeRaw) private var includeRaw = true
    @AppStorage(Prefs.kIncludeProxies) private var includeProxies = false
    @AppStorage(Prefs.kFolderPattern) private var folderPattern = "YYYYMMDD"
    @AppStorage(Prefs.kPreferProxy) private var preferProxy = true
    @AppStorage(Prefs.kOverrideIP) private var overrideIP = ""

    var body: some View {
        Form {
            Section("Transfers") {
                LabeledContent("Base folder") {
                    HStack {
                        Text(Prefs.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        FolderPickerButton()
                    }
                }
                Toggle("Organize into folders by capture day", isOn: $organizeByDay)
                if organizeByDay {
                    TextField("Day folder pattern", text: $folderPattern, prompt: Text("YYYYMMDD"))
                        .onAppear {
                            if folderPattern.trimmingCharacters(in: .whitespaces).isEmpty {
                                folderPattern = "YYYYMMDD"
                            }
                        }
                    Text("YYYYMMDD → 20260810 · YYYY-MM-DD → 2026-08-10 · YYYY/MM/DD nests folders. MM is month; add HHmm for time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Include RAW photos (.GPR)", isOn: $includeRaw)
                Toggle("Include proxy files (.LRV / .THM)", isOn: $includeProxies)
            }
            Section("Playback") {
                Toggle("Prefer low-res proxy when streaming video", isOn: $preferProxy)
            }
            Section("Connection") {
                TextField("Camera IP override", text: $overrideIP, prompt: Text("automatic"))
                Text("Leave empty for automatic USB discovery (camera at 172.2x.x.51). A LAN IP also works if the camera is on your network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 470)
    }
}
