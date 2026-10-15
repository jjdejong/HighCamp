import SwiftUI

/// Main window: sidebar, map with inspector, and the device status bar.
struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(DeviceStore.self) private var device
    @Environment(MapSettings.self) private var mapSettings
    @Environment(RoutePlanner.self) private var planner
    @Environment(MapLayerSettings.self) private var mapLayers
    @Environment(\.openSettings) private var openSettings
    @State private var showInspector = true
    @Environment(GarminMapListStore.self) private var garminMaps
    @Environment(RouteRecalculator.self) private var recalculator
    @Environment(RoutingSettings.self) private var routing
    @Environment(ElevationSettings.self) private var elevation
    @Environment(DisplaySettings.self) private var display
    @State private var isDropTargeted = false
    @AppStorage("display.profileHeight") private var profileHeight = 260.0
    @State private var showMapList = false
    @State private var showPointTypes = false

    /// The profile pane is shown for a selected track or route, unless the user hid it.
    private var showsProfilePane: Bool {
        guard display.showsProfilePane else { return false }
        switch store.selection {
        case .track?, .route?: return true
        default: return false
        }
    }

    var body: some View {
        @Bindable var store = store
        @Bindable var mapLayers = mapLayers
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: store.sidebarStyle == .table ? 500 : 220,
                    ideal: store.sidebarStyle == .table ? 500 : 260
                )
        } detail: {
            // The map with the route tool's bar, the profile under it in a pane the user can resize, and the
            // device's status at the bottom. A plain stack: a safe-area inset and VSplitView both left a gap.
            VStack(spacing: 0) {
                MapPane()
                    .frame(minHeight: 200)
                if planner.isActive {
                    RoutePlannerBar()
                }
                if showsProfilePane {
                    ProfileResizeHandle(height: $profileHeight)
                    ProfilePane()
                        .frame(height: profileHeight)
                }
                DeviceStatusBar()
            }
                .background(ToolbarTooltipInstaller())
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
                .overlay {
                    if isDropTargeted {
                        dropHighlight
                    }
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button("Import", systemImage: "square.and.arrow.down") {
                            store.showImportPanel()
                        }
                        .help(ToolbarTooltips.help("Import"))

                        Menu {
                            ForEach(LibraryStore.ExportFormat.allCases) { format in
                                Button(format.label) {
                                    store.export(format)
                                }
                                .disabled(store.library.isEmpty || (format.needsSelection && !store.hasCourseSelection))
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .help(ToolbarTooltips.help("Export"))

                        Button("Maps", systemImage: "map") {
                            store.showMaps = true
                        }
                        .help(ToolbarTooltips.help("Maps"))

                        Toggle(isOn: Binding(get: { display.showsProfilePane }, set: { display.showsProfilePane = $0 })) {
                            Label("Profile", systemImage: "chart.xyaxis.line")
                        }
                        .help(ToolbarTooltips.help("Profile"))

                        Button("Find", systemImage: "magnifyingglass") {
                            store.showFind = true
                        }
                        .help(ToolbarTooltips.help("Find"))

                        Button("Edge Activities", systemImage: "figure.mixed.cardio") {
                            store.showActivities = true
                        }
                        .help(ToolbarTooltips.help("Edge Activities"))
                        .disabled(!device.isConnected)

                        Menu {
                            Button("Go to My Location", systemImage: "location") {
                                store.locateRequest += 1
                            }
                            Divider()
                            Section("Garmin maps, from the map folder") {
                                if garminMaps.entries.isEmpty {
                                    Text(garminMaps.problem ?? "No .img maps in the map folder")
                                }
                                ForEach(garminMaps.topFirst) { entry in
                                    Toggle(GarminMapListStore.title(entry), isOn: Binding(
                                        get: { mapLayers.base == .garmin && entry.isEnabled },
                                        set: { on in
                                            garminMaps.setEnabled(on, for: entry.fileName)
                                            if on { mapLayers.base = .garmin }
                                        }
                                    ))
                                }
                                Button("Map List: Order, Zoom Range, Opacity…") { showMapList = true }
                                Button("Points of Interest…") { showPointTypes = true }
                                Picker("Detail", selection: $mapLayers.garminDetail) {
                                    ForEach(GarminDetail.allCases) { detail in
                                        Text(detail.label).tag(detail)
                                    }
                                }
                                Toggle("Softer Colours", isOn: $mapLayers.garminSoftColors)
                                Picker("Relief Shading", selection: $mapLayers.reliefStrength) {
                                    Text("Off").tag(0.0)
                                    Text("Light").tag(MapLayerSettings.lightRelief)
                                    Text("Medium").tag(MapLayerSettings.mediumRelief)
                                    Text("Strong").tag(MapLayerSettings.strongRelief)
                                }
                            }
                            Divider()
                            Picker("Base map", selection: $mapLayers.base) {
                                ForEach(BaseMapLayer.allCases) { layer in
                                    Text(layer.label).tag(layer)
                                }
                            }
                            .pickerStyle(.inline)
                            Divider()
                            Toggle("Contour lines (IGN, France)", isOn: $mapLayers.showContours)
                            Picker("Contour strength", selection: $mapLayers.contourOpacity) {
                                Text("Light").tag(0.4)
                                Text("Medium").tag(0.7)
                                Text("Strong").tag(1.0)
                            }
                            .disabled(!mapLayers.showContours)
                            Divider()
                            Toggle("Show map coverage", isOn: $mapLayers.showCoverage)
                        } label: {
                            Label("Map", systemImage: "square.3.layers.3d")
                        }
                        .help(ToolbarTooltips.help("Map"))

                        Button("Measure", systemImage: "ruler") {
                            store.toggleMeasuring()
                        }
                        .help(ToolbarTooltips.help("Measure"))
                        .foregroundStyle(store.measuring ? Color.accentColor : Color.primary)

                        Button("Plan Route", systemImage: "road.lanes") {
                            planner.isActive.toggle()
                        }
                        .help(ToolbarTooltips.help("Plan Route"))

                        Button("Inspector", systemImage: "sidebar.trailing") {
                            showInspector.toggle()
                        }
                        .help(ToolbarTooltips.help("Inspector"))
                    }
                }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { LibraryStore.importExtensions.contains($0.pathExtension.lowercased()) }
            guard !files.isEmpty else { return false }
            store.importFiles(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert("HighCamp", isPresented: errorIsPresented) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(isPresented: $showPointTypes) {
            POITypesSheet()
                .environment(mapLayers)
                .environment(garminMaps)
                .task { await garminMaps.reload(folder: mapSettings.folder) }
        }
        .sheet(isPresented: $showMapList) {
            GarminMapListSheet()
                .environment(garminMaps)
                .task { await garminMaps.reload(folder: mapSettings.folder) }
        }
        .sheet(isPresented: $store.showMaps) {
            MapsSheet()
                .environment(mapSettings)
        }
        .sheet(isPresented: $store.showFind) {
            FindSheet()
                .environment(store)
        }
        .sheet(isPresented: $store.showActivities) {
            ActivitiesSheet()
                .environment(store)
                .environment(device)
        }
        .alert("Garmin Edge", isPresented: sendResultIsPresented) {
            Button("OK") {}
        } message: {
            Text(device.sendMessage ?? "")
        }
        .alert(
            "Replace the course on the Edge?",
            isPresented: replacementIsPresented,
            presenting: device.pendingReplacement
        ) { course in
            Button("Replace") { device.replace(course) }
            Button("Cancel", role: .cancel) {}
        } message: { course in
            Text("Garmin/Courses already has \(course.fileName). The new course is copied and checked before the old one is deleted.")
        }
        .alert(
            deletionTitle,
            isPresented: deviceDeletionIsPresented,
            presenting: store.pendingDeviceDeletion
        ) { files in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await device.deleteFiles(files)
                    } catch {
                        store.errorMessage = "Could not delete from \(store.device.deviceName). \(error.localizedDescription)"
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { files in
            Text(deletionMessage(files))
        }
        .onChange(of: elevation.sources(maps: garminMaps), initial: true) { _, sources in
            store.heightSources = sources
        }
        .task(id: store.revision) {
            // Legs whose stops changed are recalculated with their route's profile, in the background, with
            // heights from the elevation models and the Garmin maps (set here too, so the first check has them).
            store.heightSources = elevation.sources(maps: garminMaps)
            recalculator.check(store: store, planner: planner, settings: routing)
        }
        .modifier(LibraryDialogs())
        .alert(
            "Replace the file waiting on the Edge?",
            isPresented: Binding(get: { device.pendingGPXReplacement != nil }, set: { if !$0 { device.pendingGPXReplacement = nil } }),
            presenting: device.pendingGPXReplacement
        ) { file in
            Button("Replace") { device.sendGPX(file, replacing: true) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text("Garmin/NewFiles already has \(file.fileName), not yet taken in by the Edge. The new file is copied and checked before the old one is deleted.")
        }
        .onChange(of: device.contents) { _, contents in
            store.device = contents
        }
        .onAppear {
            // Copies of the device's files are kept next to the library, so a device connected again is quick to show.
            device.cacheFolder = store.dataFolder.appendingPathComponent("Device Files")
            device.refresh()
            #if DEBUG
            // `--show settings` opens the Settings window at launch, for testing.
            if BaseCampApp.launchValue("--show") == "settings" {
                openSettings()
            }
            // `--show maplist` opens the Garmin map list, for testing.
            if BaseCampApp.launchValue("--show") == "maplist" {
                showMapList = true
            }
            // `--show pointtypes` opens the Points of Interest window, for testing.
            if BaseCampApp.launchValue("--show") == "pointtypes" {
                showPointTypes = true
            }
            #endif
        }
    }

    private var deviceDeletionIsPresented: Binding<Bool> {
        Binding(
            get: { store.pendingDeviceDeletion != nil },
            set: { if !$0 { store.pendingDeviceDeletion = nil } }
        )
    }

    private var deletionTitle: String {
        let count = store.pendingDeviceDeletion?.count ?? 0
        return "Delete \(count == 1 ? "this file" : "\(count) files") from \(store.device.deviceName)?"
    }

    /// Which files go, and what else goes with them: a GPX file holds all the items read from it.
    private func deletionMessage(_ files: [DeviceFileRef]) -> String {
        let lines = files.prefix(12).map { file -> String in
            let items = store.deviceItems(in: file)
            let name = items.first.map { store.name(of: $0) } ?? file.name
            let others = items.count > 1 ? ", with \(items.count - 1) other item\(items.count == 2 ? "" : "s") in the same file" : ""
            return "\(name) (Garmin/\(file.kind.folder.last ?? "")/\(file.name)\(others))"
        }
        let more = files.count > 12 ? ["and \(files.count - 12) more"] : []
        return (lines + more).joined(separator: "\n") + "\n\nThis cannot be undone. Copy an item to the library first to keep it."
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private var sendResultIsPresented: Binding<Bool> {
        Binding(
            get: { device.sendMessage != nil },
            set: { if !$0 { device.sendMessage = nil } }
        )
    }

    private var replacementIsPresented: Binding<Bool> {
        Binding(
            get: { device.pendingReplacement != nil },
            set: { if !$0 { device.pendingReplacement = nil } }
        )
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .padding(10)
            .allowsHitTesting(false)
    }
}

/// The bar above the profile pane. Dragging it up or down makes the profile taller or shorter.
struct ProfileResizeHandle: View {
    @Binding var height: Double
    @State private var startHeight: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(.separator).frame(height: 1)
            Capsule().fill(.tertiary).frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 9)
        .background(.background)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startHeight ?? height
                    startHeight = start
                    height = min(max(start - drag.translation.height, 120), 900)
                }
                .onEnded { _ in startHeight = nil }
        )
        .help("Drag to resize the profile")
    }
}
