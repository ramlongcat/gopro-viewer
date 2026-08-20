import SwiftUI

/// Translucent window-background fill shared by the toolbar strip and the
/// pinned day headers in the grid — defined once so the two bands can't
/// drift apart. Deliberately not a blur material: tried in 1.11.24, too busy.
extension ShapeStyle where Self == AnyShapeStyle {
    static var headerBackdrop: AnyShapeStyle {
        AnyShapeStyle(.background.opacity(0.94))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transfers: TransferManager
    @AppStorage("sidebarWidth") private var sidebarWidth = 255.0
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage(Prefs.kGridShowInfo) private var showInfo = false
    @Namespace private var filterNS
    @State private var hoveredFilter: MediaFilter?

    /// The inspector follows the last cell clicked — the same item ⇧-click
    /// measures from, so it is always the one the eye is on.
    private var inspected: MediaEntry? {
        model.selectionAnchor.flatMap { model.entry(for: $0) }
    }

    var body: some View {
        // The intro is a full-window empty state, so it keeps the sidebar out
        // of a window with nothing to browse. It carries its own way through
        // to this Mac — otherwise the source picker, which lives in the
        // sidebar, would be unreachable without a camera.
        Group {
            if model.source == .mac || model.connState == .connected {
                connectedBody
            } else {
                NotConnectedView()
            }
        }
            .navigationTitle("GoProViewer")
            .sheet(isPresented: $model.showAbout) { AboutView() }
        // The viewer is a window of its own, not a sheet — see
        // ViewerWindowController for why.
        .onChange(of: model.viewer) { _, target in
            if target == nil {
                ViewerWindowController.shared.close()
            } else {
                ViewerWindowController.shared.show(model: model, transfers: transfers)
            }
        }
    }

    /// Flat, borderless layout (true App Store-style): no split-view divider;
    /// the faintly tinted sidebar runs flush to the window's top-left corner,
    /// so the standard traffic lights naturally sit inside it. An invisible
    /// strip at the boundary still resizes it.
    private var connectedBody: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .background(.quinary)
                        .ignoresSafeArea()
                        .transition(.move(edge: .leading))
                }
                MediaBrowserView()
                .overlay(alignment: .leading) {
                    if !sidebarCollapsed { resizeHandle }
                }
            }
            // Scroll-under backdrop for the toolbar region (the automatic
            // toolbar background never engages in this custom layout).
            // Non-interactive.
            .overlay(alignment: .top) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: sidebarCollapsed ? 0 : sidebarWidth)
                    Rectangle()
                        .fill(.headerBackdrop)
                }
                .frame(height: geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 52)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
        }
        .background(.background)
        // The system's own trailing column: it brings the drag-to-resize
        // divider and the right background, and it doesn't compete with the
        // grid for width the way a plain HStack child does.
        .inspector(isPresented: $showInfo) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
        }
        // The 1.11.18 header minus the sidebar toggle (the sidebar still
        // toggles via View menu / ⌃⌘S). Do not rearrange:
        // removing/adding items makes macOS shuffle the sides, placeholder
        // items draw chrome, spacer items eat clicks below.
        .toolbar {
            // Tahoe draws its own glass capsule around each toolbar item's
            // full bounds — with the pill's leading padding that chrome would
            // stretch across the padded width. Hide it; filterBar carries its
            // own capsule-shaped glass instead.
            // Never conditional: emptying the principal item makes macOS
            // re-shuffle everything else to the left.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) { filterBar }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { filterBar }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload the media list (⌘R)")
                .disabled(model.loadingMedia || transfers.isActive)
                Menu {
                    Picker("Sort by", selection: $model.sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("Show", selection: $model.showScope) {
                        ForEach(ShowScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("View", systemImage: "square.grid.3x1.below.line.grid.1x2")
                }
                .help("Grid sort order, and whether copied items are shown")
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showInfo.toggle() }
                } label: {
                    Label("Info", systemImage: showInfo ? "info.circle.fill" : "info.circle")
                }
                .help("Details, metadata and GPS for the selected item (⌘I)")
                .keyboardShortcut("i")
                Menu {
                    Button("Select All Visible") { model.selectAllVisible() }
                    let n = model.missingEntries.count
                    Button("Select \(n) Missing Item\(n == 1 ? "" : "s")") { model.selectMissing() }
                        .disabled(n == 0)
                    Button("Deselect All") { model.deselectAll() }
                } label: {
                    Label("Select", systemImage: "checklist")
                }
            }
        }
    }

    /// Everything the camera knows about whichever item is in focus. Lives
    /// beside the grid rather than in the viewer: it's a way of reading the
    /// library, not of watching one clip.
    @ViewBuilder private var inspector: some View {
        if let entry = inspected {
            MediaDetailView(entry: entry)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "info.circle",
                                   description: Text("Click an item in the grid to see its details."))
        }
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { v in
                        sidebarWidth = min(340, max(210, v.location.x))
                    }
            )
    }

    /// Segmented pill: one encompassing capsule, the selection sliding
    /// between segments. The toolbar centers the .principal item in the
    /// window; the leading padding widens the item by the sidebar width so
    /// the pill lands centered over the media list instead. Padding (not
    /// offset) keeps the pill inside the item's bounds, and the padded
    /// region stays click-through (no contentShape).
    @ViewBuilder private var filterBar: some View {
        let pill = HStack(spacing: 8) {
            ForEach(MediaFilter.allCases) { f in
                filterPill(f)
            }
        }
        .padding(6)
        .background(.quinary, in: Capsule())
        Group {
            if #available(macOS 26.0, *) {
                pill.glassEffect(.regular, in: Capsule())
            } else {
                pill
            }
        }
        .padding(.leading, sidebarCollapsed ? 0 : sidebarWidth)
    }

    /// Bright accents (lime, yellow) get dark text on the selected thumb;
    /// dark accents get white — contrast never depends on the accent choice.
    private var accentIsBright: Bool {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }

    private func filterPill(_ f: MediaFilter) -> some View {
        let selected = model.filter == f
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { model.filter = f }
        } label: {
            Text(f.rawValue)
                .fontWeight(.medium)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? (accentIsBright ? Color.black : .white) : .primary)
        .background {
            if selected {
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .matchedGeometryEffect(id: "filter-selection", in: filterNS)
            } else if hoveredFilter == f {
                Capsule().fill(.quaternary)
            }
        }
        .onHover { inside in
            if inside {
                hoveredFilter = f
            } else if hoveredFilter == f {
                hoveredFilter = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredFilter)
    }
}
