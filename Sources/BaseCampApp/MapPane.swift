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
    @State private var libraryLayer = LibraryLayerCache()

    var body: some View {
        MapKitView(
            base: layers.base,
            garminFolder: mapSettings.folder,
            garminDetail: layers.garminDetail,
            showContours: layers.showContours,
            contourOpacity: layers.contourOpacity,
            scene: scene,
            fitRequest: store.fitRequest,
            fitCoordinates: store.fitCoordinates,
            onMapClick: { coordinate in
                if planner.isActive {
                    planner.add(coordinate)
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
                store.moveRoutePoint(reference.route, at: reference.index, to: coordinate)
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
            await coverage.reload(folder: mapSettings.folder)
        }
        .overlay {
            if store.library.isEmpty && planner.via.isEmpty {
                emptyState
            }
        }
    }

    /// Everything the map draws, built from the library and the planner, one layer at a time.
    private var scene: MapScene {
        var parts: [MapLayerKind: MapLayerContent] = [:]
        parts[.coverage] = coverageLayer
        parts[.library] = libraryLayer.content(revision: store.revision, selectedItems: store.selectedItems, build: buildLibraryLayer)
        parts[.planner] = plannerLayer
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
                style: .waypoint(selected: selected),
                item: .waypoint(waypoint.id),
                title: waypoint.name,
                showsLabel: true
            ))
        }

        // Selected lines are drawn last, so they are not hidden under the others.
        var selectedLines: [MapLine] = []
        for route in store.library.routes {
            let selected = store.selectedItems.contains(.route(route.id))
            let line = MapLine(id: "route-\(route.id)", coordinates: route.points.map(\.coordinate), color: selected ? .red : .blue)
            if selected {
                selectedLines.append(line)
            } else {
                content.lines.append(line)
            }
        }

        // The points of the selected route can be dragged, when there are few enough to handle one by one.
        if case .route(let id)? = store.selection, let selectedRoute = store.route(id),
           selectedRoute.points.count <= LibraryStore.draggableRoutePointLimit {
            for (index, point) in selectedRoute.points.enumerated() {
                content.pins.append(MapPin(
                    id: "route-point-\(selectedRoute.id)-\(index)",
                    coordinate: point.coordinate,
                    style: .routePoint,
                    item: nil,
                    title: point.name ?? "Point \(index + 1)",
                    routePoint: RoutePointRef(route: selectedRoute.id, index: index)
                ))
            }
        }

        for track in store.library.tracks {
            let selected = store.selectedItems.contains(.track(track.id))
            for (index, segment) in track.segments.enumerated() {
                let line = MapLine(
                    id: "track-\(track.id)-\(index)",
                    coordinates: segment.map(\.coordinate),
                    color: selected ? .red : .orange
                )
                if selected {
                    selectedLines.append(line)
                } else {
                    content.lines.append(line)
                }
            }
        }
        content.lines += selectedLines
        return content
    }

    private var plannerLayer: MapLayerContent {
        var content = MapLayerContent()
        for (index, point) in planner.via.enumerated() {
            content.pins.append(MapPin(
                id: "via-\(index)",
                coordinate: point,
                style: .via(number: index + 1),
                item: nil,
                title: "Point \(index + 1)"
            ))
        }
        if let plan = planner.plan {
            content.lines.append(MapLine(
                id: "planned-route",
                coordinates: plan.geometry.points.map(\.coordinate),
                color: .teal
            ))
            for (index, section) in plan.remainingSteepSections.enumerated() {
                content.circles.append(MapCircleShape(
                    id: "steep-circle-\(index)",
                    center: section.center,
                    radiusMeters: section.lengthMeters / 2 + 25
                ))
                content.pins.append(MapPin(
                    id: "steep-pin-\(index)",
                    coordinate: section.center,
                    style: .steep(percent: Int(section.maxGradePercent.rounded())),
                    item: nil,
                    title: "Climb above \(Int(section.maxGradePercent.rounded()))%"
                ))
            }
        }
        return content
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
        let base = layers.pictureBase(folder: mapSettings.folder)
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
        Text(layers.attribution)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to show", systemImage: "map")
        } description: {
            Text("Drop GPX files here, or import them to add waypoints, routes and tracks.")
        } actions: {
            Button("Import GPX…") {
                store.showImportPanel()
            }
        }
    }
}

/// Keeps the library layer until the library or the selection changes, so that other changes to the map, such as the
/// profile cursor moving, do not rebuild it. Handing back the same arrays also keeps the map's comparison quick.
@MainActor
final class LibraryLayerCache {
    private var revision: Int?
    private var selectedItems: Set<LibraryItem> = []
    private var cached = MapLayerContent()

    func content(revision: Int, selectedItems: Set<LibraryItem>, build: () -> MapLayerContent) -> MapLayerContent {
        if revision != self.revision || selectedItems != self.selectedItems {
            cached = build()
            self.revision = revision
            self.selectedItems = selectedItems
        }
        return cached
    }
}
