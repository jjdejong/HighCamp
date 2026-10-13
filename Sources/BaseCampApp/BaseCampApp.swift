import AppKit
import SwiftUI

@main
struct BaseCampApp: App {
    @State private var store = LibraryStore(fileURL: Self.libraryFileURL())
    @State private var device = DeviceStore()
    @State private var mapSettings = MapSettings()
    @State private var routing = RoutingSettings()
    @State private var planner = RoutePlanner()
    @State private var brouter = BRouterServer()
    @State private var mapLayers = MapLayerSettings()
    @State private var mapCoverage = MapCoverageStore()
    @State private var display = DisplaySettings()
    @State private var elevation = ElevationSettings()

    var body: some Scene {
        WindowGroup("BaseCamp Clone") {
            ContentView()
                .environment(store)
                .environment(device)
                .environment(mapSettings)
                .environment(routing)
                .environment(planner)
                .environment(brouter)
                .environment(mapLayers)
                .environment(mapCoverage)
                .environment(display)
                .environment(elevation)
                .frame(minWidth: 960, minHeight: 620)
#if DEBUG
                .task {
                    store.importFiles(Self.launchFiles())
                    if let names = Self.launchSelection() {
                        for name in names.split(separator: ",") {
                            store.selectItem(named: String(name), addingToSelection: true)
                        }
                    }
                    // `--show find|maps|activities|measure` opens that window at launch, for testing. Settings open from the content view.
                    if let what = Self.launchValue("--show") {
                        try? await Task.sleep(for: .seconds(Double(Self.launchValue("--show-delay") ?? "3") ?? 3))
                        switch what {
                        case "find": store.showFind = true
                        case "maps": store.showMaps = true
                        case "activities": store.showActivities = true
                        case "measure": store.toggleMeasuring()
                        case "rename": store.requestRenameCollection()
                        default: break
                        }
                    }
                    // `--new-collection` puts the launch selection into a new collection, for testing.
                    if CommandLine.arguments.contains("--new-collection") {
                        store.createCollection()
                        if let id = store.activeCollectionID {
                            store.addSelection(toCollection: id)
                        }
                    }
                    // `--report-png PATH` renders the report for the selection to PATH, for testing.
                    if Self.launchValue("--report-png") != nil {
                        try? await Task.sleep(for: .seconds(6))
                        await ReportPrinter.printSelection(store: store, display: display, base: mapLayers.pictureBase(folder: mapSettings.folder))
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
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    brouter.stop()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            BaseCampCommands(store: store, planner: planner, elevation: elevation, display: display, layers: mapLayers, mapSettings: mapSettings)
        }

        Settings {
            SettingsView()
                .environment(mapSettings)
                .environment(routing)
                .environment(display)
                .environment(planner)
                .environment(elevation)
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

    /// Set by `--map-image`, so the map view is saved there without asking.
    @MainActor static var testMapImagePath: URL?

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
    let elevation: ElevationSettings
    let display: DisplaySettings
    let layers: MapLayerSettings
    let mapSettings: MapSettings

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print Report…") {
                Task { await ReportPrinter.printSelection(store: store, display: display, base: layers.pictureBase(folder: mapSettings.folder)) }
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

        CommandMenu("Collection") {
            Button("New Collection") {
                store.createCollection()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Rename Collection…") {
                store.requestRenameCollection()
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(store.activeCollectionID == nil)
            Button("Delete Collection") {
                if let id = store.activeCollectionID {
                    store.deleteCollection(id)
                }
            }
            .disabled(store.activeCollectionID == nil)
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
            Button("Split at Profile Position") {
                store.splitSelectedTrackAtCursor()
            }
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
                store.fillElevationsFromModel(folder: elevation.folder, replaceExisting: false)
            }
            Button("Replace Elevations from Model") {
                store.fillElevationsFromModel(folder: elevation.folder, replaceExisting: true)
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom to Selection") {
                store.zoomToSelection()
            }
            .keyboardShortcut("l", modifiers: [.command])
        }

        CommandGroup(replacing: .importExport) {
            Button("Import GPX…") {
                store.showImportPanel()
            }
            .keyboardShortcut("o")

            Menu("Export") {
                ForEach(LibraryStore.ExportFormat.allCases) { format in
                    Button(format.label) {
                        store.export(format)
                    }
                    .disabled(format.needsSelection && !store.hasCourseSelection)
                }
            }

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
