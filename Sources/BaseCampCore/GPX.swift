import Foundation

public enum GPXError: Error, Equatable {
    case malformedXML(String)
}

extension GPXError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedXML(let detail):
            "The file is not valid XML: \(detail)"
        }
    }
}

/// Reads and writes GPX 1.1 files: waypoints, routes and tracks.
/// Elements the planner does not use are skipped on read. A point whose lat or lon is missing or
/// out of range is skipped as well, and counted in `skipped`.
public enum GPX {
    public static func read(_ data: Data) throws -> (library: Library, skipped: Int) {
        try GPXReader().read(data)
    }

    public static func write(_ library: Library) -> Data {
        GPXWriter.write(library)
    }
}

/// The Garmin extension namespaces. The version at the end of the URI may change, so only the start is matched.
private enum GarminNamespace {
    static let gpxExtensions = "http://www.garmin.com/xmlschemas/GpxExtensions/"
    static let tripExtensions = "http://www.garmin.com/xmlschemas/TripExtensions/"
    static let trackPointExtensions = "http://www.garmin.com/xmlschemas/TrackPointExtension/"
    static let powerExtensions = "http://www.garmin.com/xmlschemas/PowerExtension/"
}

/// A route point as read: its position, whether it is a shaping point, and the shape points after it.
private struct ReadRoutePoint {
    var point: RoutePoint
    var isShaping = false
    var shape: [RoutePoint] = []
}

private final class GPXReader: NSObject, XMLParserDelegate {
    private var library = Library()
    private var skipped = 0
    private var stack: [String] = []
    private var text = ""

    private var waypoint: Waypoint?
    private var route: Route?
    private var routePoint: ReadRoutePoint?
    /// The points of the route being read. The route is made from them at its end.
    private var routePoints: [ReadRoutePoint] = []
    private var track: Track?
    private var segment: [TrackPoint]?
    private var trackPoint: TrackPoint?

