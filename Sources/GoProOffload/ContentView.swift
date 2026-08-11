import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        Group {
            if model.connState == .connected {
                connectedBody
            } else {
                NotConnectedView()
            }
        }
        .navigationTitle("GoProViewer")
    }

    private var connectedBody: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 255, max: 320)
        } detail: {
            MediaBrowserView()
        }
        .navigationSubtitle(model.info?.modelName ?? "")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if transfers.phase != .idle {
                TransferBarView()
            } else if !model.entries.isEmpty {
                SelectionStatusBar()
            }
        }
        .toolbar { toolbarContent }
        .sheet(item: $model.viewer) { target in
            ViewerView(targetID: target.id)
                .environmentObject(model)
                .environmentObject(transfers)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.loadMedia() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload the media list (⌘R)")
            .disabled(model.loadingMedia || transfers.isActive)

            Menu {
                Button("Select All Visible") { model.selectAllVisible() }
                Button("Deselect All") { model.deselectAll() }
            } label: {
                Label("Select", systemImage: "checklist")
            }

            Button {
                model.downloadSelected()
            } label: {
                Label(model.selection.isEmpty ? "Transfer" : "Transfer (\(model.selection.count))",
                      systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .help("Transfer selected items to this Mac")
            .disabled(model.selection.isEmpty || transfers.isActive)
        }
    }
}
