import AppKit
import BaseCampCore
import BaseCampIMG
import MapKit
import SwiftUI

/// What one marker on the map stands for.
/// A point of a route that can be dragged on the map.
struct RoutePointRef: Equatable {
    let route: UUID
    let index: Int
}

struct MapPin: Equatable {
    enum Style: Equatable {
        case waypoint(selected: Bool)
        case via(number: Int)
        case steep(percent: Int)
        case label(String)
        /// The point under the cursor of an elevation profile.
        case cursor
        /// A point of a selected route. Drag it to move the point.
        case routePoint
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
struct MapRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

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
}

struct MapCircleShape: Equatable {
    let id: String
    let center: Coordinate
    let radiusMeters: Double
}

/// Everything drawn on the map. The map only redraws when this changes.
struct MapScene: Equatable {
    var pins: [MapPin] = []
    var lines: [MapLine] = []
    var circles: [MapCircleShape] = []
    var footprints: [MapFootprint] = []
    /// The Garmin map features of the view. Compared by identity.
    var featureLayer: FeatureLayer?
}

/// An MKMapView with the library, the planner and the chosen base map. Markers are small
/// circles, so the map keeps its detail.
struct MapKitView: NSViewRepresentable {
    let base: BaseMapLayer
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

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.4),
                span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
            ),
            animated: false
        )
        // Report the starting view too, so the store knows where the map is before anything moves it.
        DispatchQueue.main.async { [weak map, coordinator = context.coordinator] in
            if let map {
                coordinator.reportViewport(map)
            }
        }
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        map.addGestureRecognizer(click)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyBase(base, on: map)
        coordinator.applyContours(show: showContours, opacity: contourOpacity, on: map)
        coordinator.applyScene(scene, on: map)
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

        private var appliedBase: BaseMapLayer?
        private var baseOverlay: MKTileOverlay?
        private var contourOverlay: MKTileOverlay?
        private var appliedOpacity: Double?
        private var scene = MapScene()

        init(parent: MapKitView) {
            self.parent = parent
        }

        // MARK: Base map and contours

        func applyBase(_ base: BaseMapLayer, on map: MKMapView) {
            guard base != appliedBase else { return }
            appliedBase = base
            if let baseOverlay {
                map.removeOverlay(baseOverlay)
            }
            baseOverlay = base.tileOverlay()
            map.mapType = base == .appleHybrid ? .hybrid : .standard
            if let baseOverlay {
                map.insertOverlay(baseOverlay, at: 0, level: .aboveLabels)
            }
        }

        func applyContours(show: Bool, opacity: Double, on map: MKMapView) {
            if show, contourOverlay == nil || appliedOpacity != opacity {
                if let contourOverlay {
                    map.removeOverlay(contourOverlay)
                }
                contourOverlay = MapTileURLs.contourOverlay()
                appliedOpacity = opacity
                map.addOverlay(contourOverlay!, level: .aboveLabels)
            } else if !show, let contourOverlay {
                map.removeOverlay(contourOverlay)
                self.contourOverlay = nil
                appliedOpacity = nil
            }
        }

        // MARK: Library, planner and route overlays

        func applyScene(_ new: MapScene, on map: MKMapView) {
            guard new != scene else { return }
            scene = new

            map.removeAnnotations(map.annotations.filter { $0 is PinAnnotation })
            map.removeOverlays(map.overlays.filter { $0 is LineOverlay || $0 is AreaOverlay || $0 is LineGroupOverlay || $0 is AreaGroupOverlay || $0 is CircleOverlay || $0 is FootprintOverlay })

            map.addAnnotations(new.pins.map { PinAnnotation(pin: $0) })
            // Areas go above the base map's roads but below its labels; lines go above the labels.
            // The Garmin features are one overlay per style, so the map stays quick with many paths.
            for group in new.featureLayer?.areas ?? [] {
                let polygons = group.rings.compactMap { ring -> MKPolygon? in
                    let coordinates = ring.map(\.clLocation)
                    return coordinates.count >= 3 ? MKPolygon(coordinates: coordinates, count: coordinates.count) : nil
                }
                guard !polygons.isEmpty else { continue }
                let overlay = AreaGroupOverlay(polygons)
                overlay.fill = group.fill.nsColor.withAlphaComponent(0.7)
                map.addOverlay(overlay, level: .aboveRoads)
            }
            for group in new.featureLayer?.lines ?? [] {
                let polylines = group.paths.map { path -> MKPolyline in
                    let coordinates = path.map(\.clLocation)
                    return MKPolyline(coordinates: coordinates, count: coordinates.count)
                }
                let overlay = LineGroupOverlay(polylines)
                overlay.color = group.rgb.nsColor
                overlay.width = CGFloat(group.width)
                map.addOverlay(overlay, level: .aboveLabels)
            }
            for line in new.lines {
                let coordinates = line.coordinates.map(\.clLocation)
                let overlay = LineOverlay(coordinates: coordinates, count: coordinates.count)
                overlay.color = line.rgb?.nsColor ?? line.color.nsColor
                overlay.width = CGFloat(line.width)
                map.addOverlay(overlay, level: .aboveLabels)
            }
            for circle in new.circles {
                let overlay = CircleOverlay(center: circle.center.clLocation, radius: circle.radiusMeters)
                map.addOverlay(overlay, level: .aboveLabels)
            }
            for footprint in new.footprints {
                let corners = footprint.corners.map(\.clLocation)
                let overlay = FootprintOverlay(coordinates: corners, count: corners.count)
                map.addOverlay(overlay, level: .aboveLabels)
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
            parent.onMapClick(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = tiles === contourOverlay ? parent.contourOpacity : 1
                return renderer
            }
            if let group = overlay as? AreaGroupOverlay {
                let renderer = MKMultiPolygonRenderer(multiPolygon: group)
                renderer.fillColor = group.fill
                renderer.strokeColor = nil
                return renderer
            }
            if let group = overlay as? LineGroupOverlay {
                let renderer = MKMultiPolylineRenderer(multiPolyline: group)
                renderer.strokeColor = group.color
                renderer.lineWidth = group.width
                return renderer
            }
            if let area = overlay as? AreaOverlay {
                let renderer = MKPolygonRenderer(polygon: area)
                renderer.fillColor = area.fill
                renderer.strokeColor = nil
                return renderer
            }
            if let line = overlay as? LineOverlay {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = line.color
                renderer.lineWidth = line.width
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
            view.isDraggable = pin.routePoint != nil
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard newState == .ending, let pin = view.annotation as? PinAnnotation, let reference = pin.routePoint else { return }
            view.dragState = .none
            parent.onMovePoint(reference, Coordinate(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude))
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            reportViewport(mapView)
        }

        /// Sends the visible area to the owner, after the current update has finished.
        func reportViewport(_ mapView: MKMapView) {
            let region = mapView.region
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

/// Map annotation for one marker.
final class PinAnnotation: NSObject, MKAnnotation {
    let pinID: String
    let style: MapPin.Style
    let item: LibraryItem?
    let title: String?
    /// Changes when the marker is dragged.
    var coordinate: CLLocationCoordinate2D
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
}

/// A filled area of the map style.
final class AreaOverlay: MKPolygon {
    var fill: NSColor = .clear
}

/// Every path of one style of the Garmin map, as one overlay.
final class LineGroupOverlay: MKMultiPolyline {
    var color: NSColor = .systemGray
    var width: CGFloat = 3
}

/// Every ring of one fill of the Garmin map, as one overlay.
final class AreaGroupOverlay: MKMultiPolygon {
    var fill: NSColor = .clear
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
        case .waypoint(let selected):
            image = dot(diameter: selected ? 14 : 11, fill: selected ? .systemRed : .systemBlue, label: nil)
        case .via(let number):
            image = dot(diameter: 18, fill: .systemGreen, label: "\(number)")
        case .steep:
            image = dot(diameter: 14, fill: .systemOrange, label: "!")
        case .label(let text):
            image = pill(text)
        case .cursor:
            image = dot(diameter: 12, fill: .white, label: nil, ring: .systemRed)
        case .routePoint:
            image = dot(diameter: 10, fill: .white, label: nil, ring: .systemBlue)
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
