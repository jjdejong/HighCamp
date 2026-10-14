import AppKit
import BaseCampCore
import BaseCampIMG
import MapKit
import SwiftUI

/// A point of a route that can be dragged on the map: a stop, or the handle in the middle of a leg, which inserts a
/// stop where it is dropped.
struct RoutePointRef: Equatable {
    let route: UUID
    /// The stop, or for a handle the leg.
    let index: Int
    var isInsertion = false
}

/// What one marker on the map stands for.

struct MapPin: Equatable {
    enum Style: Equatable {
        /// A waypoint. `symbol` is its GPX symbol name, which picks the glyph drawn in the marker.
        case waypoint(selected: Bool, symbol: String?)
        case via(number: Int)
        case steep(percent: Int)
        case label(String)
        /// The point under the cursor of an elevation profile.
        case cursor
        /// A stop of the selected route. Drag it to move the stop; click it to select it.
        case routePoint(selected: Bool)
        /// The middle of a leg of the selected route. Drag it to insert a stop there.
        case insertHandle
    }

    let id: String
    let coordinate: Coordinate
    let style: Style
    /// Library item selected when the marker is clicked, if any.
    let item: LibraryItem?
    let title: String
    /// Writes the name beside the marker, as BaseCamp does for waypoints.
    var showsLabel = false
    /// Set for the points of a route that can be moved.
    var routePoint: RoutePointRef?
}

enum MapLineColor: Equatable {
    case blue, orange, red, teal, contour, road, water, other, measure

    var nsColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .orange: .systemOrange
        case .red: .systemRed
        case .teal: .systemTeal
        case .contour: NSColor(calibratedRed: 0.72, green: 0.45, blue: 0.25, alpha: 1)
        case .road: NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.20, alpha: 1)
        case .water: NSColor(calibratedRed: 0.30, green: 0.60, blue: 0.90, alpha: 1)
        case .other: NSColor(calibratedWhite: 0.45, alpha: 1)
        case .measure: .systemPurple
        }
    }
}

/// A colour from a map's style, with components from 0 to 1.
struct MapRGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: ItemColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}

struct MapLine: Equatable {
    let id: String
    let coordinates: [Coordinate]
    let color: MapLineColor
    /// The colour and width from the map's style. When nil, `color` and a default width are used.
    var rgb: MapRGB?
    var width: Double = 3
    /// Drawn dashed, as a route leg waiting to be recalculated.
    var dashed = false
}

struct MapCircleShape: Equatable {
    let id: String
    let center: Coordinate
    let radiusMeters: Double
}

/// The parts of the map that change on their own. Each is redrawn only when its own content changes, so moving
/// the profile cursor does not redraw the library or the Garmin map. Listed from bottom to top.
enum MapLayerKind: Int, CaseIterable {
    /// Coverage outlines of the maps in the map folder, with their names.
    case coverage
    /// Waypoints, routes and tracks, and the draggable points of the selected route.
    case library
    case measure
    /// The stretch picked on the selected item's profile.
    case profileRange
    /// The point under the cursor of an elevation profile.
    case cursor
}

/// What one layer draws.
struct MapLayerContent: Equatable {
    var pins: [MapPin] = []
    var lines: [MapLine] = []
    var circles: [MapCircleShape] = []
    var footprints: [MapFootprint] = []
}

/// Everything drawn on the map above the base map.
struct MapScene: Equatable {
    var layers: [MapLayerKind: MapLayerContent] = [:]

    init(layers: [MapLayerKind: MapLayerContent] = [:]) {
        self.layers = layers
    }

    /// A scene with only these lines, as for a printed report.
    init(lines: [MapLine]) {
        self.init(layers: [.library: MapLayerContent(lines: lines)])
    }

    func content(_ kind: MapLayerKind) -> MapLayerContent {
        layers[kind] ?? MapLayerContent()
    }

    /// Every layer's items together, from the bottom layer to the top one.
    var pins: [MapPin] { MapLayerKind.allCases.flatMap { content($0).pins } }
    var lines: [MapLine] { MapLayerKind.allCases.flatMap { content($0).lines } }
    var circles: [MapCircleShape] { MapLayerKind.allCases.flatMap { content($0).circles } }
    var footprints: [MapFootprint] { MapLayerKind.allCases.flatMap { content($0).footprints } }
}

