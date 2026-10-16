import AppKit
import BaseCampCore
import Foundation
import SwiftUI

/// Settings (⌘,): display, map and elevation folders, track DEMs, routing profiles and the router.
struct SettingsView: View {
    @Environment(MapSettings.self) private var mapSettings
    @Environment(RoutingSettings.self) private var routing
    @Environment(DisplaySettings.self) private var display
    @Environment(RoutePlanner.self) private var planner
    @Environment(ElevationSettings.self) private var elevation
    @Environment(BRouterInstall.self) private var brouterInstall
    @Environment(BRouterServer.self) private var brouterServer
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var mapSettings = mapSettings
        @Bindable var routing = routing
        @Bindable var display = display
        @Bindable var elevation = elevation
        Form {
            Section("Units and positions") {
                Picker("Units", selection: $display.units) {
                    ForEach(UnitSystem.allCases) { system in
                        Text(system.label).tag(system)
                    }
                }
                Picker("Positions", selection: $display.coordinates) {
                    ForEach(CoordinateSystem.allCases) { system in
                        Text(system.label).tag(system)
                    }
                }
            }
            Section("Maps") {
                LabeledContent("Map folder") {
                    Text(mapSettings.folder.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder…") {
                        chooseFolder()
                    }
                    if let qmapshack = MapSettings.qmapshackFolder, qmapshack != mapSettings.folder {
                        Button("Use QMapShack's Folder") {
                            mapSettings.folder = qmapshack
                        }
                        .help(qmapshack.path)
                    }
                }
                Text("The folder of Garmin maps (.img). If QMapShack is installed, the same folder can serve both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Elevation models (DEM)") {
                LabeledContent("Folder") {
                    Text(elevation.folder.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder…") {
                        chooseElevationFolder()
                    }
                }
                Picker("Heights from", selection: $elevation.mapHeightsFirst) {
                    Text("These models, then the Garmin maps").tag(false)
                    Text("The Garmin maps, then these models").tag(true)
                }
                Text("Heights for tracks, routes, new waypoints and the route planner come from the first model in this folder that covers the point, or from the heights the Garmin maps carry. A track or route takes all its heights from one source when one covers it. Put the best model first, such as Current_DEM.vrt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Track DEMs (high resolution)") {
                LabeledContent("Tile folder") {
                    Text(elevation.tileFolder.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Choose Tile Folder…") {
                    chooseTileFolder()
                }
                Picker("Corridor", selection: Bindable(elevation).corridor) {
                    Text("50 m").tag(50.0)
                    Text("100 m").tag(100.0)
                    Text("200 m").tag(200.0)
                    Text("500 m").tag(500.0)
                }
                Text("Build Track DEM (Track and Route menus, or the profile) gathers the tiles of this folder and its subfolders that lie within the corridor of the selected line into a small DEM for it, finest tiles first, without copying them. Its profile is then read every few metres along the line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RoutingProfileSettings()
            Section("Routing") {
                Picker("Engine", selection: $routing.engine) {
                    ForEach(RoutingSettings.Engine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                if routing.engine == .local {
                    localBRouter
                } else {
                    TextField("brouter.de address", text: $routing.onlineServer)
                    Text("Routes planned with brouter.de send the route points to that site.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .padding()
    }

    /// HighCamp's own BRouter: whether it is installed, Java, the map data tiles, and where it all is.
    @ViewBuilder
    private var localBRouter: some View {
        @Bindable var routing = routing
        let folder = routing.brouterFolder
        let installed = brouterInstall.isInstalled(in: folder)
        LabeledContent("BRouter") {
            if installed {
                Text(brouterServer.isRunning ? "Installed, running" : "Installed, not running")
            } else {
                Button("Install BRouter \(BRouterInstall.version)") {
                    Task {
                        await brouterInstall.install(into: folder)
                        brouterServer.start(routing)
                    }
                }
                .disabled(brouterInstall.activity != nil)
                .help("Downloads BRouter (about 6 MB) from its GitHub page into HighCamp's folder")
            }
        }
        LabeledContent("Java") {
            if routing.hasJava {
                Text(routing.javaPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(routing.javaPath)
            } else {
                Text("Not found. Install a Java runtime, such as Temurin (adoptium.net).")
                    .foregroundStyle(.orange)
            }
        }
        if installed {
            let tiles = brouterInstall.tiles(in: folder)
            LabeledContent("Map data") {
                Text(tiles.isEmpty ? "None yet" : "\(tiles.count) tile\(tiles.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: tiles.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
            }
            ForEach(tiles, id: \.name) { tile in
                HStack {
                    Text(tile.name)
                        .monospaced()
                    Text(ByteCountFormatter.string(fromByteCount: tile.bytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete") {
                        brouterInstall.deleteTile(tile.name, in: folder)
                    }
                    .disabled(brouterInstall.activity != nil)
                }
            }
            let needed = brouterInstall.missingTiles(for: libraryPlaces, in: folder)
            if !needed.isEmpty {
                Button("Download Map Data for the Library's Routes (\(needed.joined(separator: ", ")))") {
                    Task {
                        await brouterInstall.downloadTiles(needed, into: folder)
                        brouterServer.start(routing)
                    }
                }
                .disabled(brouterInstall.activity != nil)
                .help("Each tile covers 5° by 5° and is 50 to 250 MB, from brouter.de")
            }
        }
        if let activity = brouterInstall.activity {
            HStack {
                if let fraction = activity.fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(activity.text)
                    .foregroundStyle(.secondary)
            }
        }
        if let problem = brouterInstall.problem ?? brouterServer.lastError {
            Text(problem)
                .foregroundStyle(.orange)
        }
        LabeledContent("Folder") {
            Text(folder.path)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        HStack {
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
            Button("Use Another BRouter Folder…") {
                chooseBRouterFolder()
                brouterServer.start(routing)
            }
            if folder != BRouterInstall.defaultFolder {
                Button("Use HighCamp's Folder") {
                    routing.brouterFolder = BRouterInstall.defaultFolder
                    brouterServer.start(routing)
                }
            }
        }
        TextField("Address", text: $routing.localServer)
        TextField("Java", text: $routing.javaPath)
        Text("HighCamp runs its own BRouter while it is open, from this folder: the BRouter program, its profiles, and the map data tiles your routes need, downloaded from brouter.de. Another BRouter folder (such as QMapShack's) can be used instead.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The stops of each route, and every 50th point of each track: where routes are planned.
    private var libraryPlaces: [[Coordinate]] {
        store.library.routes.map { $0.stops.map(\.coordinate) }
            + store.library.tracks.flatMap { track in track.segments.map { segment in stride(from: 0, to: segment.count, by: 50).map { segment[$0].coordinate } } }
    }

    private func chooseBRouterFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = routing.brouterFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        routing.brouterFolder = url
    }

    private func chooseTileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = elevation.tileFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            elevation.tileFolder = url
        }
    }

    private func chooseElevationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = elevation.folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        elevation.folder = url
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = mapSettings.folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mapSettings.folder = url
    }
}
