import AppKit
import BaseCampCore
import BaseCampIMG
import SwiftUI

/// The map. Everything in the library is drawn, and the selected item is highlighted in red.
/// While planning a route, clicks add route points, and the planned route is drawn with its
/// climbs that are still too steep marked.
struct MapPane: View {
    @Environment(LibraryStore.self) private var store
    @Environment(RoutePlanner.self) private var planner
    @Environment(MapLayerSettings.self) private var layers
    @Environment(MapCoverageStore.self) private var coverage
    @Environment(MapSettings.self) private var mapSettings
    @Environment(DisplaySettings.self) private var display
    @Environment(GarminMapListStore.self) private var garminMaps
    @State private var libraryLayer = LibraryLayerCache()
    /// The visible area and scale, for the place names.
    @State private var viewport: PlaceQuery?
    /// The names the Garmin maps write in view.
    @State private var names = MapNames()

    var body: some View {
        MapKitView(
            base: layers.base,
            garmin: layers.garminConfiguration(garminMaps),
            showContours: layers.showContours,
            contourOpacity: layers.contourOpacity,
            scene: scene,
            fitRequest: store.fitRequest,
            fitCoordinates: store.fitCoordinates,
            onMapClick: { coordinate, line in
                if planner.isActive {
                    planner.click(coordinate, store: store)
                } else if store.measuring {
                    store.measurePoints.append(coordinate)
                } else if let line {
                    // As in BaseCamp, clicking a track or route on the map selects it in the library.
                    store.selection = line
                }
            },
            onSelect: { item in
                store.selection = item
            },
            onViewportChange: { bounds, metersPerPoint in
                viewport = PlaceQuery(bounds: bounds, metersPerPoint: metersPerPoint)
                store.viewCenter = Coordinate(
                    latitude: (bounds.north + bounds.south) / 2,
                    longitude: (bounds.east + bounds.west) / 2
                )
                store.viewBounds = bounds
            },
            onMovePoint: { reference, coordinate in
                if reference.isInsertion {
                    store.insertRouteStop(reference.route, at: reference.index + 1, coordinate: coordinate)
                } else {
                    store.moveRouteStop(reference.route, at: reference.index, to: coordinate)
                }
            },
            onOptionClick: { coordinate in
                // Option-click adds a stop after the end of the selected route, as BaseCamp's route tool does.
                guard !planner.isActive, !store.measuring, case .route(let id)? = store.selection else { return }
                store.extendRoute(id, to: coordinate)
            },
            editableRoute: selectedRoute,
            onStopClick: { reference in
                store.selectedStop = store.route(reference.route)?.stops[safe: reference.index]?.id
            },
            profileLine: store.selectedMeasure,
            onProfileHover: { distance in
                store.profileCursor = distance
            },
            contextMenu: contextMenu,
            locateRequest: store.locateRequest,
            onLocationProblem: { message in
                store.errorMessage = message
            }
        )
        .overlay(alignment: .bottomLeading) {
            attribution
        }
        .overlay(alignment: .top) {
            if store.measuring {
                measureBar
            }
        }
        .onChange(of: store.mapImageRequest) { _, _ in
            saveImage()
        }
        .task(id: placeRequest) {
            await loadPlaces(placeRequest)
        }
        .task(id: mapSettings.folder) {
            await garminMaps.reload(folder: mapSettings.folder)
            await coverage.reload(folder: mapSettings.folder)
        }
        .overlay(alignment: .bottom) {
            // A small bar, so the map stays usable everywhere else: BaseCamp shows nothing over its map.
            if store.library.isEmpty && !planner.isActive {
                emptyState
            }
        }
    }

    /// What the place names are read for: the view, and the Garmin maps drawn in it. Nil when the base map is not
    /// the Garmin maps.
    private var placeRequest: PlaceRequest? {
        guard layers.base == .garmin, let viewport else { return nil }
        let garmin = layers.garminConfiguration(garminMaps)
        let zoom = viewport.zoom
        let maps = garmin.layers.filter { !$0.isOverlay && $0.isVisible(atZoom: zoom) }.map(\.url)
        guard !maps.isEmpty else { return nil }
        return PlaceRequest(
            viewport: viewport, maps: maps, detailOffset: garmin.detailOffset, hiddenPointTypes: garmin.hiddenPointTypes,
            zoomedOutPointTypes: garmin.zoomedOutPointTypes
        )
    }