    func read(_ data: Data) throws -> (library: Library, skipped: Int) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Namespaces are processed, so the Garmin extensions are recognised by their namespace whatever prefix a
        // file gives them. Element names are then the local names.
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw GPXError.malformedXML(parser.parserError?.localizedDescription ?? "unknown error")
        }
        return (library, skipped)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        stack.append(elementName)
        text = ""
        if routePoint != nil {
            // Inside a route point: a shaping marker, or a shape point, from the Garmin extensions.
            if elementName == "ShapingPoint", namespaceURI?.hasPrefix(GarminNamespace.tripExtensions) == true {
                routePoint?.isShaping = true
            } else if elementName == "rpt", namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true,
                      let coordinate = coordinate(attributes) {
                routePoint?.shape.append(RoutePoint(coordinate: coordinate))
            }
        }
        switch elementName {
        case "wpt":
            guard let coordinate = coordinate(attributes) else { return }
            waypoint = Waypoint(name: "", coordinate: coordinate)
        case "rte":
            route = Route(name: "")
        case "rtept":
            guard let coordinate = coordinate(attributes) else { return }
            routePoint = ReadRoutePoint(point: RoutePoint(coordinate: coordinate))
        case "trk":
            track = Track(name: "")
        case "trkseg":
            segment = []
        case "trkpt":
            guard let coordinate = coordinate(attributes) else { return }
            trackPoint = TrackPoint(coordinate: coordinate)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        stack.removeLast()
        text = ""

        switch (elementName, parent) {
        case ("name", "wpt"):
            waypoint?.name = value
        case ("ele", "wpt"):
            waypoint?.elevation = Double(value)
        case ("time", "wpt"):
            waypoint?.time = GPXDate.parse(value)
        case ("cmt", "wpt"):
            waypoint?.comment = value.nonEmpty
        case ("desc", "wpt"):
            if waypoint?.comment == nil {
                waypoint?.comment = value.nonEmpty
            }
        case ("sym", "wpt"):
            waypoint?.symbol = value.nonEmpty
        case ("Proximity", "WaypointExtension") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            waypoint?.proximity = Double(value)
        case ("StreetAddress", "Address") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            setAddress { $0.street = value.nonEmpty }
        case ("City", "Address") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            setAddress { $0.city = value.nonEmpty }
        case ("State", "Address") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            setAddress { $0.state = value.nonEmpty }
        case ("PostalCode", "Address") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            setAddress { $0.postalCode = value.nonEmpty }
        case ("Country", "Address") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            setAddress { $0.country = value.nonEmpty }
        case ("PhoneNumber", "WaypointExtension") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            setAddress { $0.phone = value.nonEmpty }
        case ("wpt", _):
            if let waypoint { library.waypoints.append(waypoint) }
            waypoint = nil

        case ("name", "rte"):
            route?.name = value
        case ("DisplayColor", "RouteExtension") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            route?.color = GarminColour.color(named: value)
        case ("name", "rtept"):
            routePoint?.point.name = value.nonEmpty
        case ("ele", "rtept"):
            routePoint?.point.elevation = Double(value)
        case ("rtept", _):
            if let routePoint { routePoints.append(routePoint) }
            routePoint = nil
        case ("rte", _):
            if let route {
                var built = Self.route(id: route.id, name: route.name, points: routePoints)
                built.color = route.color
                library.routes.append(built)
            }
            route = nil
            routePoints = []

        case ("name", "trk"):
            track?.name = value
        case ("DisplayColor", "TrackExtension") where namespaceURI?.hasPrefix(GarminNamespace.gpxExtensions) == true:
            track?.color = GarminColour.color(named: value)
        case ("ele", "trkpt"):
            trackPoint?.elevation = Double(value)
        case ("time", "trkpt"):
            trackPoint?.time = GPXDate.parse(value)
        case ("hr", "TrackPointExtension") where namespaceURI?.hasPrefix(GarminNamespace.trackPointExtensions) == true:
            trackPoint?.heartRate = Double(value)
        case ("cad", "TrackPointExtension") where namespaceURI?.hasPrefix(GarminNamespace.trackPointExtensions) == true:
            trackPoint?.cadence = Double(value)
        case ("atemp", "TrackPointExtension") where namespaceURI?.hasPrefix(GarminNamespace.trackPointExtensions) == true:
            trackPoint?.temperature = Double(value)
        case ("PowerInWatts", _) where namespaceURI?.hasPrefix(GarminNamespace.powerExtensions) == true:
            trackPoint?.power = Double(value)
        case ("power", "extensions"):
            trackPoint?.power = Double(value)
        case ("trkpt", _):
            if let trackPoint { segment?.append(trackPoint) }
            trackPoint = nil
        case ("trkseg", _):
            if let segment { track?.segments.append(segment) }
            segment = nil
        case ("trk", _):
            if let track { library.tracks.append(track) }
            track = nil

        default:
            break
        }
    }

    /// Changes the waypoint's address, making one when it has none yet.
    private func setAddress(_ change: (inout WaypointAddress) -> Void) {
        var address = waypoint?.address ?? WaypointAddress()
        change(&address)
        waypoint?.address = address
    }

    /// The route from its points. A route with no shape points is read as a plain list of points, as before, keeping
    /// the shaping markers when every point became a stop. Otherwise each point is a stop, and the shape points after a
    /// stop are the imported leg to the next stop. The first and last stops are always via points, as the writer makes
    /// them.
    private static func route(id: UUID, name: String, points: [ReadRoutePoint]) -> Route {
        guard points.contains(where: { !$0.shape.isEmpty }) else {
            var route = Route(id: id, name: name, points: points.map(\.point))
            if route.stops.count == points.count {
                for (index, read) in points.enumerated() where read.isShaping {
                    route.setShaping(true, at: index)
                }
            }
            return route
        }
        let last = points.count - 1
        let stops = points.enumerated().map { index, read in
            RouteStop(
                name: read.point.name,
                coordinate: read.point.coordinate,
                elevation: read.point.elevation,
                isShaping: read.isShaping && index != 0 && index != last
            )
        }
        // The shape points of the last point have no leg after them, so they are not used. BaseCamp repeats a stop as
        // the first shape point of its leg, and sometimes the next stop as the last; those repeats are dropped.
        let legs = points.indices.dropLast().map { index in
            let start = points[index].point.coordinate, end = points[index + 1].point.coordinate
            let shape = points[index].shape.filter { $0.coordinate != start && $0.coordinate != end }
            return RouteLeg(shape: shape, method: .imported)
        }
        return Route(id: id, name: name, stops: stops, legs: legs)
    }

    /// The point's coordinate. A point whose lat or lon is missing or out of range gives nil and is counted as skipped.
    private func coordinate(_ attributes: [String: String]) -> Coordinate? {
        guard let latitudeText = attributes["lat"], let longitudeText = attributes["lon"],
              let latitude = Double(latitudeText), let longitude = Double(longitudeText) else {
            skipped += 1
            return nil
        }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else {
            skipped += 1
            return nil
        }
        return coordinate
    }
}