/// An MKMapView with the library, the planner and the chosen base map. Markers are small
/// circles, so the map keeps its detail.
struct MapKitView: NSViewRepresentable {
    let base: BaseMapLayer
    /// The maps the Garmin base map draws, and how much detail it shows.
    let garmin: GarminMapConfiguration
    let showContours: Bool
    let contourOpacity: Double
    let scene: MapScene
    let fitRequest: Int
    let fitCoordinates: [Coordinate]
    let onMapClick: (Coordinate) -> Void
    let onSelect: (LibraryItem) -> Void
    /// Called when the visible area changes, with its bounds and metres per point.
    let onViewportChange: (GeoBounds, Double) -> Void
    /// Called when a dragged route point is released at a new position.
    let onMovePoint: (RoutePointRef, Coordinate) -> Void
    /// Called for a click with the Option key on empty map.
    var onOptionClick: (Coordinate) -> Void = { _ in }
    /// The selected route, whose stops and line can be dragged.
    var editableRoute: Route?
    /// Called when a stop of the selected route is clicked without dragging.
    var onStopClick: (RoutePointRef) -> Void = { _ in }
    /// The line of the selected track or route. Hovering over it moves the profile cursor (`onProfileHover`).
    var profileLine: LineMeasure?
    /// Called with the distance along `profileLine` under the pointer, while the pointer is over that line.
    var onProfileHover: (Double) -> Void = { _ in }
    /// The items of the context menu for what was right-clicked.
    var contextMenu: (MapContextTarget) -> [MapMenuItem] = { _ in [] }
    /// Bumped to go to the Mac's position.
    let locateRequest: Int
    /// Called with a message when the position cannot be found.
    let onLocationProblem: (String) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let map = ScrollZoomMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        // Open where the map was left, as BaseCamp does. The first time, go to the Mac's position if it can be
        // found; until then, France.
        let saved = SavedMapRegion.load()
        map.setRegion(
            saved ?? MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.4),
                span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
            ),
            animated: false
        )
        context.coordinator.lastLocateRequest = locateRequest
        if saved == nil {
            DispatchQueue.main.async { [weak map, coordinator = context.coordinator] in
                if let map { coordinator.goToMyLocation(on: map, reportProblems: false) }
            }
        }
        // Report the starting view too, so the store knows where the map is before anything moves it.
        DispatchQueue.main.async { [weak map, coordinator = context.coordinator] in
            if let map {
                coordinator.reportViewport(map)
            }
        }
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        map.addGestureRecognizer(click)
        context.coordinator.installMouseMonitor(on: map)
        context.coordinator.installHoverMonitor(on: map)
        return map
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.removeMouseMonitor()
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Mouse-moved events only reach the window once it asks for them; the window exists from the first update.
        if profileLine != nil, let window = map.window, !window.acceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = true
        }
        coordinator.applyBase(base, garmin: garmin, on: map)
        coordinator.applyContours(show: showContours, opacity: contourOpacity, on: map)
        coordinator.applyScene(scene, on: map)
        if locateRequest != coordinator.lastLocateRequest {
            coordinator.lastLocateRequest = locateRequest
            DispatchQueue.main.async {
                coordinator.goToMyLocation(on: map, reportProblems: true)
            }
        }
        if fitRequest != coordinator.lastFitRequest {
            coordinator.lastFitRequest = fitRequest
            // Moving the camera can run map callbacks at once, so it waits until this update has finished.
            let coordinates = fitCoordinates
            DispatchQueue.main.async {
                coordinator.fit(coordinates, on: map)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapKitView
        var lastFitRequest = -1
        var lastLocateRequest = 0
        /// Takes mouse-downs on the selected route before MapKit (see MapRouteEditing.swift).
        var mouseMonitor: Any?
        /// Follows the pointer over the selected line, for the profile cursor (see MapRouteEditing.swift).
        var hoverMonitor: Any?
        private let locationFinder = LocationFinder()

        private var appliedBase: (layer: BaseMapLayer, garmin: GarminMapConfiguration)?
        private var baseOverlay: MKTileOverlay?
        private var contourOverlay: MKTileOverlay?
        private var appliedOpacity: Double?

        private var appliedLayers: [MapLayerKind: MapLayerContent] = [:]
        private var layerOverlays: [MapLayerKind: [MKOverlay]] = [:]
        private var layerPins: [MapLayerKind: [PinAnnotation]] = [:]
        /// The stacking rank of each overlay on the map. Within a level, an overlay always goes above every overlay
        /// of a lower or equal rank and below every higher one, whatever order things change in.
        private var ranks: [ObjectIdentifier: Int] = [:]

        private enum Rank {
            static let base = 0
            static let contours = 1
            static func layer(_ kind: MapLayerKind) -> Int { 10 + kind.rawValue }
        }

        init(parent: MapKitView) {
            self.parent = parent
        }

        // MARK: Base map and contours

        func applyBase(_ base: BaseMapLayer, garmin: GarminMapConfiguration, on map: MKMapView) {
            if let appliedBase, appliedBase.layer == base, base != .garmin || appliedBase.garmin == garmin {
                return
            }
            appliedBase = (base, garmin)
            if let baseOverlay {
                remove([baseOverlay], from: map)
            }
            baseOverlay = base.tileOverlay(garmin: garmin)
            map.mapType = base == .appleHybrid ? .hybrid : .standard
            if let baseOverlay {
                insert([baseOverlay], rank: Rank.base, level: .aboveLabels, on: map)
            }
        }

        func applyContours(show: Bool, opacity: Double, on map: MKMapView) {
            if show, contourOverlay == nil || appliedOpacity != opacity {
                if let contourOverlay {
                    remove([contourOverlay], from: map)
                }
                let overlay = MapTileURLs.contourOverlay()
                contourOverlay = overlay
                appliedOpacity = opacity
                insert([overlay], rank: Rank.contours, level: .aboveLabels, on: map)
            } else if !show, let contourOverlay {
                remove([contourOverlay], from: map)
                self.contourOverlay = nil
                appliedOpacity = nil
            }
        }

        // MARK: Garmin features, library, planner and the other layers

        /// Redraws only the layers whose content changed.
        func applyScene(_ new: MapScene, on map: MKMapView) {
            for kind in MapLayerKind.allCases {
                let content = new.content(kind)
                guard content != appliedLayers[kind] ?? MapLayerContent() else { continue }
                appliedLayers[kind] = content
                apply(content, as: kind, on: map)
            }
        }

        private func apply(_ content: MapLayerContent, as kind: MapLayerKind, on map: MKMapView) {
            map.removeAnnotations(layerPins[kind] ?? [])
            remove(layerOverlays[kind] ?? [], from: map)

            let pins = content.pins.map { PinAnnotation(pin: $0) }
            map.addAnnotations(pins)
            layerPins[kind] = pins

            var overlays: [MKOverlay] = []
            for footprint in content.footprints {
                let corners = footprint.corners.map(\.clLocation)
                overlays.append(FootprintOverlay(coordinates: corners, count: corners.count))
            }
            for line in content.lines {
                let coordinates = line.coordinates.map(\.clLocation)
                let overlay = LineOverlay(coordinates: coordinates, count: coordinates.count)
                overlay.color = line.rgb?.nsColor ?? line.color.nsColor
                overlay.width = CGFloat(line.width)
                overlay.dashed = line.dashed
                overlays.append(overlay)
            }
            for circle in content.circles {
                overlays.append(CircleOverlay(center: circle.center.clLocation, radius: circle.radiusMeters))
            }
            insert(overlays, rank: Rank.layer(kind), level: .aboveLabels, on: map)
            layerOverlays[kind] = overlays
        }

        /// Puts overlays on the map above every overlay of the same or a lower rank in the level, keeping their order.
        private func insert(_ overlays: [MKOverlay], rank: Int, level: MKOverlayLevel, on map: MKMapView) {
            guard !overlays.isEmpty else { return }
            let existing = map.overlays(in: level)
            let index = existing.firstIndex { (ranks[ObjectIdentifier($0)] ?? 0) > rank } ?? existing.count
            for (offset, overlay) in overlays.enumerated() {
                ranks[ObjectIdentifier(overlay)] = rank
                map.insertOverlay(overlay, at: index + offset, level: level)
            }
        }

        private func remove(_ overlays: [MKOverlay], from map: MKMapView) {
            guard !overlays.isEmpty else { return }
            map.removeOverlays(overlays)
            for overlay in overlays {
                ranks[ObjectIdentifier(overlay)] = nil
            }
        }

        /// Centres the map on the Mac's position, about 30 km across. Problems are reported only when the user asked.
        func goToMyLocation(on map: MKMapView, reportProblems: Bool) {
            locationFinder.locate { [weak self, weak map] result in
                switch result {
                case .success(let coordinate):
                    map?.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000), animated: true)
                case .failure(let problem):
                    if reportProblems { self?.parent.onLocationProblem(problem.message) }
                }
            }
        }

        func fit(_ coordinates: [Coordinate], on map: MKMapView) {
            guard let area = MapFraming.area(enclosing: coordinates) else { return }
            let corner = MKMapPoint(area.southWest.clLocation)
            let opposite = MKMapPoint(area.northEast.clLocation)
            let rect = MKMapRect(
                x: min(corner.x, opposite.x),
                y: min(corner.y, opposite.y),
                width: abs(opposite.x - corner.x),
                height: abs(opposite.y - corner.y)
            )
            let padding = NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
            map.setVisibleMapRect(rect.insetBy(dx: -rect.width * 0.05, dy: -rect.height * 0.05), edgePadding: padding, animated: true)
        }

        // MARK: Clicks

        /// A click on empty map adds a planner point. Clicks on markers are left to the markers.
        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            var hit: NSView? = map.hitTest(map.superview?.convert(point, from: map) ?? point)
            while let view = hit {
                if view is MKAnnotationView {
                    return
                }
                hit = view.superview
            }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            let clicked = Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if NSEvent.modifierFlags.contains(.option) {
                parent.onOptionClick(clicked)
            } else {
                parent.onMapClick(clicked)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = tiles === contourOverlay ? parent.contourOpacity : 1
                return renderer
            }
            if let line = overlay as? LineOverlay {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = line.color
                renderer.lineWidth = line.width
                if line.dashed {
                    renderer.lineDashPattern = [NSNumber(value: Double(line.width) * 2), NSNumber(value: Double(line.width) * 1.6)]
                }
                return renderer
            }
            if overlay is FootprintOverlay, let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = .systemPurple
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                // Outline only: stacked fills would wash out the base map.
                renderer.fillColor = nil
                return renderer
            }
            if let circle = overlay as? CircleOverlay {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = .systemRed
                renderer.lineWidth = 2
                renderer.fillColor = NSColor.systemRed.withAlphaComponent(0.2)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? PinAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin")
                ?? MKAnnotationView(annotation: pin, reuseIdentifier: "pin")
            view.annotation = pin
            let dot = MarkerImage.image(for: pin.style)
            let image = MarkerImage.image(for: pin.style, label: pin.showsLabel ? pin.title : nil)
            view.image = image
            // A label makes the image wider; shift it so the marker itself stays on the coordinate.
            view.centerOffset = CGPoint(x: (image.size.width - dot.size.width) / 2, y: 0)
            view.canShowCallout = false
            // Stops and handles are dragged by the mouse monitor, not by MapKit, which would pan the map instead.
            view.isDraggable = false
            return view
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            reportViewport(mapView)
        }

        /// Sends the visible area to the owner, after the current update has finished.
        func reportViewport(_ mapView: MKMapView) {
            let region = mapView.region
            if mapView.bounds.width > 0 {
                SavedMapRegion.save(region)
            }
            let half = (region.span.latitudeDelta / 2, region.span.longitudeDelta / 2)
            let bounds = GeoBounds(
                north: MapFraming.clampLatitude(region.center.latitude + half.0),
                east: MapFraming.clampLongitude(region.center.longitude + half.1),
                south: MapFraming.clampLatitude(region.center.latitude - half.0),
                west: MapFraming.clampLongitude(region.center.longitude - half.1)
            )
            let width = Double(mapView.bounds.width)
            guard width > 0 else {
                // Not laid out yet, so try again shortly. Without this the starting view would never be reported.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak mapView] in
                    if let self, let mapView {
                        self.reportViewport(mapView)
                    }
                }
                return
            }
            let metersPerPoint = mapView.visibleMapRect.size.width
                * MKMetersPerMapPointAtLatitude(region.center.latitude) / width
            // Sent after the current view update, so the app's state is not changed during SwiftUI's update.
            DispatchQueue.main.async { [onViewportChange = parent.onViewportChange] in
                onViewportChange(bounds, metersPerPoint)
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer { mapView.deselectAnnotation(view.annotation, animated: false) }
            guard let pin = view.annotation as? PinAnnotation, let item = pin.item else { return }
            parent.onSelect(item)
        }
    }
}