    private func loadPlaces(_ request: PlaceRequest?) async {
        guard let request else {
            names = MapNames()
            return
        }
        // Waits for the map to settle, so panning does not read the maps at every step.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let read = await Self.names(for: request) else { return }
        names = read
    }

    /// The names the Garmin maps write in a view, read a little beyond it so names at its edges are kept. Nil when
    /// the task was cancelled.
    static func names(for request: PlaceRequest) async -> MapNames? {
        let b = request.viewport.bounds
        let margin = (lat: (b.north - b.south) * 0.1, lon: (b.east - b.west) * 0.1)
        let area = GeoBounds(north: b.north + margin.lat, east: b.east + margin.lon, south: b.south - margin.lat, west: b.west - margin.lon)
        var found: [MapPlace] = []
        for map in request.maps {
            found += await MapFeatureCache.shared.places(
                in: area, metersPerPoint: request.viewport.metersPerPoint, map: map, detailOffset: request.detailOffset
            )
        }
        guard !Task.isCancelled else { return nil }
        var names = MapNames()
        names.places = MapPlace.merged(found)
        names.points = await pointNames(in: area, request: request)
        names.areas = await areaNames(in: area, request: request, places: names.places)

        // Street names from about zoom 15, where there is room for them between the streets.
        guard request.viewport.metersPerPoint <= streetNameScale else { return names }
        var lines: [NamedLine] = []
        for map in request.maps {
            lines += await MapFeatureCache.shared.namedLines(
                in: area, metersPerPoint: request.viewport.metersPerPoint, map: map, detailOffset: request.detailOffset
            )
        }
        guard !Task.isCancelled else { return nil }
        names.streets = Array(StreetLabels.place(lines, metersPerPoint: request.viewport.metersPerPoint).prefix(600))
        return names
    }

    /// Street names are written from this scale in, in metres per point (about zoom 15).
    static let streetNameScale = 4.5

    /// Area names written, at most, in one view.
    static let maximumAreaNames = 150

    /// The names of the areas in the view, each in the part of its area that shows, largest first, clear of the
    /// place names (which would hide them: a lake's middle often has a hamlet's name).
    static func areaNames(in area: GeoBounds, request: PlaceRequest, places: [MapPlace] = []) async -> [AreaLabel] {
        var areas: [NamedArea] = []
        for map in request.maps {
            areas += await MapFeatureCache.shared.namedAreas(
                in: area, metersPerPoint: request.viewport.metersPerPoint, map: map, detailOffset: request.detailOffset
            )
        }
        let b = request.viewport.bounds
        let view = (southWest: Coordinate(latitude: b.south, longitude: b.west), northEast: Coordinate(latitude: b.north, longitude: b.east))
        // The place names' boxes, from their font sizes (see `MarkerImage.place`).
        let boxes = places.map { place -> LabelBox in
            let size: Double = place.rank >= 3 ? 14 : place.rank == 2 ? 12.5 : place.rank == 1 ? 11 : 10
            return LabelBox(center: place.coordinate, width: Double(place.name.count) * size * 0.6 + 6, height: size * 1.3 + 4)
        }
        let placed = AreaLabels.place(areas, in: view, metersPerPoint: request.viewport.metersPerPoint, avoiding: boxes)
        return Array(placed.prefix(maximumAreaNames))
    }

    /// Point names written, at most, in one view.
    static let maximumPointNames = 400

