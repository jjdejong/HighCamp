import AppKit
import BaseCampCore
import MapKit

/// What a right-click on the map was on.
enum MapContextTarget {
    /// A stop of the selected route.
    case stop(RoutePointRef)
    /// The line of the selected route, in the given leg.
    case leg(route: UUID, leg: Int, at: Coordinate)
    /// Anything else on the map.
    case map(Coordinate)
}

/// One item of the map's context menu.
struct MapMenuItem {
    var title: String
    var isEnabled = true
    var isSeparator = false
    var action: () -> Void = {}

    static let separator = MapMenuItem(title: "", isSeparator: true)
}

/// Dragging the stops and the line of the selected route, and the map's context menu. Mouse-downs are taken before
/// MapKit sees them, so that dragging a stop or the line moves it instead of panning the map.
extension MapKitView.Coordinator {
    /// What a mouse-down hit on the selected route.
    enum RouteHit {
        case stop(Int)
        /// The handle in the middle of a leg, or the leg's line: dragging it inserts a stop into that leg.
        case leg(Int)
    }

    /// Installs the mouse monitor. It only acts on events over the map itself, not on controls drawn over it.
    func installMouseMonitor(on map: MKMapView) {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak map] event in
            guard let self, let map, event.window === map.window, self.isOverMap(event, map) else { return event }
            let point = map.convert(event.locationInWindow, from: nil)
            let isMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            if isMenu {
                return self.showMenu(for: event, at: point, on: map) ? nil : event
            }
            // Option-click is left to the click handler, which extends the route.
            guard !event.modifierFlags.contains(.option), let route = self.parent.editableRoute,
                  let hit = self.hit(at: point, route: route, on: map) else { return event }
            self.track(hit, route: route, from: point, on: map)
            return nil
        }
    }

    func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        if let hoverMonitor {
            NSEvent.removeMonitor(hoverMonitor)
        }
        hoverMonitor = nil
    }

    /// Follows the pointer over the selected track or route, and moves the profile cursor to the place on the line
    /// under it, as hovering over the profile moves the marker on the map. Off the line, the cursor stays.
    func installHoverMonitor(on map: MKMapView) {
        map.window?.acceptsMouseMovedEvents = true
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self, weak map] event in
            guard let self, let map, event.window === map.window, let line = self.parent.profileLine else { return event }
            map.window?.acceptsMouseMovedEvents = true
            let point = map.convert(event.locationInWindow, from: nil)
            guard map.bounds.contains(point), self.isOverMap(event, map),
                  let distance = Self.distance(along: line, at: point, on: map, tolerance: 8) else { return event }
            self.parent.onProfileHover(distance)
            return event
        }
    }

    /// The distance along `line` of the place nearest to `point`, if the line passes within `tolerance` points.
    /// Works in map points, which are cheap to compute, so long tracks follow the pointer smoothly.
    static func distance(along line: LineMeasure, at point: CGPoint, on map: MKMapView, tolerance: CGFloat) -> Double? {
        let target = MKMapPoint(map.convert(point, toCoordinateFrom: map))
        let perScreenPoint = map.visibleMapRect.width / max(Double(map.bounds.width), 1)
        let limit = Double(tolerance) * perScreenPoint
        var best: (distance: Double, gap: Double)?
        for (segmentIndex, segment) in line.segments.enumerated() {
            var previous: MKMapPoint?
            for (index, coordinate) in segment.enumerated() {
                let current = MKMapPoint(coordinate.clLocation)
                defer { previous = current }
                guard let start = previous else { continue }
                let dx = current.x - start.x, dy = current.y - start.y
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared > 0 ? max(0, min(1, ((target.x - start.x) * dx + (target.y - start.y) * dy) / lengthSquared)) : 0
                let gap = hypot(target.x - (start.x + t * dx), target.y - (start.y + t * dy))
                if gap <= limit, gap < (best?.gap ?? .infinity) {
                    best = (line.distance(segment: segmentIndex, index: index - 1, fraction: t), gap)
                }
            }
        }
        return best?.distance
    }

    func isOverMap(_ event: NSEvent, _ map: MKMapView) -> Bool {
        guard let content = map.window?.contentView,
              var view = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
        while true {
            if view === map { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    private func screenPoint(_ coordinate: Coordinate, on map: MKMapView) -> CGPoint {
        map.convert(coordinate.clLocation, toPointTo: map)
    }

    private func coordinate(at point: CGPoint, on map: MKMapView) -> Coordinate {
        let location = map.convert(point, toCoordinateFrom: map)
        return Coordinate(latitude: location.latitude, longitude: location.longitude)
    }

    /// The stop, handle or line under the pointer, nearest first: stops win over handles, handles over the line.
    func hit(at point: CGPoint, route: Route, on map: MKMapView) -> RouteHit? {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let stops = route.stops.indices.map { (index: $0, d: distance(screenPoint(route.stops[$0].coordinate, on: map), point)) }
        if let nearest = stops.min(by: { $0.d < $1.d }), nearest.d <= 9 {
            return .stop(nearest.index)
        }
        for leg in route.legs.indices {
            if let middle = route.legMidpoint(leg), distance(screenPoint(middle, on: map), point) <= 8 {
                return .leg(leg)
            }
        }
        var best: (leg: Int, d: CGFloat)?
        for leg in route.legs.indices {
            let line = route.legLine(leg).map { screenPoint($0, on: map) }
            for (a, b) in zip(line, line.dropFirst()) {
                let d = Self.distance(from: point, toSegment: a, b)
                if d <= 6, d < (best?.d ?? .infinity) {
                    best = (leg, d)
                }
            }
        }
        return best.map { .leg($0.leg) }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Follows the mouse until it is released. A stop that was only clicked is selected; a drag moves the stop, or
    /// inserts a new one into the leg. While dragging, dashed lines join the point to its neighbours.
    private func track(_ hit: RouteHit, route: Route, from start: CGPoint, on map: MKMapView) {
        let neighbours: [Coordinate]
        switch hit {
        case .stop(let index):
            neighbours = [index - 1, index + 1].filter { route.stops.indices.contains($0) }.map { route.stops[$0].coordinate }
        case .leg(let leg):
            neighbours = [route.stops[leg].coordinate, route.stops[leg + 1].coordinate]
        }
        let marker = PinAnnotation(pin: MapPin(
            id: "drag", coordinate: coordinate(at: start, on: map), style: .routePoint(selected: true), item: nil, title: ""
        ))
        var rubberBands: [LineOverlay] = []
        var moved = false
        var current = start

        while let event = map.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            current = map.convert(event.locationInWindow, from: nil)
            if !moved, hypot(current.x - start.x, current.y - start.y) >= 3 {
                moved = true
                map.addAnnotation(marker)
            }
            if moved {
                let here = coordinate(at: current, on: map)
                marker.coordinate = here.clLocation
                map.removeOverlays(rubberBands)
                rubberBands = neighbours.map { neighbour in
                    var line = [neighbour.clLocation, here.clLocation]
                    let overlay = LineOverlay(coordinates: &line, count: 2)
                    overlay.color = NSColor.systemBlue.withAlphaComponent(0.8)
                    overlay.width = 2
                    overlay.dashed = true
                    return overlay
                }
                map.addOverlays(rubberBands, level: .aboveLabels)
            }
            if event.type == .leftMouseUp { break }
        }
        map.removeOverlays(rubberBands)
        map.removeAnnotation(marker)

        let end = coordinate(at: current, on: map)
        switch hit {
        case .stop(let index):
            let reference = RoutePointRef(route: route.id, index: index)
            if moved {
                parent.onMovePoint(reference, end)
            } else {
                parent.onStopClick(reference)
            }
        case .leg(let leg):
            if moved {
                parent.onMovePoint(RoutePointRef(route: route.id, index: leg, isInsertion: true), end)
            }
        }
    }

    /// Shows the context menu for what is under the pointer. Returns false when there is nothing to offer.
    private func showMenu(for event: NSEvent, at point: CGPoint, on map: MKMapView) -> Bool {
        let here = coordinate(at: point, on: map)
        var target = MapContextTarget.map(here)
        if let route = parent.editableRoute, let hit = hit(at: point, route: route, on: map) {
            switch hit {
            case .stop(let index): target = .stop(RoutePointRef(route: route.id, index: index))
            case .leg(let leg): target = .leg(route: route.id, leg: leg, at: here)
            }
        }
        let items = parent.contextMenu(target)
        guard !items.isEmpty else { return false }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(MenuAction.run), keyEquivalent: "")
            let action = MenuAction(item.action)
            menuItem.target = action
            menuItem.representedObject = action
            menuItem.isEnabled = item.isEnabled
            menu.addItem(menuItem)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: map)
        return true
    }
}

/// Runs a closure from a menu item. The item keeps it alive through `representedObject`.
final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

extension Array {
    /// The element at `index`, or nil when the index is out of range.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
