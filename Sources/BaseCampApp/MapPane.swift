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
    @Environment(MapFeatureStore.self) private var features
    @Environment(MapSettings.self) private var mapSettings
    @Environment(DisplaySettings.self) private var display

    var body: some View {
        MapKitView(
            base: layers.base,
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
            onViewportChange: { bounds, metersPerPoint in
                store.viewCenter = Coordinate(
                    latitude: (bounds.north + bounds.south) / 2,
                    longitude: (bounds.east + bounds.west) / 2
                )
                store.viewBounds = bounds
                features.viewportChanged(bounds, metersPerPoint: metersPerPoint, folder: mapSettings.folder)
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
        .onAppear {
            features.setMaximumBits(layers.garminDetail.rawValue)
            features.setEnabled(layers.showGarminDetail)
        }
        .onChange(of: layers.showGarminDetail) { _, shown in
            features.setEnabled(shown)
        }
        .onChange(of: layers.garminDetail) { _, detail in
            features.setMaximumBits(detail.rawValue)
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

    /// Everything the map draws, built from the library and the planner.
    private var scene: MapScene {
        var scene = MapScene()

        if layers.showGarminDetail {
            scene.featureLayer = features.layer
        }

        for waypoint in store.library.waypoints {
            let selected = store.selectedItems.contains(.waypoint(waypoint.id))
            scene.pins.append(MapPin(
                id: "waypoint-\(waypoint.id)",
                coordinate: waypoint.coordinate,
                style: .waypoint(selected: selected),
                item: .waypoint(waypoint.id),
                title: waypoint.name,
                showsLabel: true
            ))
        }

        for route in store.library.routes {
            let selected = store.selectedItems.contains(.route(route.id))
            scene.lines.append(MapLine(
                id: "route-\(route.id)",
                coordinates: route.points.map(\.coordinate),
                color: selected ? .red : .blue
            ))
        }

        // The points of the selected route can be dragged, when there are few enough to handle one by one.
        if case .route(let id)? = store.selection, let selectedRoute = store.route(id),
           selectedRoute.points.count <= LibraryStore.draggableRoutePointLimit {
            for (index, point) in selectedRoute.points.enumerated() {
                scene.pins.append(MapPin(
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
                scene.lines.append(MapLine(
                    id: "track-\(track.id)-\(index)",
                    coordinates: segment.map(\.coordinate),
                    color: selected ? .red : .orange
                ))
            }
        }

        for (index, point) in planner.via.enumerated() {
            scene.pins.append(MapPin(
                id: "via-\(index)",
                coordinate: point,
                style: .via(number: index + 1),
                item: nil,
                title: "Point \(index + 1)"
            ))
        }

        if let plan = planner.plan {
            scene.lines.append(MapLine(
                id: "planned-route",
                coordinates: plan.geometry.points.map(\.coordinate),
                color: .teal
            ))
            for (index, section) in plan.remainingSteepSections.enumerated() {
                scene.circles.append(MapCircleShape(
                    id: "steep-circle-\(index)",
                    center: section.center,
                    radiusMeters: section.lengthMeters / 2 + 25
                ))
                scene.pins.append(MapPin(
                    id: "steep-pin-\(index)",
                    coordinate: section.center,
                    style: .steep(percent: Int(section.maxGradePercent.rounded())),
                    item: nil,
                    title: "Climb above \(Int(section.maxGradePercent.rounded()))%"
                ))
            }
        }

        if store.measuring, !store.measurePoints.isEmpty {
            scene.lines.append(MapLine(id: "measure", coordinates: store.measurePoints, color: .measure))
            for (index, point) in store.measurePoints.enumerated() {
                scene.pins.append(MapPin(
                    id: "measure-\(index)",
                    coordinate: point,
                    style: .via(number: index + 1),
                    item: nil,
                    title: "Measure point \(index + 1)"
                ))
            }
        }

        if let cursor = store.profileCoordinate {
            scene.pins.append(MapPin(id: "profile-cursor", coordinate: cursor, style: .cursor, item: nil, title: "Profile position"))
        }

        if layers.showCoverage {
            scene.footprints = coverage.footprints
            for footprint in coverage.footprints {
                scene.pins.append(MapPin(
                    id: "coverage-\(footprint.name)",
                    coordinate: footprint.center,
                    style: .label(footprint.name),
                    item: nil,
                    title: footprint.name
                ))
            }
        }

        return scene
    }

    /// Asks where to save, then writes the visible map as a PNG.
    private func saveImage() {
        guard let bounds = store.viewBounds else { return }
        let url: URL
        if let testPath = BaseCampApp.testMapImagePath {
            url = testPath
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Map.png"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        let scene = self.scene
        let base = layers.base
        let contours = layers.showContours
        Task {
            do {
                let image = try await MapImageExport.render(scene: scene, bounds: bounds, size: CGSize(width: 1600, height: 1200), base: base, contours: contours)
                guard let data = MapImageExport.pngData(image) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            } catch {
                store.errorMessage = "The map image could not be saved. \(error.localizedDescription)"
            }
        }
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