    /// The named points the tiles draw icons for, whose style writes their name. The tiles are drawn at a whole
    /// zoom near the view's; points are thinned for the whole zoom below it, which are drawn at either (a coarser
    /// zoom's squares each hold four of the next one's), so every name has its icon.
    static func pointNames(in area: GeoBounds, request: PlaceRequest) async -> [POIName] {
        let zoom = Int(request.viewport.zoomLevel.rounded(.down))
        let middle = (area.north + area.south) / 2 * .pi / 180
        let metersPerPoint = 40_075_016.686 * cos(middle) / (256 * pow(2, Double(zoom)))
        var all: [POIName] = []
        for map in request.maps {
            all += await MapFeatureCache.shared.pointNames(
                in: area, metersPerPoint: metersPerPoint, map: map, detailOffset: request.detailOffset
            )
        }
        all.removeAll { request.hiddenPointTypes.contains($0.poi.type) }
        var byPoint: [String: POIName] = [:]
        for name in all {
            byPoint["\(name.poi.type)|\(name.poi.coordinate.latitude)|\(name.poi.coordinate.longitude)"] = name
        }
        let named = MapPOI.shown(all.map(\.poi), zoom: zoom, zoomedOut: request.zoomedOutPointTypes).compactMap { poi -> POIName? in
            guard poi.name != nil, let name = byPoint["\(poi.type)|\(poi.coordinate.latitude)|\(poi.coordinate.longitude)"],
                  name.labelled else { return nil }
            return name
        }
        return Array(named.sorted { ($0.poi.isLandmark ? 1 : 0) > ($1.poi.isLandmark ? 1 : 0) }.prefix(maximumPointNames))
    }

    /// The place names, as text-only markers. MapKit keeps the more important of two that would overlap.
    private var placeLayer: MapLayerContent {
        MapLayerContent(pins: names.pins)
    }

    /// The colour of the stretch picked on a profile: a magenta that stands out from the tracks, routes and maps.
    static let pickedStretchColour = MapRGB(red: 0.88, green: 0.10, blue: 0.72)

    /// Everything the map draws, built from the library and the planner, one layer at a time.
    private var scene: MapScene {
        var parts: [MapLayerKind: MapLayerContent] = [:]
        parts[.places] = placeLayer
        parts[.coverage] = coverageLayer
        parts[.library] = libraryLayer.content(
            revision: LibraryLayerCache.Revision(
                library: store.revision, device: store.deviceRevision, deviceGroupsOnMap: store.deviceGroupsOnMap
            ),
            selectedItems: store.selectedItems, selectedStop: store.selectedStop, build: buildLibraryLayer
        )
        parts[.measure] = measureLayer
        if let range = store.profileRange, let measure = store.selectedMeasure {
            // Drawn over the selected line, so the stretch picked on the profile can be seen on the map.
            parts[.profileRange] = MapLayerContent(lines: measure.section(range).enumerated().map { index, piece in
                MapLine(id: "profile-range-\(index)", coordinates: piece, color: .measure, rgb: Self.pickedStretchColour, width: 7)
            })
        }
        if let cursor = store.profileCoordinate {
            parts[.cursor] = MapLayerContent(pins: [
                MapPin(id: "profile-cursor", coordinate: cursor, style: .cursor, item: nil, title: "Profile position"),
            ])
        }
        return MapScene(layers: parts)
    }

    /// Waypoints, routes and tracks, highlighted when selected, and the points of the selected route that can be dragged.
    private func buildLibraryLayer() -> MapLayerContent {
        var content = MapLayerContent()
        for waypoint in store.library.waypoints {
            let selected = store.selectedItems.contains(.waypoint(waypoint.id))
            content.pins.append(MapPin(
                id: "waypoint-\(waypoint.id)",
                coordinate: waypoint.coordinate,
                style: .waypoint(selected: selected, symbol: waypoint.symbol),
                item: .waypoint(waypoint.id),
                title: waypoint.name,
                showsLabel: true
            ))
        }

        // Selected lines are drawn last, so they are not hidden under the others. Each has a halo under it, and all
        // the halos are drawn before any selected line, so one item's halo never covers another selected line.
        var selectedHalos: [MapLine] = []
        var selectedLines: [MapLine] = []
        for route in store.library.routes {
            let selected = store.selectedItems.contains(.route(route.id))
            for line in Self.routeLines(route) {
                if selected {
                    selectedHalos.append(Self.selectionHalo(for: line))
                    selectedLines.append(line)
                } else {
                    content.lines.append(line)
                }
            }
        }

        // The stops of the selected route can be dragged.
        if case .route(let id)? = store.selection, let selectedRoute = store.route(id) {
            for (index, point) in selectedRoute.stops.enumerated() {
                content.pins.append(MapPin(
                    id: "route-point-\(selectedRoute.id)-\(index)",
                    coordinate: point.coordinate,
                    style: .routePoint(selected: point.id == store.selectedStop),
                    item: nil,
                    title: point.name ?? "Point \(index + 1)",
                    routePoint: RoutePointRef(route: selectedRoute.id, index: index)
                ))
            }
            // A handle in the middle of each leg: drag it to insert a stop.
            for leg in selectedRoute.legs.indices {
                guard let middle = selectedRoute.legMidpoint(leg) else { continue }
                content.pins.append(MapPin(
                    id: "route-insert-\(selectedRoute.id)-\(leg)",
                    coordinate: middle,
                    style: .insertHandle,
                    item: nil,
                    title: "Drag to insert a point",
                    routePoint: RoutePointRef(route: selectedRoute.id, index: leg, isInsertion: true)
                ))
            }
        }

        for track in store.library.tracks {
            let selected = store.selectedItems.contains(.track(track.id))
            for (index, segment) in track.segments.enumerated() {
                let line = MapLine(
                    id: "track-\(track.id)-\(index)",
                    coordinates: segment.map(\.coordinate),
                    color: .orange,
                    rgb: track.color.map(MapRGB.init),
                    item: .track(track.id)
                )
                if selected {
                    selectedHalos.append(Self.selectionHalo(for: line))
                    selectedLines.append(line)
                } else {
                    content.lines.append(line)
                }
            }
        }
        addDeviceItems(to: &content, selectedHalos: &selectedHalos, selectedLines: &selectedLines)
        content.lines += selectedHalos + selectedLines
        return content
    }

