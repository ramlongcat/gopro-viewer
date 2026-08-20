import SwiftUI

/// Compact transfer progress / summary block for the sidebar bottom.
struct SidebarTransferStatus: View {
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        switch transfers.phase {
        case .running: running
        case .finished: finished
        case .idle: EmptyView()
        }
    }

    /// Same shape as every other sidebar gauge (SidebarMetric), so the
    /// copying state doesn't arrive with its own bar thickness and padding.
    private var running: some View {
        var note = transfers.currentName
        if transfers.speed > 0 { note += " · \(Fmt.speed(transfers.speed))" }
        if transfers.totalKnownBytes > 0 {
            note += " · \(Fmt.size(transfers.doneBytes + transfers.currentFileBytes)) of \(Fmt.size(transfers.totalKnownBytes))"
        }
        return VStack(alignment: .leading, spacing: 8) {
            SidebarMetric(
                icon: "arrow.down.circle",
                title: transfers.toTransferCount == 0
                    ? "Checking what's copied"
                    : "Copying \(min(transfers.filesDone + 1, transfers.toTransferCount)) of \(transfers.toTransferCount)",
                value: transfers.overallFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "",
                fraction: transfers.overallFraction
                    ?? Double(transfers.filesDone) / Double(max(1, transfers.toTransferCount)),
                subtitle: note)
            Button("Cancel") { transfers.cancel() }
                .controlSize(.small)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: transfers.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(transfers.failures.isEmpty ? .green : .yellow)
                Text(transfers.summaryLine)
                    .font(.callout)
            }
            if !transfers.failures.isEmpty {
                Text(transfers.failures.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(transfers.failures.joined(separator: "\n"))
            }
            if transfers.failedCount > 0 {
                Button("Retry Failed (\(transfers.failedCount))") { transfers.retryFailed() }
                    .controlSize(.small)
            }
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Prefs.destination])
                }
                Spacer()
                Button("OK") { transfers.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }
}