/// A map that zooms with the scroll wheel or two-finger scrolling, around the pointer, and moves by dragging, as
/// BaseCamp and QMapShack do. Pinching still zooms.
final class ScrollZoomMapView: MKMapView {
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // Trackpads report points, mouse wheels report lines; one wheel notch zooms by about a quarter.
        let perUnit = event.hasPreciseScrollingDeltas ? 0.01 : 0.25
        let factor = exp(-Double(delta) * perUnit)
        let point = convert(event.locationInWindow, from: nil)
        let anchor = MKMapPoint(convert(point, toCoordinateFrom: self))
        let rect = visibleMapRect
        let zoomed = MKMapRect(
            x: anchor.x - (anchor.x - rect.minX) * factor,
            y: anchor.y - (anchor.y - rect.minY) * factor,
            width: rect.width * factor,
            height: rect.height * factor
        )
        // Not closer than about a building, and not farther out than the whole world.
        guard zoomed.width > 50, zoomed.width < MKMapRect.world.width * 1.5 else { return }
        setVisibleMapRect(zoomed, animated: false)
    }
}

/// Map annotation for one marker.
final class PinAnnotation: NSObject, MKAnnotation {
    let pinID: String
    let style: MapPin.Style
    let item: LibraryItem?
    let title: String?
    /// Changes while the marker is dragged; MapKit follows it.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let showsLabel: Bool
    let routePoint: RoutePointRef?