    /// The connected device's items: those of the folders shown on the map, and any selected. Their lines are teal,
    /// so they are told apart from the library's.
    private func addDeviceItems(to content: inout MapLayerContent, selectedHalos: inout [MapLine], selectedLines: inout [MapLine]) {
        for group in store.device.groups {
            let shown = store.deviceGroupsOnMap.contains(group.id)
            for waypoint in group.library.waypoints {
                let selected = store.selectedItems.contains(.waypoint(waypoint.id))
                guard shown || selected else { continue }
                content.pins.append(MapPin(
                    id: "device-waypoint-\(waypoint.id)",
                    coordinate: waypoint.coordinate,
                    style: .waypoint(selected: selected, symbol: waypoint.symbol),
                    item: .waypoint(waypoint.id),
                    title: waypoint.name,
                    showsLabel: true
                ))
            }
            let lines = group.library.routes.map { (LibraryItem.route($0.id), [$0.points.map(\.coordinate)]) }
                + group.library.tracks.map { (LibraryItem.track($0.id), $0.segments.map { $0.map(\.coordinate) }) }
            for (item, pieces) in lines {
                let selected = store.selectedItems.contains(item)
                guard shown || selected else { continue }
                for (index, piece) in pieces.enumerated() where piece.count > 1 {
                    let line = MapLine(id: "device-\(item)-\(index)", coordinates: piece, color: .teal, item: item)
                    if selected {
                        selectedHalos.append(Self.selectionHalo(for: line))
                        selectedLines.append(line)
                    } else {
                        content.lines.append(line)
                    }
                }
            }
        }
    }

    /// A route's line, cut where legs start or stop waiting for the router: those legs are drawn dashed.
    private static func routeLines(_ route: Route) -> [MapLine] {
        let rgb = route.color.map(MapRGB.init)
        guard route.legs.contains(where: \.needsRecalculation) else {
            return [MapLine(id: "route-\(route.id)", coordinates: route.points.map(\.coordinate), color: .blue, rgb: rgb, item: .route(route.id))]
        }
        var lines: [MapLine] = []
        var run: [Coordinate] = []
        var runIsWaiting = false
        for leg in route.legs.indices {
            let waiting = route.legs[leg].needsRecalculation
            if !run.isEmpty, waiting != runIsWaiting {
                lines.append(MapLine(id: "route-\(route.id)-\(lines.count)", coordinates: run, color: .blue, rgb: rgb, dashed: runIsWaiting, item: .route(route.id)))
                run = []
            }
            runIsWaiting = waiting
            let line = route.legLine(leg)
            run += run.isEmpty ? line : Array(line.dropFirst())
        }
        if !run.isEmpty {
            lines.append(MapLine(id: "route-\(route.id)-\(lines.count)", coordinates: run, color: .blue, rgb: rgb, dashed: runIsWaiting, item: .route(route.id)))
        }
        return lines
    }

    /// The selected route, when exactly one item is selected and it is a route.
    private var selectedRoute: Route? {
        guard case .route(let id)? = store.selection else { return nil }
        return store.route(id)
    }

