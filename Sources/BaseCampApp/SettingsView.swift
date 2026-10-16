import AppKit
import BaseCampCore
import Foundation
import SwiftUI

/// Settings (⌘,): the folder that holds the map files, shared with QMapShack.
struct SettingsView: View {
    @Environment(MapSettings.self) private var mapSettings
    @Environment(RoutingSettings.self) private var routing
    @Environment(DisplaySettings.self) private var display
    @Environment(RoutePlanner.self) private var planner
    @Environment(ElevationSettings.self) private var elevation

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
                Text("QMapShack keeps its own map folder setting. Set it to the same folder in QMapShack so both apps read the same maps.")
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
                    if let qmapshack = ElevationSettings.qmapshackFolder, qmapshack != elevation.folder {
                        Button("Use QMapShack's DEM Folder") {
                            elevation.folder = qmapshack
                        }
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
            routingProfilesSection
            Section("Routing") {
                Picker("Engine", selection: $routing.engine) {
                    ForEach(RoutingSettings.Engine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                TextField("Local BRouter address", text: $routing.localServer)
                TextField("brouter.de address", text: $routing.onlineServer)
                LabeledContent("BRouter folder") {
                    Text(routing.brouterFolder.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Choose BRouter Folder…") {
                    chooseBRouterFolder()
                }
                TextField("Java", text: $routing.javaPath)
                Text("The BRouter folder holds the BRouter jar, segments4 and profiles2. It defaults to QMapShack's folder. Routes planned with brouter.de send the route points to that site.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .padding()
    }

    /// Edits the limits of the selected routing profile. The planner bar uses the same profiles.
    @ViewBuilder
    private var routingProfilesSection: some View {
        let profile = planner.selectedProfile
        Section("Routing profiles") {
            Picker("Profile", selection: Binding(
                get: { planner.selectedProfileID },
                set: { planner.selectProfile($0) }
            )) {
                ForEach(planner.profiles) { item in
                    Text(item.name).tag(item.id)
                }
            }
            TextField("Name", text: profileBinding(\.name))
            Picker("BRouter profile", selection: profileBinding(\.brouterProfile)) {
                ForEach(brouterProfileNames(including: profile.brouterProfile), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Toggle("Limit grade", isOn: Binding(
                get: { profile.maxGradePercent != nil },
                set: { limited in planner.updateSelected { $0.maxGradePercent = limited ? 12 : nil } }
            ))
            // The rest only matters with a grade limit: it says when and how far to detour around a steep stretch.
            if let limit = profile.maxGradePercent {
                valueSlider("Max grade", value: "\(Int(limit))%", Binding(
                    get: { limit },
                    set: { value in planner.updateSelected { $0.maxGradePercent = value.rounded() } }
                ), in: 5...25, step: 1)
                valueSlider("Steep stretch from", value: "\(Int(profile.minimumClimbMeters)) m", Binding(
                    get: { profile.minimumClimbMeters },
                    set: { value in planner.updateSelected { $0.minimumClimbMeters = (value / 50).rounded() * 50 } }
                ), in: 100...1000, step: 50)
                .help("How long, along the route, a stretch steeper than the limit must be before a way round it is sought")
                valueSlider("Max detour", value: "\(Int(profile.maxDetourPercent))% longer", Binding(
                    get: { profile.maxDetourPercent },
                    set: { value in planner.updateSelected { $0.maxDetourPercent = (value / 5).rounded() * 5 } }
                ), in: 10...150, step: 5)
                Stepper(value: Binding(
                    get: { profile.maxPasses },
                    set: { value in planner.updateSelected { $0.maxPasses = value } }
                ), in: 1...10) {
                    LabeledContent("Avoidance passes", value: "\(profile.maxPasses)")
                }
            }
            HStack {
                Button("Add Profile") {
                    planner.addProfile()
                }
                Button("Delete Profile") {
                    planner.deleteSelectedProfile()
                }
                .disabled(planner.profiles.count <= 1)
            }
            Text("A detour is sought only for a stretch steeper than the max grade and at least the steep-stretch distance long, measured along the route (not a height). It may make the route at most the max detour longer. The BRouter profile names come from the profiles2 folder of the BRouter folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A binding to one field of the selected profile.
    /// A slider with its value beside it, on one line with its label.
    private func valueSlider(_ label: String, value: String, _ binding: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: binding, in: range, step: step)
                    .labelsHidden()
                Text(value)
                    .monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
        }
    }

    private func profileBinding(_ keyPath: WritableKeyPath<RoutingProfile, String>) -> Binding<String> {
        Binding(
            get: { planner.selectedProfile[keyPath: keyPath] },
            set: { value in planner.updateSelected { $0[keyPath: keyPath] = value } }
        )
    }

    /// The BRouter profiles installed in the BRouter folder, plus the one in use even if it is not installed.
    private func brouterProfileNames(including current: String) -> [String] {
        let folder = routing.brouterFolder.appendingPathComponent("profiles2")
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var names = Set(installed.filter { $0.hasSuffix(".brf") }.map { String($0.dropLast(4)) })
        names.insert(current)
        return names.sorted()
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