private enum GPXWriter {
    static func write(_ library: Library) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"BaseCamp Clone\" xmlns=\"http://www.topografix.com/GPX/1/1\""
        xml += " xmlns:gpxx=\"http://www.garmin.com/xmlschemas/GpxExtensions/v3\""
        xml += " xmlns:trp=\"http://www.garmin.com/xmlschemas/TripExtensions/v1\""
        xml += " xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\""
        xml += " xmlns:power=\"http://www.garmin.com/xmlschemas/PowerExtension/v1\">\n"

        for waypoint in library.waypoints {
            xml += "  <wpt\(attributes(waypoint.coordinate))>\n"
            xml += element("ele", waypoint.elevation.map(number), indent: "    ")
            xml += element("time", waypoint.time.map(GPXDate.string), indent: "    ")
            xml += element("name", waypoint.name, indent: "    ")
            xml += element("cmt", waypoint.comment, indent: "    ")
            xml += element("sym", waypoint.symbol, indent: "    ")
            xml += waypointExtensions(waypoint, indent: "    ")
            xml += "  </wpt>\n"
        }

        for route in library.routes {
            xml += "  <rte>\n"
            xml += element("name", route.name, indent: "    ")
            xml += colourExtension("RouteExtension", route.color, indent: "    ")
            let last = route.stops.count - 1
            for (index, stop) in route.stops.enumerated() {
                xml += "    <rtept\(attributes(stop.coordinate))>\n"
                xml += element("ele", stop.elevation.map(number), indent: "      ")
                xml += element("name", stop.name, indent: "      ")
                xml += "      <extensions>\n"
                // The first and last stops are always via points, as Garmin requires.
                let isShaping = stop.isShaping && index != 0 && index != last
                xml += isShaping ? "        <trp:ShapingPoint/>\n" : "        <trp:ViaPoint/>\n"
                let shape = index < route.legs.count ? route.legs[index].shape : []
                if !shape.isEmpty {
                    xml += "        <gpxx:RoutePointExtension>\n"
                    for point in shape {
                        xml += "          <gpxx:rpt\(attributes(point.coordinate))/>\n"
                    }
                    xml += "        </gpxx:RoutePointExtension>\n"
                }
                xml += "      </extensions>\n"
                xml += "    </rtept>\n"
            }
            xml += "  </rte>\n"
        }

        for track in library.tracks {
            xml += "  <trk>\n"
            xml += element("name", track.name, indent: "    ")
            xml += colourExtension("TrackExtension", track.color, indent: "    ")
            for segment in track.segments {
                xml += "    <trkseg>\n"
                for point in segment {
                    xml += "      <trkpt\(attributes(point.coordinate))>\n"
                    xml += element("ele", point.elevation.map(number), indent: "        ")
                    xml += element("time", point.time.map(GPXDate.string), indent: "        ")
                    xml += sensorExtensions(point, indent: "        ")
                    xml += "      </trkpt>\n"
                }
                xml += "    </trkseg>\n"
            }
            xml += "  </trk>\n"
        }