    /// The map's context menu: for a stop of the selected route, its line, or anywhere else.
    private func contextMenu(_ target: MapContextTarget) -> [MapMenuItem] {
        switch target {
        case .stop(let reference):
            guard let route = store.route(reference.route), let stop = route.stops[safe: reference.index] else { return [] }
            let isEnd = reference.index == 0 || reference.index == route.stops.count - 1
            return [
                MapMenuItem(title: "Delete Point") { store.removeRouteStop(route.id, at: reference.index) },
                MapMenuItem(title: stop.isShaping ? "Make Via Point" : "Make Shaping Point", isEnabled: !isEnd) {
                    store.setRouteStopShaping(route.id, stop: stop.id, isShaping: !stop.isShaping)
                },
            ]
        case .leg(let route, let leg, let coordinate):
            return [
                MapMenuItem(title: "Insert Point Here") { store.insertRouteStop(route, at: leg + 1, coordinate: coordinate) },
            ]
        case .map(let coordinate):
            var items = [
                MapMenuItem(title: "New Waypoint Here") {
                    store.addWaypoint(name: "Waypoint \(store.library.waypoints.count + 1)", coordinate: coordinate)
                },
                MapMenuItem(title: "New Route from Here") {
                    planner.isActive = true
                    planner.click(coordinate, store: store, startNew: true)
                },
            ]
            if let route = selectedRoute {
                items += [
                    .separator,
                    MapMenuItem(title: "Extend \(route.name) to Here") { store.extendRoute(route.id, to: coordinate) },
                ]
            }
            return items
        }
    }

    /// The pale halo under a selected line: the same path, four points wider, in white. The item keeps its colour.
    private static func selectionHalo(for line: MapLine) -> MapLine {
        MapLine(id: "halo-\(line.id)", coordinates: line.coordinates, color: line.color, rgb: MapRGB(red: 1, green: 1, blue: 1), width: line.width + 4)
    }

    private var measureLayer: MapLayerContent {
        var content = MapLayerContent()
        guard store.measuring, !store.measurePoints.isEmpty else { return content }
        content.lines.append(MapLine(id: "measure", coordinates: store.measurePoints, color: .measure))
        for (index, point) in store.measurePoints.enumerated() {
            content.pins.append(MapPin(
                id: "measure-\(index)",
                coordinate: point,
                style: .via(number: index + 1),
                item: nil,
                title: "Measure point \(index + 1)"
            ))
        }
        return content
    }

    private var coverageLayer: MapLayerContent {
        var content = MapLayerContent()
        guard layers.showCoverage else { return content }
        content.footprints = coverage.footprints
        for footprint in coverage.footprints {
            content.pins.append(MapPin(
                id: "coverage-\(footprint.name)",
                coordinate: footprint.center,
                style: .label(footprint.name),
                item: nil,
                title: footprint.name
            ))
        }
        return content
    }

    /// Asks where to save, then writes the visible map as a PNG.
    private func saveImage() {
        guard let bounds = store.viewBounds, let url = imageDestination() else { return }
        let scene = self.scene
        let base = layers.pictureBase(garmin: garminMaps)
        Task {
            do {
                let rendered = try await MapImageExport.render(scene: scene, bounds: bounds, size: CGSize(width: 1600, height: 1200), base: base)
                guard let data = MapImageExport.pngData(rendered.image) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
                if let message = rendered.missingTilesMessage {
                    store.errorMessage = message
                }
            } catch {
                store.errorMessage = "The map image could not be saved. \(error.localizedDescription)"
            }
        }
    }

