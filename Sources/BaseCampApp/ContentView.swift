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
    @State private var isDropTargeted = false

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
            MapPane()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if planner.isActive {
                            RoutePlannerBar()
                        }
                        DeviceStatusBar()
                    }
                }
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
                        .help("Import GPX files (⌘O)")

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
                        .help("Save the library or the selected route or track")

                        Button("Maps", systemImage: "map") {
                            store.showMaps = true
                        }
                        .help("Maps in the shared map folder (⇧⌘M)")

                        Button("Find", systemImage: "magnifyingglass") {
                            store.showFind = true
                        }
                        .help("Find a place and add it as a waypoint (⇧⌘F)")

                        Button("Edge Activities", systemImage: "bicycle") {
                            store.showActivities = true
                        }
                        .help("Import rides stored on the Garmin Edge")
                        .disabled(!device.isConnected)

                        Menu {
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
                            Picker("Garmin map detail", selection: $mapLayers.garminDetail) {
                                ForEach(GarminDetail.allCases) { detail in
                                    Text(detail.label).tag(detail)
                                }
                            }
                            .pickerStyle(.inline)
                            .disabled(mapLayers.base != .garmin)
                        } label: {
                            Label("Map", systemImage: "square.3.layers.3d")
                        }
                        .help("Base map, detail and contour lines")

                        Button("Measure", systemImage: "ruler") {
                            store.toggleMeasuring()
                        }
                        .help("Measure a distance by clicking the map (⌥⌘M)")
                        .foregroundStyle(store.measuring ? Color.accentColor : Color.primary)

                        Button("Plan Route", systemImage: "road.lanes") {
                            planner.isActive.toggle()
                        }
                        .help("Plan a route by clicking the map (⌥⌘R)")

                        Button("Inspector", systemImage: "sidebar.trailing") {
                            showInspector.toggle()
                        }
                        .help("Show or hide the inspector")
                    }
                }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { LibraryStore.importExtensions.contains($0.pathExtension.lowercased()) }
            guard !files.isEmpty else { return false }
            store.importFiles(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert("BaseCamp Clone", isPresented: errorIsPresented) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
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
        .onAppear {
            device.refresh()
            #if DEBUG
            // `--show settings` opens the Settings window at launch, for testing.
            if BaseCampApp.launchValue("--show") == "settings" {
                openSettings()
            }
            #endif
        }
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
