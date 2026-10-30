import AppKit
import BaseCampCore
import BaseCampIMG
import SwiftUI

/// Manages maps in two places: the map files on the Edge, and the map folder on this Mac that QMapShack
/// also reads. Sending a map copies it from the folder to the Edge.
struct MapsSheet: View {
    @Environment(MapSettings.self) private var mapSettings
    @Environment(DeviceStore.self) private var device
    @Environment(\.dismiss) private var dismiss

    enum Tab: Hashable {
        case edge
        case folder
    }

    @State private var tab: Tab = .edge
    @State private var deviceMaps: [DeviceMap] = []
    @State private var folderMaps: [MapFile] = []
    @State private var isLoadingDevice = false
    @State private var message: String?
    @State private var pendingDelete: DeviceMap?
    @State private var coverages: [URL: GeoBounds] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 500)
        .task {
            // Let the sheet finish appearing before it reads the device and the folder.
            await Task.yield()
            await reloadDevice()
            reloadFolder()
        }
        .onChange(of: device.isConnected) { _, _ in
            Task { await reloadDevice() }
        }
        .onChange(of: mapSettings.folder) { _, _ in
            reloadFolder()
        }
        .confirmationDialog(
            "Delete this map from the Edge?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { map in
            Button("Delete \(map.file.name)", role: .destructive) {
                Task { await delete(map) }
            }
        } message: { _ in
            Text("A deleted map has to be copied to the Edge again to use it.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Maps", selection: $tab) {
                Text("On the Edge").tag(Tab.edge)
                Text("Map Folder").tag(Tab.folder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Spacer()

            if tab == .folder {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(mapSettings.folder)
                }
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task {
                    await reloadDevice()
                    reloadFolder()
                }
            }
            .labelStyle(.iconOnly)
            .disabled(isLoadingDevice || device.mapTransfer != nil)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .edge:
            edgeContent
        case .folder:
            folderContent
        }
    }

    @ViewBuilder
    private var edgeContent: some View {
        if !device.isConnected {
            ContentUnavailableView(
                "The Edge is not connected",
                systemImage: "cable.connector.slash",
                description: Text("Connect the Edge over USB in MTP mode to see and manage its maps.")
            )
        } else if isLoadingDevice {
            ProgressView("Reading the maps on the Edge…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if deviceMaps.isEmpty {
            ContentUnavailableView(
                "No maps on the Edge",
                systemImage: "map",
                description: Text("Send a map from the Map Folder tab.")
            )
        } else {
            List(deviceMaps) { map in
                HStack {
                    Image(systemName: "map")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(map.file.name)
                        Text(deviceMaps.contains { !$0.onMainStorage } ? "\(map.kindLabel), \(map.storage.name)" : map.kindLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.bytes(map.file.size))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if map.kind.canDelete {
                        Button(role: .destructive) {
                            pendingDelete = map
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .help("Delete this map from the Edge")
                        .disabled(device.mapTransfer != nil)
                    } else {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                            .help("Built-in and licensed maps are protected")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var folderContent: some View {
        if folderMaps.isEmpty {
            ContentUnavailableView(
                "No IMG maps in this folder",
                systemImage: "folder",
                description: Text("Put Garmin .img maps in \(mapSettings.folder.path), or choose another folder in Settings (⌘,).")
            )
        } else {
            List(folderMaps) { map in
                HStack {
                    Image(systemName: "map")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(map.name)
                        if let bounds = coverages[map.url] {
                            Text(coverageText(bounds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let modified = map.modified {
                            Text(modified.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(Format.bytes(UInt64(max(map.size, 0))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Send to Edge") {
                        Task { await send(map) }
                    }
                    .disabled(!canSend(map))
                    .help(sendHelp(map))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let transfer = device.mapTransfer {
                ProgressView(value: transfer.fraction)
                    .frame(maxWidth: 220)
                Text("Copying \(transfer.name) · \(Int(transfer.fraction * 100))%")
                    .monospacedDigit()
                Button("Cancel") {
                    device.cancelMapTransfer()
                }
            } else if let message {
                Label(message, systemImage: "info.circle")
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let free = device.freeBytes {
                Text("Free on the Edge: \(Format.bytes(free))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding()
    }

    // MARK: Sending

    private func alreadyOnDevice(_ map: MapFile) -> Bool {
        // Maps are sent to the main storage; a memory card may hold one of the same name.
        deviceMaps.contains { $0.onMainStorage && $0.file.name.caseInsensitiveCompare(map.name) == .orderedSame }
    }

    private func doesNotFit(_ map: MapFile) -> Bool {
        guard let free = device.freeBytes else { return false }
        return UInt64(max(map.size, 0)) > free
    }

    private func canSend(_ map: MapFile) -> Bool {
        device.isConnected && device.mapTransfer == nil && !alreadyOnDevice(map) && !doesNotFit(map)
    }

    private func sendHelp(_ map: MapFile) -> String {
        if !device.isConnected { return "Connect the Edge first" }
        if device.mapTransfer != nil { return "Another copy is in progress" }
        if alreadyOnDevice(map) { return "A map with this name is already on the Edge" }
        if doesNotFit(map) { return "Not enough free space on the Edge" }
        return "Copy this map to the Edge's Garmin folder"
    }

    private func send(_ map: MapFile) async {
        message = nil
        do {
            try await device.sendMap(map)
            await reloadDevice()
            message = "Sent \(map.name). Restart the Edge to use it."
        } catch {
            message = "Could not send \(map.name). \(error.localizedDescription)"
        }
    }

    private func delete(_ map: DeviceMap) async {
        message = nil
        do {
            try await device.deleteMap(map)
            await reloadDevice()
            message = "Deleted \(map.file.name)."
        } catch {
            message = "Could not delete \(map.file.name). \(error.localizedDescription)"
        }
    }

    // MARK: Loading

    private func reloadDevice() async {
        guard device.isConnected, device.mapTransfer == nil else {
            deviceMaps = []
            return
        }
        isLoadingDevice = true
        defer { isLoadingDevice = false }
        do {
            deviceMaps = try await device.deviceMaps()
        } catch {
            deviceMaps = []
            message = "Could not read the maps on the Edge. \(error.localizedDescription)"
        }
    }

    /// Reads each map's coverage from its IMG header, off the main thread.
    private func loadCoverages(for maps: [MapFile]) {
        Task {
            let found = await Task.detached { () -> [URL: GeoBounds] in
                var result: [URL: GeoBounds] = [:]
                for map in maps {
                    if let img = try? GarminIMG(url: map.url), let bounds = img.coverage {
                        result[map.url] = bounds
                    }
                }
                return result
            }.value
            coverages = found
        }
    }

    private func coverageText(_ bounds: GeoBounds) -> String {
        String(format: "Covers %.1f° to %.1f° N, %.1f° to %.1f° E", bounds.south, bounds.north, bounds.west, bounds.east)
    }

    private func reloadFolder() {
        do {
            folderMaps = try MapFolder.imgMaps(in: mapSettings.folder)
            loadCoverages(for: folderMaps)
        } catch {
            folderMaps = []
            message = "Could not read the map folder. \(error.localizedDescription)"
        }
    }
}