    /// The file to write: the `--map-image` path in debug builds, otherwise one the user picks.
    private func imageDestination() -> URL? {
        #if DEBUG
        if let testPath = BaseCampApp.testMapImagePath {
            return testPath
        }
        #endif
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Map.png"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Shows the measured distance, with buttons to clear it and to stop measuring.
    private var measureBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler")
            Text(store.measurePoints.count < 2
                ? "Click the map to measure a distance"
                : "\(UnitFormat.distance(store.measuredDistance, display.units)) over \(store.measurePoints.count) points")
                .monospacedDigit()
            Button("Clear") {
                store.measurePoints = []
            }
            .disabled(store.measurePoints.isEmpty)
            Button("Done") {
                store.toggleMeasuring()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }

    private var attribution: some View {
        Text(layers.base == .garmin
            ? (garminMaps.enabledTitles.isEmpty ? "No Garmin map is ticked in the Map menu" : garminMaps.enabledTitles.joined(separator: " · "))
                + (layers.showContours ? " · " + MapTileURLs.contourAttribution : "")
            : layers.attribution)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
            Text("Your library is empty. Drop GPX files on the map, or")
            Button("Import…") {
                store.showImportPanel()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 36)
    }
}

/// Keeps the library layer until the library or the selection changes, so that other changes to the map, such as the
/// profile cursor moving, do not rebuild it. Handing back the same arrays also keeps the map's comparison quick.
@MainActor
final class LibraryLayerCache {
    /// The library's revision, the device's, and the device folders shown.
    struct Revision: Equatable {
        let library: Int
        let device: Int
        let deviceGroupsOnMap: Set<String>
    }

    private var revision: Revision?
    private var selectedItems: Set<LibraryItem> = []
    private var selectedStop: UUID?
    private var cached = MapLayerContent()

    func content(revision: Revision, selectedItems: Set<LibraryItem>, selectedStop: UUID?, build: () -> MapLayerContent) -> MapLayerContent {
        if revision != self.revision || selectedItems != self.selectedItems || selectedStop != self.selectedStop {
            cached = build()
            self.revision = revision
            self.selectedItems = selectedItems
            self.selectedStop = selectedStop
        }
        return cached
    }
}


/// The visible area of the map and its scale.
struct PlaceQuery: Equatable {
    let bounds: GeoBounds
    let metersPerPoint: Double

    /// The Web Mercator zoom this scale is nearest to, as the tiles count it.
    var zoom: Int {
        Int(zoomLevel.rounded())
    }

    /// The Web Mercator zoom of this scale, with its fraction.
    var zoomLevel: Double {
        let middle = (bounds.north + bounds.south) / 2 * .pi / 180
        return log2(40_075_016.686 * cos(middle) / (256 * max(metersPerPoint, 0.01)))
    }
}

/// The place names to read: the view, and the Garmin maps drawn in it.
struct PlaceRequest: Equatable {
    let viewport: PlaceQuery
    let maps: [URL]
    let detailOffset: Int
    var hiddenPointTypes: Set<Int> = []
    var zoomedOutPointTypes = MapPOI.defaultZoomedOutTypes
}

/// The names the Garmin maps write in a view: places, points of interest, areas and, zoomed in, streets.
struct MapNames {
    var places: [MapPlace] = []
    var points: [POIName] = []
    var areas: [AreaLabel] = []
    var streets: [StreetLabel] = []

    /// The names as text-only markers; the map, or a saved picture, keeps the more important of two that overlap.
    var pins: [MapPin] {
        var pins: [MapPin] = []
        for place in places {
            let id = "place-\(place.name)-\(place.coordinate.latitude)-\(place.coordinate.longitude)"
            pins.append(MapPin(
                id: id, coordinate: place.coordinate, style: .place(rank: place.rank, size: place.size), item: nil, title: place.name
            ))
        }
        for label in areas {
            pins.append(MapPin(
                id: "area-\(label.name)-\(label.coordinate.latitude)-\(label.coordinate.longitude)",
                coordinate: label.coordinate,
                style: .areaName(kind: label.kind, importance: label.importance),
                item: nil, title: label.name
            ))
        }
        for point in points {
            guard let name = point.poi.name else { continue }
            pins.append(MapPin(
                id: "poi-\(point.poi.type)-\(point.poi.coordinate.latitude)-\(point.poi.coordinate.longitude)",
                coordinate: point.poi.coordinate,
                style: .pointName(
                    landmark: point.poi.isLandmark, iconWidth: point.iconWidth, size: point.size.rawValue, rgb: point.colour
                ),
                item: nil, title: name
            ))
        }
        for street in streets {
            let degrees = Int((street.angle * 180 / .pi / 3).rounded()) * 3
            pins.append(MapPin(
                id: "street-\(street.name)-\(street.coordinate.latitude)-\(street.coordinate.longitude)",
                coordinate: street.coordinate,
                style: .street(angle: degrees, importance: street.importance, water: street.isWater),
                item: nil, title: street.name
            ))
        }
        return pins
    }
}
