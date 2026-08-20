import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.kDestination) private var destinationPath = ""
    @AppStorage(Prefs.kOrganize) private var organizeByDay = true
    @AppStorage(Prefs.kIncludeRaw) private var includeRaw = true
    @AppStorage(Prefs.kIncludeProxies) private var includeProxies = false
    @AppStorage(Prefs.kFolderPattern) private var folderPattern = "YYYYMMDD"
    @AppStorage(Prefs.kOverrideIP) private var overrideIP = ""
    @AppStorage(Prefs.kAutoLaunch) private var autoLaunchOnConnect = false
    @AppStorage(Prefs.kGoogleClientID) private var googleClientID = ""
    @AppStorage(Prefs.kGoogleClientSecret) private var googleClientSecret = ""
    @AppStorage(Prefs.kGoogleAutoUpload) private var googleAutoUpload = false
    @ObservedObject private var google = GooglePhotos.shared
    @State private var showOwnClient = false

    var body: some View {
        Form {
            Section("Copying") {
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
            Section("Google Photos") {
                if google.isSignedIn {
                    LabeledContent("Signed in as") { Text(google.account ?? "") }
                    Toggle("Upload copies to Google Photos automatically", isOn: $googleAutoUpload)
                    Button("Sign Out") { google.signOut() }
                } else {
                    HStack {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(google.busy ? "Signing in…" : "Sign In…") {
                            Task { await google.signIn() }
                        }
                        .disabled(google.busy)
                    }
                    Text("Opens Google in your browser. The app can only add photos and videos — Google removed the permission to read your library in March 2025, so it can never see what's already there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = google.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Hand-rolled disclosure: DisclosureGroup in a grouped form
                // only toggles on its small chevron — and not reliably even
                // there — so the whole row is a plain Button instead.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showOwnClient.toggle() }
                } label: {
                    HStack {
                        Text("Use my own Google client")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showOwnClient ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onAppear {
                    // Without a secret sign-in cannot succeed, so the fields
                    // that fix it start visible rather than folded away.
                    if Prefs.googleClientSecret.isEmpty { showOwnClient = true }
                }
                if showOwnClient {
                    TextField("Client ID", text: $googleClientID,
                              prompt: Text(Prefs.defaultGoogleClientID))
                    SecureField("Client secret", text: $googleClientSecret)
                    Text("Google's desktop clients reject sign-in without their secret, so paste yours here. Leave the ID empty to use the app's own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Connection") {
                TextField("Camera IP override", text: $overrideIP, prompt: Text("automatic"))
                Text("Leave empty for automatic USB discovery (camera at 172.2x.x.51). A LAN IP also works if the camera is on your network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Open GoProViewer when a GoPro is plugged in", isOn: $autoLaunchOnConnect)
                    .onChange(of: autoLaunchOnConnect) { _, on in AutoLaunch.setEnabled(on) }
                Text("Installs a per-user launch agent that fires when a GoPro USB device attaches. macOS lists it under Login Items; a one-time \"background items added\" notification is normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: AppInfo.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
    }
}
