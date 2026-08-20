import SwiftUI

private struct LocalNetworkSettingsButton: View {
    var body: some View {
        Button("Open Local Network Settings") {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
            )
        }
    }
}

struct NotConnectedView: View {
    @EnvironmentObject var model: AppModel

    private var title: String {
        switch model.connState {
        case .searching: return "Looking for your GoPro…"
        case .linkAsleep: return "Camera link found — camera not answering"
        case .linkBlocked: return "macOS is blocking the camera connection"
        case .connecting(let ip): return "Connecting to \(ip)…"
        case .connected: return ""
        }
    }

    private var subtitle: String {
        switch model.connState {
        case .searching:
            return "Connect the camera over USB-C. The app finds it automatically once its USB network link is up."
        case .linkAsleep(let port):
            return "The \"\(port)\" USB link is active but nothing responds. If the camera screen is off, tap any button on it to wake it."
        case .linkBlocked(let port):
            return "The \"\(port)\" link is up and the camera looks reachable, but macOS is denying this app's Local Network access. This happens after the app is rebuilt or updated — the permission has to be granted again."
        case .connecting:
            return "Setting up wired control."
        case .connected:
            return ""
        }
    }

    private var symbol: String {
        switch model.connState {
        case .searching: return "cable.connector.horizontal"
        case .linkBlocked: return "lock.shield"
        default: return "camera.fill"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 500)

            switch model.connState {
            case .searching:
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Plug the camera into this Mac with USB-C", systemImage: "1.circle")
                        Label("On the camera: Preferences → Connections → USB Connection → **GoPro Connect** (not MTP)", systemImage: "2.circle")
                        Label("Wake the camera — tap any button", systemImage: "3.circle")
                    }
                    .padding(6)
                }
                .frame(maxWidth: 520)

                Text("If it still isn't found, set a manual camera IP in Settings (⌘,).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            case .linkBlocked:
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Open **Privacy & Security → Local Network**", systemImage: "1.circle")
                        Label("Turn **GoProViewer** off and back on (enable it if it's new)", systemImage: "2.circle")
                        Label("Relaunch this app", systemImage: "3.circle")
                    }
                    .padding(6)
                }
                .frame(maxWidth: 520)
                LocalNetworkSettingsButton()
                Text("If the toggle looks right but it still can't connect, remove the entry or reboot — macOS caches these grants.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            case .linkAsleep:
                VStack(spacing: 8) {
                    Text("Camera awake and it still says this? macOS may be silently blocking the app's Local Network access.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    LocalNetworkSettingsButton()
                        .controlSize(.small)
                }

            default:
                EmptyView()
            }

            ProgressView()
                .controlSize(.small)

            Divider()
                .frame(maxWidth: 260)
            VStack(spacing: 6) {
                Button {
                    model.switchTo(.mac)
                } label: {
                    Label("Browse What's Already on This Mac", systemImage: "apple.logo")
                }
                .controlSize(.large)
                Text("Everything you've copied, without the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
