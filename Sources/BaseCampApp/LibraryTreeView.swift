import BaseCampCore
import SwiftUI

/// BaseCamp's library pane: My Collection, the list folders and lists that organise it, the items in no list, and
/// the connected device's folders. Selecting a node lists its items below and draws them on the map. Items are
/// dragged onto a list to add them; lists and folders are dragged into folders, or onto My Collection to go to the top.
struct LibraryTreeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(DeviceStore.self) private var device
    /// The folders shown open, kept between launches.
    @AppStorage("library.openFolders") private var openFolders = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Library") {
                    nodeRow(.myCollection, name: "My Collection", symbol: "tray.full", count: store.library.allItems.count)
                    folderContents(nil)
                    nodeRow(.unlisted, name: "Unlisted Data", symbol: "tray", count: store.library.unlistedItems.count)
                }
                let groups = store.device.groups.filter { !$0.items.isEmpty || store.device.progress != nil }
                if !groups.isEmpty {
                    Section(store.device.deviceName) {
                        ForEach(groups) { group in
                            deviceRow(group)
                        }
                    }
                }
            }
            .onDeleteCommand {
                store.requestRemoval(store.selectedNode)
            }
            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("New List") { store.newList() }
                    Button("New List Folder") { store.newFolder() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New list or list folder, in the selected folder")
                Button {
                    store.requestRemoval(store.selectedNode)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(!store.selectedNodeIsEditable)
                .help(store.selectedNode.isFolder ? "Remove the folder" : "Remove the list")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .onChange(of: store.selectedNode) { _, node in
            openAncestors(of: node)
        }
    }

    private var selection: Binding<LibraryNode?> {
        Binding(get: { store.selectedNode }, set: { if let node = $0 { store.selectedNode = node } })
    }

    // MARK: Rows

    /// The folders and lists in a folder (nil: at the top), folders first, each by name.
    private func folderContents(_ folder: UUID?) -> AnyView {
        let children = store.library.children(of: folder)
        return AnyView(Group {
            ForEach(children.folders) { child in
                DisclosureGroup(isExpanded: isOpen(child.id)) {
                    folderContents(child.id)
                } label: {
                    nodeRow(.folder(child.id), name: child.name, symbol: "folder", count: nil)
                }
            }
            ForEach(children.lists) { list in
                nodeRow(.list(list.id), name: list.name, symbol: "list.bullet", count: list.items.count)
            }
        })
    }

    private func nodeRow(_ node: LibraryNode, name: String, symbol: String, count: Int?) -> some View {
        HStack {
            Label(name.isEmpty ? "Unnamed" : name, systemImage: symbol)
                .lineLimit(1)
            Spacer()
            if let count {
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .tag(node)
        .contextMenu { menu(for: node) }
        .dropDestination(for: String.self) { payloads, _ in
            drop(payloads, on: node)
        }
        .modifier(DraggableNode(node: node))
    }

    /// One folder of the device: its count, how far reading has got, and whether the map shows it.
    private func deviceRow(_ group: DeviceGroup) -> some View {
        let shown = store.deviceGroupsOnMap.contains(group.id)
        let symbol = switch group.kind {
        case .courses: "flag.checkered"
        case .locations: "mappin.and.ellipse"
        case .activities: "bicycle"
        case .gpx: "doc"
        }
        return HStack(spacing: 6) {
            Label(group.kind.title, systemImage: symbol)
            Spacer()
            if let progress = store.device.progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .help("Reading the device: \(progress.done) of \(progress.total) files")
            }
            Text("\(group.items.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(shown ? "Hide on Map" : "Show on Map", systemImage: shown ? "eye" : "eye.slash") {
                if shown { store.deviceGroupsOnMap.remove(group.id) } else { store.deviceGroupsOnMap.insert(group.id) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(shown ? "Drawn on the map whatever is selected" : "Drawn on the map only while selected here")
        }
        .tag(LibraryNode.device(group.kind))
    }

    @ViewBuilder
    private func menu(for node: LibraryNode) -> some View {
        if case .device = node {} else {
            Button("Export as GPX…") {
                store.selectedNode = node
                store.export(.gpx)
            }
            Button("Send to \(device.isConnected ? store.device.deviceName.isEmpty ? "Device" : store.device.deviceName : "Device")") {
                store.selectedNode = node
                if let gpx = store.gpxForDevice() {
                    device.sendGPX(PendingGPX(fileName: gpx.fileName, data: gpx.data))
                }
            }
            .disabled(!device.isConnected || device.isSending)
            Divider()
        }
        switch node {
        case .myCollection, .folder:
            Button("New List") {
                store.selectedNode = node
                store.newList()
            }
            Button("New List Folder") {
                store.selectedNode = node
                store.newFolder()
            }
            if case .folder = node {
                Divider()
                Button("Rename Folder…") { store.renaming = node }
                Button("Remove Folder…") { store.requestRemoval(node) }
            }
        case .list(let id):
            Button("Rename List…") { store.renaming = node }
            Button("Duplicate List…") { store.pendingListDuplication = id }
            Divider()
            Button("Remove List…") { store.requestRemoval(node) }
        default:
            EmptyView()
        }
    }

    // MARK: Dragging

    /// Items dropped on a list are added to it (items from the device are copied to My Collection first). Items
    /// from the device dropped on My Collection are copied to it. Lists and folders dropped on a folder go into it,
    /// and dropped on My Collection go to the top.
    private func drop(_ payloads: [String], on node: LibraryNode) -> Bool {
        var handled = false
        for payload in payloads {
            if let items = DragPayload.items(payload) {
                switch node {
                case .list(let id):
                    let fromDevice = items.filter(store.isOnDevice)
                    var adding = items.filter { !store.isOnDevice($0) }
                    if !fromDevice.isEmpty {
                        store.copyToLibrary(Set(fromDevice))
                        adding += store.selectedItems
                    }
                    store.add(adding, toList: id)
                    handled = true
                case .myCollection:
                    let fromDevice = items.filter(store.isOnDevice)
                    if !fromDevice.isEmpty {
                        store.copyToLibrary(Set(fromDevice))
                        handled = true
                    }
                default:
                    break
                }
            } else if let moved = DragPayload.node(payload) {
                switch node {
                case .folder(let id):
                    store.move(moved, to: id)
                    handled = true
                case .myCollection:
                    store.move(moved, to: nil)
                    handled = true
                default:
                    break
                }
            }
        }
        return handled
    }

    // MARK: Open folders

    private func isOpen(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { openFolders.contains(id.uuidString) },
            set: { open in
                var ids = Set(openFolders.split(separator: ",").map(String.init))
                if open { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
                openFolders = ids.sorted().joined(separator: ",")
            }
        )
    }

    /// Opens the folders above a node, so a list made or shown inside a closed folder can be seen.
    private func openAncestors(of node: LibraryNode) {
        var folder: UUID?
        switch node {
        case .list(let id): folder = store.library.collections.first { $0.id == id }?.folderID
        case .folder(let id): folder = store.library.folders.first { $0.id == id }?.parentID
        default: return
        }
        var seen: Set<UUID> = []
        while let id = folder, !seen.contains(id) {
            seen.insert(id)
            isOpen(id).wrappedValue = true
            folder = store.library.folders.first { $0.id == id }?.parentID
        }
    }
}

/// Lists and folders can be dragged; the other nodes cannot.
private struct DraggableNode: ViewModifier {
    let node: LibraryNode

    func body(content: Content) -> some View {
        if let payload = DragPayload.text(for: node) {
            content.draggable(payload)
        } else {
            content
        }
    }
}

/// What is dragged within the sidebar, as text: "items:t:UUID,r:UUID,w:UUID" or "node:list:UUID" / "node:folder:UUID".
enum DragPayload {
    static func text(for items: [LibraryItem]) -> String {
        "items:" + items.map { item in
            switch item {
            case .waypoint(let id): "w:\(id.uuidString)"
            case .route(let id): "r:\(id.uuidString)"
            case .track(let id): "t:\(id.uuidString)"
            }
        }.joined(separator: ",")
    }

    static func text(for node: LibraryNode) -> String? {
        switch node {
        case .list(let id): "node:list:\(id.uuidString)"
        case .folder(let id): "node:folder:\(id.uuidString)"
        default: nil
        }
    }

    static func items(_ text: String) -> [LibraryItem]? {
        guard text.hasPrefix("items:") else { return nil }
        return text.dropFirst(6).split(separator: ",").compactMap { token in
            let parts = token.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "w": return .waypoint(id)
            case "r": return .route(id)
            case "t": return .track(id)
            default: return nil
            }
        }
    }

    static func node(_ text: String) -> LibraryNode? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, parts[0] == "node", let id = UUID(uuidString: String(parts[2])) else { return nil }
        switch parts[1] {
        case "list": return .list(id)
        case "folder": return .folder(id)
        default: return nil
        }
    }
}
