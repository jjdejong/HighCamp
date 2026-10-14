import BaseCampCore
import SwiftUI

/// How the sidebar shows the items.
enum SidebarStyle {
    case list
    case table
}

/// Lists every waypoint, route and track, or only those in the chosen collection. Selecting a row selects it
/// on the map and in the inspector. The same items can be shown as a sortable table instead.
struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @State private var filter = ""
    @State private var renaming = false
    @State private var renameDraft = ""
    /// The figures for the table. Worked out only while the table is shown, and again after each change to the library.
    @State private var summaries: [ItemSummary] = []

    var body: some View {
        @Bindable var store = store
        Group {
            if store.sidebarStyle == .table {
                VStack(alignment: .leading, spacing: 0) {
                    controls
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    // A table does not take the sidebar's search field, so the filter is a field of its own here.
                    TextField("Filter by name", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    ItemsTable(items: tableItems, selection: $store.selectedItems)
                }
            } else {
                ScrollViewReader { proxy in
                List(selection: $store.selectedItems) {
                    Section {
                        controls
                    }
                    Section("Waypoints (\(waypoints.count))") {
                        ForEach(waypoints) { waypoint in
                            Label(displayName(waypoint.name), systemImage: "mappin")
                                .tag(LibraryItem.waypoint(waypoint.id))
                                .id(LibraryItem.waypoint(waypoint.id))
                        }
                    }
                    Section("Routes (\(routes.count))") {
                        ForEach(routes) { route in
                            Label(displayName(route.name), systemImage: "map")
                                .tag(LibraryItem.route(route.id))
                                .id(LibraryItem.route(route.id))
                        }
                    }
                    Section("Tracks (\(tracks.count))") {
                        ForEach(tracks) { track in
                            Label(displayName(track.name), systemImage: "waveform.path")
                                .tag(LibraryItem.track(track.id))
                                .id(LibraryItem.track(track.id))
                        }
                    }
                }
                .searchable(text: $filter, placement: .sidebar, prompt: "Filter by name")
                .onChange(of: store.selection) { _, item in
                    reveal(item, with: proxy)
                }
                }
            }
        }
        .onDeleteCommand {
            store.deleteSelection()
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
        .onChange(of: store.renameRequests) { _, _ in
            startRenaming()
        }
        .sheet(isPresented: $renaming) {
            renameSheet
        }
    }

    /// The view choice, the collection picker and its buttons. Both views show them.
    @ViewBuilder
    private var controls: some View {
        @Bindable var store = store
        Picker("View", selection: $store.sidebarStyle) {
            Text("List").tag(SidebarStyle.list)
            Text("Table").tag(SidebarStyle.table)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Picker("Show", selection: $store.activeCollectionID) {
            Text("All Items").tag(UUID?.none)
            ForEach(store.library.collections) { collection in
                Text(collection.name).tag(UUID?.some(collection.id))
            }
        }
        .pickerStyle(.menu)
        HStack {
            Button("New Collection", systemImage: "folder.badge.plus") {
                store.createCollection()
            }
            if let id = store.activeCollectionID {
                Button("Rename Collection", systemImage: "pencil") {
                    startRenaming()
                }
                Button("Delete Collection", systemImage: "trash", role: .destructive) {
                    store.deleteCollection(id)
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func refreshSummaries() {
        summaries = store.sidebarStyle == .table ? store.library.itemSummaries : []
    }

    /// The collection being shown, if any.
    private var activeCollection: LibraryCollection? {
        guard let id = store.activeCollectionID else { return nil }
        return store.library.collections.first { $0.id == id }
    }

    private func startRenaming() {
        guard let collection = activeCollection else { return }
        renameDraft = collection.name
        renaming = true
    }

    private func commitRename() {
        guard let id = store.activeCollectionID else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.renameCollection(id, to: trimmed)
        }
        renaming = false
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Collection")
                .font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("Cancel") {
                    renaming = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    commitRename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    /// The items to list: every item, or only those in the chosen collection.
    private var shown: Set<LibraryItem>? {
        guard let id = store.activeCollectionID, let collection = store.library.collections.first(where: { $0.id == id }) else {
            return nil
        }
        return store.items(in: collection)
    }

    private func isShown(_ item: LibraryItem) -> Bool {
        shown?.contains(item) ?? true
    }

    private var waypoints: [Waypoint] {
        store.library.waypoints.filter { isShown(.waypoint($0.id)) && matches($0.name) }
    }

    private var routes: [Route] {
        store.library.routes.filter { isShown(.route($0.id)) && matches($0.name) }
    }

    private var tracks: [Track] {
        store.library.tracks.filter { isShown(.track($0.id)) && matches($0.name) }
    }

    /// The table's rows: the items the list would show, with the same collection and name filter.
    private var tableItems: [ItemSummary] {
        summaries.filter { isShown($0.libraryItem) && matches($0.name) }
    }

    /// Brings an item selected elsewhere, as by clicking it on the map, into view: the collection and the name
    /// filter are dropped if they hide it, and the list scrolls to it.
    private func reveal(_ item: LibraryItem?, with proxy: ScrollViewProxy) {
        guard let item else { return }
        if !isShown(item) {
            store.activeCollectionID = nil
        }
        if let name = name(of: item), !matches(name) {
            filter = ""
        }
        DispatchQueue.main.async {
            proxy.scrollTo(item)
        }
    }

    private func name(of item: LibraryItem) -> String? {
        switch item {
        case .waypoint(let id): store.library.waypoints.first { $0.id == id }?.name
        case .route(let id): store.route(id)?.name
        case .track(let id): store.track(id)?.name
        }
    }

    private func matches(_ name: String) -> Bool {
        filter.isEmpty || name.localizedStandardContains(filter)
    }

    private func displayName(_ name: String) -> String {
        name.isEmpty ? "Unnamed" : name
    }
}
