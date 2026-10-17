import AppKit
import SwiftUI
import BaseCampCore
import BaseCampIMG

@main
struct BaseCampApp: App {
    @State private var store = LibraryStore(fileURL: Self.libraryFileURL())
    @State private var device = DeviceStore()
    @State private var mapSettings = MapSettings()
    @State private var routing = RoutingSettings()
    @State private var planner = RoutePlanner()
    @State private var brouter = BRouterServer()
    @State private var brouterInstall = BRouterInstall()
    @State private var mapLayers = MapLayerSettings()
    @State private var mapCoverage = MapCoverageStore()
    @State private var display = DisplaySettings()
    @State private var elevation = ElevationSettings()
    @State private var garminMaps = GarminMapListStore()
    @State private var recalculator = RouteRecalculator()
    @State private var trackDEMs = TrackDEMStore()

    init() {
        #if DEBUG
        Self.renderTileAndExitIfAsked()
        Self.printPointNamesAndExitIfAsked()
        Self.printHeightsAndExitIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup("HighCamp") {
            ContentView()
                .environment(store)
                .environment(device)
                .environment(mapSettings)
                .environment(routing)
                .environment(planner)
                .environment(brouter)
                .environment(brouterInstall)
                .environment(mapLayers)
                .environment(mapCoverage)
                .environment(display)
                .environment(elevation)
                .environment(trackDEMs)
                .environment(garminMaps)
                .environment(recalculator)
                .frame(minWidth: 960, minHeight: 620)
#if DEBUG
                .task {
                    store.importFiles(Self.launchFiles())
                    if let names = Self.launchSelection() {
                        for name in names.split(separator: ",") {
                            store.selectItem(named: String(name), addingToSelection: true)
                        }
                    }
                    // `--select-list NAME` selects the list with that name in the library tree, for testing.
                    if let name = Self.launchValue("--select-list"),
                       let list = store.library.collections.first(where: { $0.name == name }) {
                        store.selectedNode = .list(list.id)
                    }
                    // `--select-device NAME` selects the device item with that name once the device has been read, and
                    // frames the map on it, for testing.
                    if let name = Self.launchValue("--select-device") {
                        for _ in 0..<120 where store.device.groups.isEmpty || store.device.progress != nil {
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                        if let item = store.device.groups.flatMap(\.items).first(where: { store.name(of: $0) == name }) {
                            store.selection = item
                            store.zoomToSelection()
                        }
                    }
                    // `--install-brouter` installs BRouter in its folder, downloads the map data the library's routes need
                    // and starts the server, for testing.
                    if CommandLine.arguments.contains("--install-brouter") {
                        let folder = routing.brouterFolder
                        if !brouterInstall.isInstalled(in: folder) {
                            await brouterInstall.install(into: folder)
                        }
                        await brouterInstall.downloadTiles(brouterInstall.missingTiles(for: store.library.routes.map { $0.stops.map(\.coordinate) }, in: folder), into: folder)
                        brouter.start(routing)
                        print("BROUTER installed=\(brouterInstall.isInstalled(in: folder)) tiles=\(brouterInstall.tiles(in: folder).map(\.name)) problem=\(brouterInstall.problem ?? "none") server=\(brouter.lastError ?? "started")")
                    }
                    // `--build-track-dem` frames the map on the selected item and builds its track DEM, for testing.
                    if CommandLine.arguments.contains("--build-track-dem"), let item = store.selection {
                        try? await Task.sleep(for: .seconds(2))
                        store.zoomToSelection()
                        await trackDEMs.build(item, store: store, tileFolder: elevation.tileFolder, corridor: elevation.corridor)
                    }
                    // `--profile-range FROM TO` picks that stretch of the selected track's profile, in kilometres, for testing.
                    if let range = Self.launchProfileRange() {
                        store.profileRange = range
                    }
                    // `--sidebar table` shows the items as a table instead of a list, for testing.
                    if Self.launchValue("--sidebar") == "table" {
                        store.sidebarStyle = .table
                    }
                    // `--show find|maps|activities|measure` opens that window at launch, for testing. Settings open from the content view.
                    if let what = Self.launchValue("--show") {
                        try? await Task.sleep(for: .seconds(Double(Self.launchValue("--show-delay") ?? "3") ?? 3))
                        switch what {
                        case "find": store.showFind = true
                        case "maps": store.showMaps = true
                        case "activities": store.showActivities = true
                        case "measure": store.toggleMeasuring()
                        case "rename": if store.selectedListID != nil { store.renaming = store.selectedNode }
                        default: break
                        }
                    }
                    // `--new-collection` puts the launch selection into a new list, and selects the list, for testing.
                    if CommandLine.arguments.contains("--new-collection") {
                        store.addSelectionToNewList()
                        if case .list(let id)? = store.renaming {
                            store.renaming = nil
                            store.selectedNode = .list(id)
                        }
                    }
                    // `--report-png PATH` or `--report-pdf PATH` renders the report for the selection, for testing.
                    if Self.launchValue("--report-png") != nil || Self.launchValue("--report-pdf") != nil {
                        try? await Task.sleep(for: .seconds(6))
                        await ReportPrinter.printSelection(store: store, display: display, base: mapLayers.pictureBase(garmin: garminMaps))
                    }
                    // `--map-image PATH` saves the map view to PATH once the map has settled, for testing.
                    // With `--select`, the map is framed on the selection first, so the picture shows what was selected.
                    if let path = Self.launchValue("--map-image") {
                        try? await Task.sleep(for: .seconds(6))
                        if Self.launchSelection() != nil {
                            store.zoomToSelection()
                            try? await Task.sleep(for: .seconds(4))
                        }
                        store.mapImageRequest += 1
                        Self.testMapImagePath = URL(fileURLWithPath: path)
                    }
                }
#endif
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // HighCamp's own BRouter runs while HighCamp does.
                    if routing.engine == .local, brouterInstall.isInstalled(in: routing.brouterFolder) {
                        brouter.start(routing)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    brouter.stop()
                    store.flushSaving()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            BaseCampCommands(
                store: store, planner: planner, recalculator: recalculator, routing: routing,
                elevation: elevation, display: display, layers: mapLayers, garminMaps: garminMaps, trackDEMs: trackDEMs,
                device: device
            )
        }

        Settings {
            SettingsView()
                .environment(brouterInstall)
                .environment(brouter)
                .environment(store)
                .environment(mapSettings)
                .environment(routing)
                .environment(display)
                .environment(planner)
                .environment(elevation)
                .environment(trackDEMs)
        }
    }

    /// `--library PATH` opens a library file other than the default, for testing.
    private static func libraryFileURL() -> URL {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        #endif
        return LibraryStore.defaultFileURL
    }

    #if DEBUG
    /// The value after a launch option, such as `--select NAME`.
    static func launchValue(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `--point-names Z/X/Y --maps A.img,B.img` prints the point and area names the map pane would write over that tile's area,
    /// viewed at that zoom, and quits without opening a window. For checking the names.
    static func printPointNamesAndExitIfAsked() {
        guard let spec = launchValue("--point-names"), let maps = launchValue("--maps") else { return }
        let numbers = spec.split(separator: "/").compactMap { Int($0) }
        guard numbers.count == 3 else { exit(2) }
        let tiles = pow(2, Double(numbers[0]))
        func latitude(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y / tiles))) * 180 / .pi }
        let bounds = GeoBounds(
            north: latitude(Double(numbers[2])), east: Double(numbers[1] + 1) / tiles * 360 - 180,
            south: latitude(Double(numbers[2] + 1)), west: Double(numbers[1]) / tiles * 360 - 180
        )
        let middle: Double = (bounds.north + bounds.south) / 2 * .pi / 180
        // A shade finer than the zoom's own scale, so the view's zoom rounds down to it.
        let metersPerPoint: Double = 40_075_016.686 * cos(middle) / (256 * tiles) * 0.99
        let urls = maps.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let request = PlaceRequest(viewport: PlaceQuery(bounds: bounds, metersPerPoint: metersPerPoint), maps: urls, detailOffset: 0)
        Task.detached {
            for name in await MapPane.pointNames(in: bounds, request: request) {
                print(String(format: "%06X", name.poi.type), name.poi.name ?? "", name.poi.isLandmark ? "(landmark)" : "", "\(name.size)")
            }
            var places: [MapPlace] = []
            for map in urls {
                places += await MapFeatureCache.shared.places(in: bounds, metersPerPoint: metersPerPoint, map: map, detailOffset: 0)
            }
            for area in await MapPane.areaNames(in: bounds, request: request, places: MapPlace.merged(places)) {
                print("area", area.name, "\(area.kind)", String(format: "%.1f", area.importance))
            }
            exit(0)
        }
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// `--heights LAT,LON;LAT,LON --maps A.img,B.img --dem FOLDER [--maps-first]` prints each place's height from the
    /// folder, from the maps, and as `HeightSources` combines them, and quits without opening a window.
    static func printHeightsAndExitIfAsked() {
        guard let spec = launchValue("--heights"), let maps = launchValue("--maps"), let folder = launchValue("--dem") else { return }
        let places = spec.split(separator: ";").compactMap { pair -> Coordinate? in
            let numbers = pair.split(separator: ",").compactMap { Double($0) }
            return numbers.count == 2 ? Coordinate(latitude: numbers[0], longitude: numbers[1]) : nil
        }
        let urls = maps.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let first = CommandLine.arguments.contains("--maps-first")
        let both = HeightSources(folder: URL(fileURLWithPath: folder), maps: urls, mapsFirst: first)
        let folderOnly = HeightSources(folder: both.folder, maps: [])
        let mapsOnly = HeightSources(folder: URL(fileURLWithPath: "/nonexistent"), maps: urls, mapsFirst: true)
        Task.detached {
            let fromFolder = await folderOnly.heights(for: places)
            let fromMaps = await mapsOnly.heights(for: places)
            let combined = await both.heights(for: places)
            func text(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
            for index in places.indices {
                print(places[index].latitude, places[index].longitude,
                      "folder", text(fromFolder[index]), "maps", text(fromMaps[index]), "used", text(combined[index]))
            }
            exit(0)
        }
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// `--render-tile Z/X/Y OUT.png --maps A.img,B.img [--relief 0.45] [--scale 2] [--detail 1]` draws one Garmin tile, as the map
    /// pane would, saves it and quits without opening a window. For checking the renderer.
    static func renderTileAndExitIfAsked() {
        guard let spec = launchValue("--render-tile"), let output = launchValue(spec),
              let maps = launchValue("--maps") else { return }
        let numbers = spec.split(separator: "/").compactMap { Int($0) }
        guard numbers.count == 3 else { exit(2) }
        let configuration = GarminMapConfiguration(
            layers: maps.split(separator: ",").map {
                GarminMapLayer(url: URL(fileURLWithPath: String($0)), isOverlay: false, minimumZoom: 0, maximumZoom: 30, opacity: 1)
            },
            detailOffset: Int(launchValue("--detail") ?? "0") ?? 0, softColors: launchValue("--soft") != "0",
            relief: Double(launchValue("--relief") ?? "0.45") ?? 0.45
        )
        let scale = CGFloat(Double(launchValue("--scale") ?? "2") ?? 2)
        Task.detached {
            let data = await GarminTileRenderer.png(z: numbers[0], x: numbers[1], y: numbers[2], scale: scale, configuration: configuration)
            try? data?.write(to: URL(fileURLWithPath: output))
            exit(0)
        }
        // The main run loop keeps going, since Apple's map snapshots for empty areas answer on the main thread.
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Set by `--map-image`, so the map view is saved there without asking.
    @MainActor static var testMapImagePath: URL?

    /// `--profile-range FROM TO` picks the stretch from FROM to TO kilometres at launch, for testing.
    private static func launchProfileRange() -> ClosedRange<Double>? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--profile-range"), index + 2 < arguments.count,
              let from = Double(arguments[index + 1]), let to = Double(arguments[index + 2]), from <= to else { return nil }
        return from * 1000...to * 1000
    }

    /// `--select NAME` selects the library item with that name at launch, for testing.
    private static func launchSelection() -> String? {
        launchValue("--select")
    }

    /// GPX files named after `--open` on the command line are imported at launch.
    private static func launchFiles() -> [URL] {
        let arguments = CommandLine.arguments
        return arguments.indices.dropLast().compactMap { index in
            arguments[index] == "--open" ? URL(fileURLWithPath: arguments[index + 1]) : nil
        }
    }
    #endif
}

struct BaseCampCommands: Commands {
    let store: LibraryStore
    let planner: RoutePlanner
    let recalculator: RouteRecalculator
    let routing: RoutingSettings
    let elevation: ElevationSettings
    let display: DisplaySettings
    let layers: MapLayerSettings
    let garminMaps: GarminMapListStore
    let trackDEMs: TrackDEMStore
    let device: DeviceStore

    /// Building and removing the selected track's or route's own high-resolution DEM.
    @ViewBuilder
    private var trackDEMCommands: some View {
        let item = store.selection.flatMap { item -> LibraryItem? in
            if case .waypoint = item { return nil }
            return item
        }
        Button(item.flatMap { trackDEMs.info(for: $0, store: store) } == nil ? "Build Track DEM" : "Rebuild Track DEM") {
            guard let item else { return }
            Task { await trackDEMs.build(item, store: store, tileFolder: elevation.tileFolder, corridor: elevation.corridor) }
        }
        .disabled(item == nil || trackDEMs.status != nil)
        Button("Remove Track DEM") {
            if let item {
                trackDEMs.remove(item, store: store)
            }
        }
        .disabled(item.flatMap { trackDEMs.info(for: $0, store: store) } == nil)
    }

    /// True when the selected item is a route with legs. A route without a profile takes the route tool's profile.
    private var canRecalculateSelection: Bool {
        guard case .route(let id)? = store.selection, let route = store.route(id) else { return false }
        return !route.legs.isEmpty
    }

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print Report…") {
                Task { await ReportPrinter.printSelection(store: store, display: display, base: layers.pictureBase(garmin: garminMaps)) }
            }
            .keyboardShortcut("p")
        }

        CommandGroup(replacing: .undoRedo) {
            Button(store.undoName.map { "Undo \($0)" } ?? "Undo") {
                store.undo()
            }
            .keyboardShortcut("z")
            .disabled(!store.canUndo)

            Button(store.redoName.map { "Redo \($0)" } ?? "Redo") {
                store.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo)
        }

        // BaseCamp's lists and list folders, which organise My Collection. They act on the node selected in the
        // library tree.
        CommandMenu("Lists") {
            Button("New List") {
                store.newList()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New List Folder") {
                store.newFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Divider()
            Button(store.selectedNode.isFolder ? "Rename Folder…" : "Rename List…") {
                store.renaming = store.selectedNode
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(!store.selectedNodeIsEditable)
            Button("Duplicate List…") {
                store.pendingListDuplication = store.selectedListID
            }
            .disabled(store.selectedListID == nil)
            Button(store.selectedNode.isFolder ? "Remove Folder…" : "Remove List…") {
                store.requestRemoval(store.selectedNode)
            }
            .disabled(!store.selectedNodeIsEditable)
            Divider()
            Button("Remove from List") {
                store.removeSelectionFromList()
            }
            .disabled(store.selectedListID == nil || store.selectedItems.isEmpty)
        }

        CommandMenu("Route") {
            Button("Recalculate Route") {
                guard case .route(let id)? = store.selection else { return }
                // Clears the route's earlier failures too, so legs the router refused are asked again.
                if store.markRouteForRecalculation(id, fallbackProfile: planner.selectedProfileID) {
                    recalculator.retry(id, store: store, planner: planner, settings: routing)
                }
            }
            .disabled(!canRecalculateSelection)
            Divider()
            trackDEMCommands
        }

        CommandMenu("Track") {
            Button("Reverse") {
                store.reverseSelection()
            }
            Menu("Simplify") {
                ForEach([2.0, 5.0, 10.0, 25.0], id: \.self) { metres in
                    Button("Within \(Int(metres)) m") {
                        store.simplifySelection(tolerance: metres)
                    }
                }
            }
            Menu("Filter Points") {
                ForEach([5.0, 10.0, 30.0], id: \.self) { seconds in
                    Button("Every \(Int(seconds)) s") {
                        store.thinSelectedTrack(everySeconds: seconds)
                    }
                }
                Divider()
                ForEach([10.0, 25.0, 50.0], id: \.self) { metres in
                    Button("Every \(Int(metres)) m") {
                        store.thinSelectedTrack(everyMetres: metres)
                    }
                }
            }
            Button("Split at Profile Position") {
                store.splitSelectedTrackAtCursor()
            }
            Button("Delete Selected Points") {
                store.deleteProfileRange()
            }
            .disabled(store.profileRange == nil)
            Button("Convert to Route or Track") {
                store.convertSelection()
            }
            Button("Duplicate") {
                store.duplicateSelection()
            }
            Button("Combine Selected Tracks") {
                store.combineSelectedTracks()
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Button("Elevations from Model") {
                store.fillElevationsFromModel(replaceExisting: false)
            }
            Button("Replace Elevations from Model") {
                store.fillElevationsFromModel(trackDEM: trackDEMs.modelFolder(for: store.selection, store: store), replaceExisting: true)
            }
            Divider()
            trackDEMCommands
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom to Selection") {
                store.zoomToSelection()
            }
            .keyboardShortcut("l", modifiers: [.command])
            Button("Go to My Location") {
                store.locateRequest += 1
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Button(display.showsProfilePane ? "Hide Profile" : "Show Profile") {
                display.showsProfilePane.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .importExport) {
            Button("Import GPX…") {
                store.showImportPanel()
            }
            .keyboardShortcut("o")
            Button("Import BaseCamp Library…") {
                store.showBaseCampImportPanel()
            }

            Menu("Export") {
                ForEach(LibraryStore.ExportFormat.allCases) { format in
                    Button(format.label) {
                        store.export(format)
                    }
                    .disabled(format.needsSelection && !store.hasCourseSelection)
                }
            }
            // The node selected in the library tree, as one GPX file named after it, as BaseCamp exports a list.
            Button("Export \u{201C}\(store.name(of: store.selectedNode))\u{201D} as GPX…") {
                store.export(.gpx)
            }
            .keyboardShortcut("e")
            .disabled(store.library(of: store.selectedNode) == nil)
            Button("Send \u{201C}\(store.name(of: store.selectedNode))\u{201D} to Device") {
                if let gpx = store.gpxForDevice() {
                    device.sendGPX(PendingGPX(fileName: gpx.fileName, data: gpx.data))
                }
            }
            .disabled(store.library(of: store.selectedNode) == nil || !device.isConnected || device.isSending)

            Button("Import Activities from Edge…") {
                store.showActivities = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Maps…") {
                store.showMaps = true
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button("Save Map Image…") {
                store.mapImageRequest += 1
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Find Place…") {
                store.showFind = true
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Plan Route") {
                planner.isActive.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Button("Measure Distance") {
                store.toggleMeasuring()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}
