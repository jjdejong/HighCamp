import Foundation

public enum GPXError: Error, Equatable {
    case malformedXML(String)
    case missingCoordinate(element: String)
    case invalidCoordinate(element: String)
}

extension GPXError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedXML(let detail):
            "The file is not valid XML: \(detail)"
        case .missingCoordinate(let element):
            "A <\(element)> element has no valid lat and lon."
        case .invalidCoordinate(let element):
            "A <\(element)> element has coordinates outside the valid range."
        }
    }
}

/// Reads and writes GPX 1.1 files: waypoints, routes and tracks.
/// Elements the planner does not use are skipped on read.
public enum GPX {
    public static func read(_ data: Data) throws -> Library {
        try GPXReader().read(data)
    }

    public static func write(_ library: Library) -> Data {
        GPXWriter.write(library)
    }
}

private final class GPXReader: NSObject, XMLParserDelegate {
    private var library = Library()
    private var stack: [String] = []
    private var text = ""
    private var failure: GPXError?

    private var waypoint: Waypoint?
    private var route: Route?
    private var routePoint: RoutePoint?
    private var track: Track?
    private var segment: [TrackPoint]?
    private var trackPoint: TrackPoint?

    func read(_ data: Data) throws -> Library {
        let parser = XMLParser(data: data)
        parser.delegate = self
        let succeeded = parser.parse()
        if let failure {
            throw failure
        }
        if !succeeded {
            throw GPXError.malformedXML(parser.parserError?.localizedDescription ?? "unknown error")
        }
        return library
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
        switch elementName {
        case "wpt":
            guard let coordinate = coordinate(attributes, element: elementName, parser: parser) else { return }
            waypoint = Waypoint(name: "", coordinate: coordinate)
        case "rte":
            route = Route(name: "")
        case "rtept":
            guard let coordinate = coordinate(attributes, element: elementName, parser: parser) else { return }
            routePoint = RoutePoint(coordinate: coordinate)
        case "trk":
            track = Track(name: "")
        case "trkseg":
            segment = []
        case "trkpt":
            guard let coordinate = coordinate(attributes, element: elementName, parser: parser) else { return }
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
        case ("wpt", _):
            if let waypoint { library.waypoints.append(waypoint) }
            waypoint = nil

        case ("name", "rte"):
            route?.name = value
        case ("name", "rtept"):
            routePoint?.name = value.nonEmpty
        case ("ele", "rtept"):
            routePoint?.elevation = Double(value)
        case ("rtept", _):
            if let routePoint { route?.points.append(routePoint) }
            routePoint = nil
        case ("rte", _):
            if let route { library.routes.append(route) }
            route = nil

        case ("name", "trk"):
            track?.name = value
        case ("ele", "trkpt"):
            trackPoint?.elevation = Double(value)
        case ("time", "trkpt"):
            trackPoint?.time = GPXDate.parse(value)
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

    private func coordinate(_ attributes: [String: String], element: String, parser: XMLParser) -> Coordinate? {
        guard let latitudeText = attributes["lat"], let longitudeText = attributes["lon"],
              let latitude = Double(latitudeText), let longitude = Double(longitudeText) else {
            fail(.missingCoordinate(element: element), parser: parser)
            return nil
        }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else {
            fail(.invalidCoordinate(element: element), parser: parser)
            return nil
        }
        return coordinate
    }

    private func fail(_ error: GPXError, parser: XMLParser) {
        failure = error
        parser.abortParsing()
    }
}

private enum GPXWriter {
    static func write(_ library: Library) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"BaseCamp Clone\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"

        for waypoint in library.waypoints {
            xml += "  <wpt\(attributes(waypoint.coordinate))>\n"
            xml += element("ele", waypoint.elevation.map(number), indent: "    ")
            xml += element("time", waypoint.time.map(GPXDate.string), indent: "    ")
            xml += element("name", waypoint.name, indent: "    ")
            xml += element("cmt", waypoint.comment, indent: "    ")
            xml += element("sym", waypoint.symbol, indent: "    ")
            xml += "  </wpt>\n"
        }

        for route in library.routes {
            xml += "  <rte>\n"
            xml += element("name", route.name, indent: "    ")
            for point in route.points {
                xml += "    <rtept\(attributes(point.coordinate))>\n"
                xml += element("ele", point.elevation.map(number), indent: "      ")
                xml += element("name", point.name, indent: "      ")
                xml += "    </rtept>\n"
            }
            xml += "  </rte>\n"
        }

        for track in library.tracks {
            xml += "  <trk>\n"
            xml += element("name", track.name, indent: "    ")
            for segment in track.segments {
                xml += "    <trkseg>\n"
                for point in segment {
                    xml += "      <trkpt\(attributes(point.coordinate))>\n"
                    xml += element("ele", point.elevation.map(number), indent: "        ")
                    xml += element("time", point.time.map(GPXDate.string), indent: "        ")
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
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }

    static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
