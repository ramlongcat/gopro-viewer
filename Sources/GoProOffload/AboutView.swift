import AppKit
import SwiftUI

/// Replaces the standard About panel, which had nothing to say beyond a
/// version number.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var portrait: NSImage? {
        Bundle.main.url(forResource: "profile", withExtension: "jpg")
            .flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                if let portrait {
                    Image(nsImage: portrait)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.quaternary))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                }
                VStack(spacing: 4) {
                    Text("GoProViewer")
                        .font(.title2.weight(.semibold))
                    Text("Version \(AppInfo.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 2) {
                    Text("Made by Aurelien Ramondou")
                        .font(.callout)
                    Text("aka Rama")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Link("GitHub", destination: URL(string: "https://github.com/ramlongcat")!)
                    Text("·").foregroundStyle(.tertiary)
                    Link("x.com", destination: URL(string: "https://x.com/ramlongcat")!)
                }
                .font(.callout)
                Text("Browses, previews and copies media off a GoPro over USB. The camera is treated as strictly read-only — the app has no ability to delete anything from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 20)
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 340)
    }
}