        xml += "</gpx>\n"
        return Data(xml.utf8)
    }

    private static func attributes(_ coordinate: Coordinate) -> String {
        " lat=\"\(number(coordinate.latitude))\" lon=\"\(number(coordinate.longitude))\""
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    /// The sensor readings of a track point, in Garmin's track point extension and power extension. Nothing when the
    /// point has none of them.
    private static func sensorExtensions(_ point: TrackPoint, indent: String) -> String {
        let inner = indent + "  "
        var body = ""
        let readings = element("gpxtpx:atemp", point.temperature.map { String(format: "%.1f", $0) }, indent: inner + "  ")
            + element("gpxtpx:hr", point.heartRate.map { String(format: "%.0f", $0) }, indent: inner + "  ")
            + element("gpxtpx:cad", point.cadence.map { String(format: "%.0f", $0) }, indent: inner + "  ")
        if !readings.isEmpty {
            body += "\(inner)<gpxtpx:TrackPointExtension>\n" + readings + "\(inner)</gpxtpx:TrackPointExtension>\n"
        }
        body += element("power:PowerInWatts", point.power.map { String(format: "%.0f", $0) }, indent: inner)
        guard !body.isEmpty else { return "" }
        return "\(indent)<extensions>\n" + body + "\(indent)</extensions>\n"
    }

    /// The Garmin waypoint extension: proximity, address and phone number. Nothing when the waypoint has none of them.
    private static func waypointExtensions(_ waypoint: Waypoint, indent: String) -> String {
        let inner = indent + "  "
        let address = waypoint.address
        let parts = [
            ("gpxx:StreetAddress", address?.street), ("gpxx:City", address?.city), ("gpxx:State", address?.state),
            ("gpxx:PostalCode", address?.postalCode), ("gpxx:Country", address?.country),
        ]
        let addressXML = parts.map { element($0.0, $0.1, indent: inner + "    ") }.joined()
        var body = ""
        if let proximity = waypoint.proximity {
            body += "\(inner)<gpxx:Proximity>\(number(proximity))</gpxx:Proximity>\n"
        }
        if !addressXML.isEmpty {
            body += "\(inner)<gpxx:Address>\n" + addressXML + "\(inner)</gpxx:Address>\n"
        }
        body += element("gpxx:PhoneNumber", address?.phone, indent: inner)
        guard !body.isEmpty else { return "" }
        return "\(indent)<extensions>\n\(indent)  <gpxx:WaypointExtension>\n"
            + body
            + "\(indent)  </gpxx:WaypointExtension>\n\(indent)</extensions>\n"
    }

    /// `<extensions>` holding the item's colour name, or nothing when the item has no colour.
    private static func colourExtension(_ element: String, _ color: ItemColor?, indent: String) -> String {
        guard let color else { return "" }
        let name = GarminColour.name(nearest: color)
        return "\(indent)<extensions>\n"
            + "\(indent)  <gpxx:\(element)>\n"
            + "\(indent)    <gpxx:DisplayColor>\(name)</gpxx:DisplayColor>\n"
            + "\(indent)  </gpxx:\(element)>\n"
            + "\(indent)</extensions>\n"
    }

    /// Writes `<name>value</name>`, or nothing when the value is missing or empty.
    private static func element(_ name: String, _ value: String?, indent: String) -> String {
        guard let value, !value.isEmpty else { return "" }
        return "\(indent)<\(name)>\(escape(value))</\(name)>\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private enum GPXDate {
    // Made once. ISO8601DateFormatter took about 2.4 s for 100k timestamps; the format style takes about 0.06 s.
    private static let fractionalParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainParser = Date.ISO8601FormatStyle()
    private static let formatter = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        guard hasValidTimeOfDay(text) else { return nil }
        return (try? fractionalParser.parse(text)) ?? (try? plainParser.parse(text))
    }

    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// The format style rolls an out-of-range time over to the next day (25:00 becomes 01:00), where
    /// the formatter rejected it. So the hour, minute and second are checked before parsing.
    private static func hasValidTimeOfDay(_ text: String) -> Bool {
        guard let separator = text.firstIndex(of: "T") else { return false }
        let fields = text[text.index(after: separator)...].prefix(8).split(separator: ":").compactMap { Int($0) }
        return fields.count == 3 && fields[0] <= 23 && fields[1] <= 59 && fields[2] <= 60
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
