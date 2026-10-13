import AppKit
import BaseCampCore
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

    var body: some View {
        MapKitView(
            base: layers.base,
            garmin: garminMaps.configuration(detail: layers.garminDetail, softColors: layers.garminSoftColors),
            showContours: layers.showContours,
            contourOpacity: layers.contourOpacity,
            scene: scene,
            fitRequest: store.fitRequest,
            fitCoordinates: store.fitCoordinates,
            onMapClick: { coordinate in
                if planner.isActive {
                    planner.click(coordinate, store: store)
                } else if store.measuring {
                    store.measurePoints.append(coordinate)
                }
            },
            onSelect: { item in
                store.selection = item
            },
            onViewportChange: { bounds, _ in
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

    /// Everything the map draws, built from the library and the planner, one layer at a time.
    private var scene: MapScene {
        var parts: [MapLayerKind: MapLayerContent] = [:]
        parts[.coverage] = coverageLayer
        parts[.library] = libraryLayer.content(
            revision: store.revision, selectedItems: store.selectedItems, selectedStop: store.selectedStop, build: buildLibraryLayer
        )
        parts[.measure] = measureLayer
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
                    rgb: track.color.map(MapRGB.init)
                )
                if selected {
                    selectedHalos.append(Self.selectionHalo(for: line))
                    selectedLines.append(line)
                } else {
                    content.lines.append(line)
                }
            }
        }
        content.lines += selectedHalos + selectedLines
        return content
    }

    /// A route's line, cut where legs start or stop waiting for the router: those legs are drawn dashed.
    private static func routeLines(_ route: Route) -> [MapLine] {
        let rgb = route.color.map(MapRGB.init)
        guard route.legs.contains(where: \.needsRecalculation) else {
            return [MapLine(id: "route-\(route.id)", coordinates: route.points.map(\.coordinate), color: .blue, rgb: rgb)]
        }
        var lines: [MapLine] = []
        var run: [Coordinate] = []
        var runIsWaiting = false
        for leg in route.legs.indices {
            let waiting = route.legs[leg].needsRecalculation
            if !run.isEmpty, waiting != runIsWaiting {
                lines.append(MapLine(id: "route-\(route.id)-\(lines.count)", coordinates: run, color: .blue, rgb: rgb, dashed: runIsWaiting))
                run = []
            }
            runIsWaiting = waiting
            let line = route.legLine(leg)
            run += run.isEmpty ? line : Array(line.dropFirst())
        }
        if !run.isEmpty {
            lines.append(MapLine(id: "route-\(route.id)-\(lines.count)", coordinates: run, color: .blue, rgb: rgb, dashed: runIsWaiting))
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
    private var revision: Int?
    private var selectedItems: Set<LibraryItem> = []
    private var selectedStop: UUID?
    private var cached = MapLayerContent()

    func content(revision: Int, selectedItems: Set<LibraryItem>, selectedStop: UUID?, build: () -> MapLayerContent) -> MapLayerContent {
        if revision != self.revision || selectedItems != self.selectedItems || selectedStop != self.selectedStop {
            cached = build()
            self.revision = revision
            self.selectedItems = selectedItems
            self.selectedStop = selectedStop
        }
        return cached
    }
}
