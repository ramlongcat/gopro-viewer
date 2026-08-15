import SwiftUI

struct TransferBarView: View {
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        HStack(spacing: 14) {
            switch transfers.phase {
            case .running:
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfers.toTransferCount == 0
                         ? "Checking what's already copied…"
                         : "Transferring \(min(transfers.filesDone + 1, transfers.toTransferCount)) of \(transfers.toTransferCount) — \(transfers.currentName)")
                        .font(.callout)
                        .lineLimit(1)
                    if let f = transfers.overallFraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView(value: Double(transfers.filesDone), total: Double(max(1, transfers.toTransferCount)))
                    }
                }
                VStack(alignment: .trailing, spacing: 2) {
                    if transfers.speed > 0 {
                        Text(Fmt.speed(transfers.speed))
                            .font(.callout)
                            .monospacedDigit()
                    }
                    if transfers.totalKnownBytes > 0 {
                        Text("\(Fmt.size(transfers.doneBytes + transfers.currentFileBytes)) of \(Fmt.size(transfers.totalKnownBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Cancel") { transfers.cancel() }

            case .finished:
                Image(systemName: transfers.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(transfers.failures.isEmpty ? .green : .yellow)
                Text(transfers.summaryLine)
                    .font(.callout)
                if !transfers.failures.isEmpty {
                    Text(transfers.failures.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(transfers.failures.joined(separator: "\n"))
                }
                Spacer()
                if transfers.failedCount > 0 {
                    Button("Retry Failed (\(transfers.failedCount))") { transfers.retryFailed() }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Prefs.destination])
                }
                Button("OK") { transfers.dismiss() }
                    .keyboardShortcut(.defaultAction)

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Always-visible strip showing how much of the selection (or the whole
/// library when nothing is selected) already exists at the destination.
struct SelectionStatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let selected = model.selectedEntries
        let scope = selected.isEmpty ? model.filteredEntries : selected
        let copied = scope.filter { model.downloadedIDs.contains($0.id) }.count
        let fraction = scope.isEmpty ? 0 : Double(copied) / Double(scope.count)
        let pct = Int((fraction * 100).rounded())
        let remaining = scope
            .filter { !model.downloadedIDs.contains($0.id) }
            .compactMap(\.totalSize)
            .reduce(0, +)

        HStack(spacing: 12) {
            Image(systemName: copied == scope.count && !scope.isEmpty
                  ? "checkmark.circle.fill" : "internaldrive")
                .foregroundStyle(copied == scope.count && !scope.isEmpty ? .green : .secondary)
            Text(selected.isEmpty
                 ? "Library: \(copied) of \(scope.count) copied (\(pct)%)"
                 : "Selection: \(copied) of \(scope.count) copied (\(pct)%)")
                .font(.callout)
                .monospacedDigit()
            ProgressView(value: fraction)
                .frame(width: 140)
            if remaining > 0 {
                Text("\(Fmt.size(remaining)) to transfer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
