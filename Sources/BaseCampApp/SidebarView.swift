import BaseCampCore
import SwiftUI

/// How the sidebar shows the items.
enum SidebarStyle {
    case list
    case table
}

/// BaseCamp's two panes: the library tree above (`LibraryTreeView`), and below it the waypoints, routes and tracks
/// of the node selected there. Selecting an item selects it on the map and in the inspector. The items can be
/// shown as a sortable table instead, and dragged onto a list in the tree.
struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(RouteRecalculator.self) private var recalculator
    @Environment(RoutePlanner.self) private var planner
    @Environment(RoutingSettings.self) private var routing
    @State private var filter = ""
    /// The figures for the table. Worked out only while the table is shown, and again after each change to the library.
    @State private var summaries: [ItemSummary] = []

    var body: some View {
        VSplitView {
            LibraryTreeView()
                .frame(minHeight: 120, idealHeight: 240)
            itemsPane
                .frame(minHeight: 160)
        }
        .onAppear {
            refreshSummaries()
        }
        .onChange(of: store.revision) { _, _ in
            refreshSummaries()
        }
        .onChange(of: store.sidebarStyle) { _, _ in
            refreshSummaries()
        }
    }

    // MARK: The items of the selected node

    @ViewBuilder
    private var itemsPane: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            if store.sidebarStyle == .table {
                // A table does not take the sidebar's search field, so the filter is a field of its own here.
                TextField("Filter by name", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                ItemsTable(items: tableItems, selection: $store.selectedItems, onOpen: zoom(to:), onRecalculate: recalculate)
                    .onDeleteCommand { store.deleteSelection() }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $store.selectedItems) {
                        itemSection("Waypoints", rows: rows.filter { if case .waypoint = $0.item { true } else { false } })
                        itemSection("Routes", rows: rows.filter { if case .route = $0.item { true } else { false } })
                        itemSection("Tracks", rows: rows.filter { if case .track = $0.item { true } else { false } })
                    }
                    .searchable(text: $filter, placement: .sidebar, prompt: "Filter by name")
                    .contextMenu(forSelectionType: LibraryItem.self) { items in
                        itemMenu(items)
                    } primaryAction: { items in
                        zoom(to: items)
                    }
                    .onDeleteCommand {
                        store.deleteSelection()
                    }
                    .onChange(of: store.selection) { _, item in
                        reveal(item, with: proxy)
                    }
                }
            }
        }
    }

    /// The node's name, and the choice between list and table.
    private var header: some View {
        @Bindable var store = store
        return HStack {
            Text(store.name(of: store.selectedNode))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Picker("View", selection: $store.sidebarStyle) {
                Image(systemName: "list.bullet").tag(SidebarStyle.list)
                Image(systemName: "tablecells").tag(SidebarStyle.table)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("List or table")
        }
    }

    private func itemSection(_ title: String, rows: [Row]) -> some View {
        Section("\(title) (\(rows.count))") {
            ForEach(rows) { row in
                Label(row.name.isEmpty ? "Unnamed" : row.name, systemImage: row.symbol)
                    .tag(row.item)
                    .id(row.item)
                    .draggable(dragText(for: row.item))
            }
        }
    }

    /// The items dragged with a row: the whole selection when the row is part of it.
    private func dragText(for item: LibraryItem) -> String {
        let items = store.selectedItems.contains(item) ? Array(store.selectedItems) : [item]
        return DragPayload.text(for: items)
    }

    /// One row of the item list.
    private struct Row: Identifiable {
        let item: LibraryItem
        let name: String
        let symbol: String
        var id: LibraryItem { item }
    }

    /// The rows of the selected node that match the name filter: the library's items in it, or the device folder's.
    private var rows: [Row] {
        let source: Library
        var trackSymbol = "waveform.path"
        if case .device(let kind) = store.selectedNode {
            source = store.device.groups.first { $0.kind == kind }?.library ?? Library()
            trackSymbol = kind == .courses ? "flag.checkered" : kind == .activities ? "bicycle" : trackSymbol
        } else {
            source = store.library
        }
        let shown = store.items(of: store.selectedNode)
        let all = source.waypoints.map { Row(item: .waypoint($0.id), name: $0.name, symbol: "mappin") }
            + source.routes.map { Row(item: .route($0.id), name: $0.name, symbol: "map") }
            + source.tracks.map { Row(item: .track($0.id), name: $0.name, symbol: trackSymbol) }
        return all.filter { (shown?.contains($0.item) ?? true) && matches($0.name) }
    }

    private func refreshSummaries() {
        summaries = store.sidebarStyle == .table ? store.library.itemSummaries : []
    }

    /// The table's rows: the library items the list would show, with the same name filter.
    private var tableItems: [ItemSummary] {
        let shown = store.items(of: store.selectedNode)
        if case .device = store.selectedNode { return [] }
        return summaries.filter { (shown?.contains($0.libraryItem) ?? true) && matches($0.name) }
    }

    // MARK: Actions

    /// Double-clicking an item frames the map on the whole of it.
    private func zoom(to items: Set<LibraryItem>) {
        guard !items.isEmpty else { return }
        store.selectedItems = items
        store.zoomToSelection()
    }

    @ViewBuilder
    private func itemMenu(_ items: Set<LibraryItem>) -> some View {
        if !items.isEmpty {
            Button("Zoom to Selection") { zoom(to: items) }
        }
        let library = items.filter { !store.isOnDevice($0) }
        let routes = Self.routes(in: library)
        if !routes.isEmpty {
            Button(routes.count > 1 ? "Recalculate Routes" : "Recalculate Route") { recalculate(library) }
        }
        if !library.isEmpty {
            Menu("Add to List") {
                ForEach(store.listsByPath, id: \.id) { list in
                    Button(list.path) { store.add(Array(library), toList: list.id) }
                }
                Divider()
                Button("New List…") {
                    store.selectedItems = library
                    store.addSelectionToNewList()
                }
            }
            if store.selectedListID != nil {
                Button("Remove from List") {
                    store.selectedItems = library
                    store.removeSelectionFromList()
                }
            }
            Button("Delete from My Collection…", role: .destructive) {
                store.pendingItemDeletion = ItemDeletion(items: library, list: nil)
            }
        }
        if items.contains(where: store.isOnDevice) {
            Button("Copy to Library") { store.copyToLibrary(items) }
            Button("Delete from Device…", role: .destructive) { store.requestDeviceDeletion(items) }
        }
    }

    /// The routes among the items.
    static func routes(in items: Set<LibraryItem>) -> [UUID] {
        items.compactMap { if case .route(let id) = $0 { id } else { nil } }
    }

    /// Calculates the routes among the items again, with their routing profiles.
    private func recalculate(_ items: Set<LibraryItem>) {
        let routes = Self.routes(in: items.filter { !store.isOnDevice($0) })
        recalculator.recalculate(routes, store: store, planner: planner, settings: routing)
    }

    /// Brings an item selected elsewhere, as by clicking it on the map, into view: when the selected node does not
    /// hold it, My Collection (or its device folder) is selected instead; the name filter is dropped if it hides it;
    /// the list scrolls to it.
    private func reveal(_ item: LibraryItem?, with proxy: ScrollViewProxy) {
        guard let item else { return }
        if let group = store.deviceGroup(of: item), store.isOnDevice(item) {
            if store.selectedNode != .device(group.kind) {
                store.selectedNode = .device(group.kind)
            }
        } else if let shown = store.items(of: store.selectedNode), !shown.contains(item) {
            store.selectedNode = .myCollection
        }
        if !matches(store.name(of: item)) {
            filter = ""
        }
        DispatchQueue.main.async {
            proxy.scrollTo(item)
        }
    }

    private func matches(_ name: String) -> Bool {
        filter.isEmpty || name.localizedStandardContains(filter)
    }
}