    init(pin: MapPin) {
        pinID = pin.id
        style = pin.style
        item = pin.item
        title = pin.title
        coordinate = pin.coordinate.clLocation
        showsLabel = pin.showsLabel
        routePoint = pin.routePoint
    }
}

final class LineOverlay: MKPolyline {
    var color: NSColor = .systemBlue
    var width: CGFloat = 3
    var dashed = false
}

final class CircleOverlay: MKCircle {}

/// The coverage outline of one map in the map folder.
final class FootprintOverlay: MKPolygon {}

/// Small marker images, drawn once per style.
enum MarkerImage {
    private static var cache: [String: NSImage] = [:]

    /// A marker with its label to the right. The marker is the one `image(for:)` gives for the style.
    static func image(for style: MapPin.Style, label: String?) -> NSImage {
        let marker = image(for: style)
        guard let label, !label.isEmpty else { return marker }
        let key = "\(style)|\(label)"
        if let cached = cache[key] {
            return cached
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let size = NSSize(width: marker.size.width + 4 + textSize.width + 8, height: max(marker.size.height, textSize.height + 4))
        let image = NSImage(size: size, flipped: false) { rect in
            marker.draw(in: NSRect(x: 0, y: (rect.height - marker.size.height) / 2, width: marker.size.width, height: marker.size.height))
            let pill = NSRect(x: marker.size.width + 2, y: (rect.height - textSize.height - 4) / 2, width: textSize.width + 8, height: textSize.height + 4)
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            (label as NSString).draw(at: NSPoint(x: pill.minX + 4, y: pill.minY + 2), withAttributes: attributes)
            return true
        }
        cache[key] = image
        return image
    }

    static func image(for style: MapPin.Style) -> NSImage {
        let key = "\(style)"
        if let cached = cache[key] {
            return cached
        }
        let image: NSImage
        switch style {
        case .waypoint(let selected, let symbol):
            let fill: NSColor = selected ? .systemRed : .systemBlue
            if let systemName = WaypointSymbol.systemName(for: symbol) {
                image = symbolDot(diameter: selected ? 20 : 18, fill: fill, systemName: systemName)
            } else {
                image = dot(diameter: selected ? 14 : 11, fill: fill, label: nil)
            }
        case .via(let number):
            image = dot(diameter: 18, fill: .systemGreen, label: "\(number)")
        case .steep:
            image = dot(diameter: 14, fill: .systemOrange, label: "!")
        case .label(let text):
            image = pill(text)
        case .cursor:
            image = dot(diameter: 12, fill: .white, label: nil, ring: .systemRed)
        case .routePoint(let selected):
            image = selected
                ? dot(diameter: 14, fill: .systemBlue, label: nil, ring: .white)
                : dot(diameter: 10, fill: .white, label: nil, ring: .systemBlue)
        case .insertHandle:
            image = dot(diameter: 9, fill: NSColor.white.withAlphaComponent(0.75), label: nil, ring: NSColor.systemBlue.withAlphaComponent(0.6))
        }
        cache[key] = image
        return image
    }

    /// A small rounded label, used for map names on the coverage outlines.
    private static func pill(_ text: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: textSize.width + 12, height: textSize.height + 4)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.systemPurple.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            (text as NSString).draw(at: NSPoint(x: 6, y: 2), withAttributes: attributes)
            return true
        }
    }

    /// A filled circle with a white SF Symbol in it, for a waypoint that has a symbol.
    private static func symbolDot(diameter: CGFloat, fill: NSColor, systemName: String) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            fill.setFill()
            circle.fill()
            NSColor.white.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            let configuration = NSImage.SymbolConfiguration(pointSize: diameter * 0.5, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }

    private static func dot(diameter: CGFloat, fill: NSColor, label: String?, ring: NSColor = .white) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            fill.setFill()
            circle.fill()
            ring.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            if let label {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: diameter * 0.6, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]
                let text = NSAttributedString(string: label, attributes: attributes)
                let textSize = text.size()
                text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            }
            return true
        }
    }
}
