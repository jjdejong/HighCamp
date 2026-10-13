import BaseCampCore
import SwiftUI

/// Shows and edits the selected item: its name and fields, statistics, editing actions and device actions.
struct InspectorView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(DeviceStore.self) private var device
    @Environment(DisplaySettings.self) private var display
    @Environment(ElevationSettings.self) private var elevation
    @Environment(RoutePlanner.self) private var planner
    @Environment(RouteRecalculator.self) private var recalculator
    @Environment(RoutingSettings.self) private var routing

    var body: some View {
        if store.selectedItems.count > 1 {
            multipleSelection
        } else if let selection = store.selection {
            Form {
                Section {
                    TextField("Name", text: nameBinding(for: selection))
                }
                details(for: selection)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "cursorarrow.click",
                description: Text("Select a waypoint, route or track in the sidebar.")
            )
        }
    }

    /// Summary and actions for several selected items.
    private var multipleSelection: some View {
        Form {
            Section("\(store.selectedItems.count) items selected") {
                ForEach(names(of: store.selectedItems), id: \.self) { name in
                    Text(name.isEmpty ? "Unnamed" : name)
                }
            }
            Section("Actions") {
                collectionMenu
                if store.activeCollectionID != nil {
                    Button("Remove from This Collection") {
                        store.removeSelectionFromActiveCollection()
                    }
                }
                Button("Combine Tracks") {
                    store.combineSelectedTracks()
                }
                .disabled(store.selectedTracks.count < 2)
                .help("Join the selected tracks, in library order, into one track")
                Button("Zoom to Selection") {
                    store.zoomToSelection()
                }
                Button("Delete \(store.selectedItems.count) Items", role: .destructive) {
                    store.deleteSelection()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Adds the selected items to a collection, or to a new one.
    private var collectionMenu: some View {
        Menu("Add to Collection") {
            ForEach(store.library.collections) { collection in
                Button(collection.name) {
                    store.addSelection(toCollection: collection.id)
                }
            }
            Divider()
            Button("New Collection") {
                store.createCollection()
                if let id = store.activeCollectionID {
                    store.addSelection(toCollection: id)
                }
            }
        }
    }

    /// The names of the items, in sidebar order: waypoints, routes, then tracks.
    private func names(of items: Set<LibraryItem>) -> [String] {
        let waypoints = store.library.waypoints.filter { items.contains(.waypoint($0.id)) }.map(\.name)
        let routes = store.library.routes.filter { items.contains(.route($0.id)) }.map(\.name)
        let tracks = store.library.tracks.filter { items.contains(.track($0.id)) }.map(\.name)
        return waypoints + routes + tracks
    }

    private func nameBinding(for item: LibraryItem) -> Binding<String> {
        Binding(
            get: { store.name(of: item) },
            set: { store.rename(item, to: $0) }
        )
    }

    @ViewBuilder
    private func details(for item: LibraryItem) -> some View {
        switch item {
        case .waypoint(let id):
            if let waypoint = store.waypoint(id) {
                waypointDetails(waypoint)
            }
        case .route(let id):
            if let route = store.route(id) {
                routeDetails(route)
                sendSection(name: route.name, points: route.coursePoints)
            }
        case .track(let id):
            if let track = store.track(id) {
                trackDetails(track)
                sendSection(name: track.name, points: track.coursePoints)
            }
        }
    }

    // MARK: Waypoints

    @ViewBuilder
    private func waypointDetails(_ waypoint: Waypoint) -> some View {
        Section("Position") {
            LabeledContent("Shown as", value: UnitFormat.coordinate(waypoint.coordinate, display.coordinates))
                .textSelection(.enabled)
            LabeledContent("Latitude") {
                TextField("Latitude", value: coordinateBinding(waypoint.id, latitude: true), format: .number.precision(.fractionLength(6)))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Longitude") {
                TextField("Longitude", value: coordinateBinding(waypoint.id, latitude: false), format: .number.precision(.fractionLength(6)))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Elevation") {
                TextField("Elevation", value: elevationBinding(waypoint.id), format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
            }
            if let height = waypoint.elevation {
                LabeledContent("Height", value: UnitFormat.elevation(height, display.units))
            }
            Button("Height from Elevation Model") {
                store.fillElevationsFromModel(folder: elevation.folder, replaceExisting: true)
            }
            if let time = waypoint.time {
                LabeledContent("Time", value: time.formatted(date: .abbreviated, time: .shortened))
            }
        }
        Section("Details") {
            Picker("Symbol", selection: symbolBinding(waypoint.id)) {
                ForEach(symbolChoices(including: waypoint.symbol ?? ""), id: \.self) { name in
                    Text(name.isEmpty ? "None" : name).tag(name)
                }
            }
            TextField("Comment", text: commentBinding(waypoint.id), axis: .vertical)
                .lineLimit(1...5)
        }
    }

    private func coordinateBinding(_ id: UUID, latitude: Bool) -> Binding<Double> {
        Binding(
            get: {
                guard let coordinate = store.waypoint(id)?.coordinate else { return 0 }
                return latitude ? coordinate.latitude : coordinate.longitude
            },
            set: { value in
                store.updateWaypoint(id, field: latitude ? "latitude" : "longitude") { waypoint in
                    if latitude {
                        waypoint.coordinate.latitude = value
                    } else {
                        waypoint.coordinate.longitude = value
                    }
                }
            }
        )
    }

    private func elevationBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { store.waypoint(id)?.elevation ?? 0 },
            set: { value in
                store.updateWaypoint(id, field: "elevation") { $0.elevation = value }
            }
        )
    }

    private func symbolBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.waypoint(id)?.symbol ?? "" },
            set: { value in
                store.updateWaypoint(id, field: "symbol") { $0.symbol = value.isEmpty ? nil : value }
            }
        )
    }

    /// Garmin's common waypoint symbols, plus the one in use even when it is not in the list.
    private func symbolChoices(including current: String) -> [String] {
        let common = [
            "", "Flag, Blue", "Pin, Red", "Summit", "Campground", "Restaurant", "Cafe", "Water Source",
            "Parking Area", "Information", "Viewpoint", "Hotel", "Bike Trail", "Danger Area", "Trail Head",
        ]
        return common.contains(current) ? common : common + [current]
    }

    private func commentBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.waypoint(id)?.comment ?? "" },
            set: { value in
                store.updateWaypoint(id, field: "comment") { $0.comment = value.isEmpty ? nil : value }
            }
        )
    }

    // MARK: Routes and tracks

    @ViewBuilder
    private func routeDetails(_ route: Route) -> some View {
        Section("Route") {
            LabeledContent("Points", value: "\(route.points.count)")
            routingPicker(route)
            recalculationStatus(route)
        }
        // The stops come first: they are what is edited on the map.
        routePointList(route)
        colourSection(.route(route.id), color: route.color, defaultColour: MapLineColor.blue)
        editSection(canSplit: false)
        statisticsSections(route.statistics, profile: route.elevationProfile)
    }

    @ViewBuilder
    private func trackDetails(_ track: Track) -> some View {
        Section("Track") {
            LabeledContent("Segments", value: "\(track.segments.count)")
            LabeledContent("Points", value: "\(track.pointCount)")
        }
        colourSection(.track(track.id), color: track.color, defaultColour: MapLineColor.orange)
        editSection(canSplit: true)
        statisticsSections(track.statistics, profile: track.elevationProfile)
    }

    /// The colour the item is drawn in on the map, and a way back to the default.
    @ViewBuilder
    private func colourSection(_ item: LibraryItem, color: ItemColor?, defaultColour: MapLineColor) -> some View {
        Section("Colour") {
            ColorPicker("Line colour", selection: Binding(
                get: { color?.swiftUIColor ?? Color(nsColor: defaultColour.nsColor) },
                set: { store.setColor(of: item, to: ItemColor($0)) }
            ), supportsOpacity: false)
            Button("Use Default Colour") {
                store.setColor(of: item, to: nil)
            }
            .disabled(color == nil)
        }
    }

    /// Editing actions for the selected track or route. The same actions are in the Track menu.
    @ViewBuilder
    private func editSection(canSplit: Bool) -> some View {
        Section("Edit") {
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
            if canSplit {
                Button("Split at Profile Position") {
                    store.splitSelectedTrackAtCursor()
                }
                .disabled(store.profileCoordinate == nil)
                .help("Move the pointer over the elevation profile to choose where to cut the track")
            }
            Menu("Add to Collection") {
                ForEach(store.library.collections) { collection in
                    Button(collection.name) {
                        store.addSelection(toCollection: collection.id)
                    }
                }
                Divider()
                Button("New Collection") {
                    store.createCollection()
                    if let id = store.activeCollectionID {
                        store.addSelection(toCollection: id)
                    }
                }
            }
            Button(store.selection.map(convertTitle) ?? "Convert") {
                store.convertSelection()
            }
            Button("Duplicate") {
                store.duplicateSelection()
            }
            if canSplit {
                let others = store.library.tracks.filter { $0.id != selectedTrackID }
                Menu("Combine With") {
                    ForEach(others) { other in
                        Button(other.name.isEmpty ? "Unnamed" : other.name) {
                            store.combineSelection(withTrack: other.id)
                        }
                    }
                }
                .disabled(others.isEmpty)
                .help("Join another track onto this one, after its last point")
            }
            Button("Elevations from Model") {
                store.fillElevationsFromModel(folder: elevation.folder, replaceExisting: false)
            }
            .help("Fill in heights where the track or route has none")
            Button("Replace Elevations from Model") {
                store.fillElevationsFromModel(folder: elevation.folder, replaceExisting: true)
            }
        }
    }

    private var selectedTrackID: UUID? {
        if case .track(let id)? = store.selection { return id }
        return nil
    }

    /// The routing profile that recalculates a route's changed legs. Choosing one recalculates nothing by itself.
    private func routingPicker(_ route: Route) -> some View {
        Picker("Routing", selection: Binding(
            get: { route.profileID },
            set: { store.setRouteProfile(route.id, profileID: $0) }
        )) {
            Text("None (straight lines)").tag(UUID?.none)
            ForEach(planner.profiles) { profile in
                Text(profile.name).tag(UUID?.some(profile.id))
            }
            // A profile that was deleted since: shown, so the picker is not blank.
            if let id = route.profileID, !planner.profiles.contains(where: { $0.id == id }) {
                Text("Deleted profile").tag(UUID?.some(id))
            }
        }
        .help("The profile that recalculates legs when their stops change, in the background. Choosing a profile recalculates nothing by itself.")
    }

    /// The route's stops, each with its name, its kind, its distance from the start, and a button to delete it. The
    /// leg to the next stop is described under each stop. The first and last stops are always via points.
    @ViewBuilder
    private func routePointList(_ route: Route) -> some View {
        let distances = route.stopDistances()
        Section("Stops (\(route.stops.count))") {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                            stopRow(stop, index: index, count: route.stops.count, route: route, distance: distances.indices.contains(index) ? distances[index] : nil)
                                .padding(2)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(stop.id == store.selectedStop ? Color.accentColor.opacity(0.18) : .clear)
                                )
                                .id(stop.id)
                            if index < route.legs.count {
                                Text(legDescription(route.legs[index], failure: recalculator.failure(route: route, leg: index)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                }
                .frame(height: min(420, CGFloat(route.stops.count) * 72 + 8))
                .onChange(of: store.selectedStop) { _, stop in
                    // A stop clicked on the map is brought into view.
                    if let stop { withAnimation { scroller.scrollTo(stop, anchor: .center) } }
                }
            }
            Text("Click a point on the map to find it here. Drag a point, or the line, to change the route; right-click for more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One stop: its number, name and delete button on the first line; its kind, distance and height on the second.
    private func stopRow(_ stop: RouteStop, index: Int, count: Int, route: Route, distance: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                TextField("Point \(index + 1)", text: Binding(
                    get: { stop.name ?? "" },
                    set: { store.renameRouteStop(route.id, stop: stop.id, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .controlSize(.small)
                Button(role: .destructive) {
                    store.removeRouteStop(route.id, at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this point")
            }
            HStack(spacing: 6) {
                Picker("Kind", selection: Binding(
                    get: { stop.isShaping },
                    set: { store.setRouteStopShaping(route.id, stop: stop.id, isShaping: $0) }
                )) {
                    Text("Via").tag(false)
                    Text("Shaping").tag(true)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 92)
                // The first and last stops are always via points.
                .disabled(index == 0 || index == count - 1)
                Spacer(minLength: 0)
                if let distance {
                    Text(UnitFormat.distance(distance, display.units))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let height = stop.elevation {
                    Text(UnitFormat.elevation(height, display.units))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 24)
        }
    }

    /// How a leg was made: straight, calculated with a named profile, imported, or waiting for recalculation.
    /// While legs wait for the router: that they are being recalculated, or that some could not be, with a button to
    /// try again. Option-click on the map adds a stop after the end; the handles in the middle of the legs insert one.
    @ViewBuilder
    private func recalculationStatus(_ route: Route) -> some View {
        let waiting = route.legsWaitingForRouter
        if !waiting.isEmpty {
            let failed = waiting.contains { recalculator.failure(route: route, leg: $0) != nil }
            HStack {
                if recalculator.isWorking(on: route.id) {
                    ProgressView().controlSize(.small)
                    Text("Recalculating \(waiting.count) leg(s)…")
                } else if failed {
                    Text("Some legs could not be recalculated.")
                    Spacer()
                    Button("Try Again") {
                        recalculator.retry(route.id, store: store, planner: planner, settings: routing, demFolder: elevation.folder)
                    }
                } else {
                    Text("\(waiting.count) leg(s) waiting for the router.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func legDescription(_ leg: RouteLeg, failure: String?) -> String {
        if let failure, leg.needsRecalculation {
            return "Not recalculated: \(failure)"
        }
        return legDescription(leg)
    }

    private func legDescription(_ leg: RouteLeg) -> String {
        switch leg.state {
        case .straight:
            return "Straight"
        case .calculated(let profileID):
            guard let profileID, let profile = planner.profiles.first(where: { $0.id == profileID }) else {
                return "Calculated"
            }
            return "Calculated (\(profile.name))"
        case .imported:
            return "Imported"
        case .waiting:
            return "Waiting to be recalculated"
        }
    }

    private func convertTitle(_ item: LibraryItem) -> String {
        switch item {
        case .track: "Convert to Route"
        case .route: "Convert to Track"
        case .waypoint: "Convert"
        }
    }

    @ViewBuilder
    private func statisticsSections(_ stats: ActivityStatistics, profile: [ElevationProfilePoint]) -> some View {
        Section("Statistics") {
            LabeledContent("Distance", value: UnitFormat.distance(stats.distanceMeters, display.units))
            if let total = stats.totalTime, let text = Format.seconds(total) {
                LabeledContent("Total time", value: text)
            }
            if let moving = stats.movingTime, let text = Format.seconds(moving) {
                LabeledContent("Moving time", value: text)
            }
            if let speed = stats.averageSpeed {
                LabeledContent("Average speed", value: UnitFormat.speed(speed, display.units))
            }
            if let speed = stats.maximumSpeed {
                LabeledContent("Maximum speed", value: UnitFormat.speed(speed, display.units))
            }
            if let ascent = stats.ascentMeters {
                LabeledContent("Ascent", value: UnitFormat.elevation(ascent, display.units))
            }
            if let descent = stats.descentMeters {
                LabeledContent("Descent", value: UnitFormat.elevation(descent, display.units))
            }
            if let lowest = stats.minimumElevation {
                LabeledContent("Lowest", value: UnitFormat.elevation(lowest, display.units))
            }
            if let highest = stats.maximumElevation {
                LabeledContent("Highest", value: UnitFormat.elevation(highest, display.units))
            }
        }
        if profile.count > 1 {
            Section("Elevation profile") {
                ElevationChart(profile: profile)
            }
        }
    }

    @ViewBuilder
    private func sendSection(name: String, points: [CoursePoint]) -> some View {
        Section("Garmin Edge") {
            if device.isConnected {
                Button {
                    device.sendCourse(name: name, points: points)
                } label: {
                    if device.isSending {
                        Label("Sending…", systemImage: "arrow.up.circle")
                    } else {
                        Label("Send to Edge as Course", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(device.isSending)
            } else {
                Text("Connect the Edge over USB to send this as a course.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension ItemColor {
    /// The colour as SwiftUI shows it.
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// The colour a SwiftUI colour picker chose, in sRGB.
    init(_ color: Color) {
        let components = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: components.redComponent, green: components.greenComponent, blue: components.blueComponent)
    }
}
