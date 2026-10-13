import BaseCampCore
import SwiftUI

/// Lists every waypoint, route and track, or only those in the chosen collection. Selecting a row selects it
/// on the map and in the inspector.
struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @State private var filter = ""
    @State private var renaming = false
    @State private var renameDraft = ""

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedItems) {
            Section {
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
            Section("Waypoints (\(waypoints.count))") {
                ForEach(waypoints) { waypoint in
                    Label(displayName(waypoint.name), systemImage: "mappin")
                        .tag(LibraryItem.waypoint(waypoint.id))
                }
            }
            Section("Routes (\(routes.count))") {
                ForEach(routes) { route in
                    Label(displayName(route.name), systemImage: "map")
                        .tag(LibraryItem.route(route.id))
                }
            }
            Section("Tracks (\(tracks.count))") {
                ForEach(tracks) { track in
                    Label(displayName(track.name), systemImage: "waveform.path")
                        .tag(LibraryItem.track(track.id))
                }
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter by name")
        .onDeleteCommand {
            store.deleteSelection()
        }
        .onChange(of: store.renameRequests) { _, _ in
            startRenaming()
        }
        .sheet(isPresented: $renaming) {
            renameSheet
        }
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

    private func matches(_ name: String) -> Bool {
        filter.isEmpty || name.localizedStandardContains(filter)
    }

    private func displayName(_ name: String) -> String {
        name.isEmpty ? "Unnamed" : name
    }
}
