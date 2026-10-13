import Foundation

public enum ExchangeError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "The file could not be read. \(reason)"
        }
    }
}

/// KML, the format Google Earth reads. Waypoints become points; routes and tracks become lines.
public enum KML {
    public static func write(_ library: Library, name: String = "Library") -> Data {
        var out = header + "<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n<Document>\n"
        out += "<name>\(escape(name))</name>\n"
        for waypoint in library.waypoints {
            out += "<Placemark>\n<name>\(escape(waypoint.name))</name>\n"
            if let comment = waypoint.comment {
                out += "<description>\(escape(comment))</description>\n"
            }
            out += "<Point><coordinates>\(coordinate(waypoint.coordinate, elevation: waypoint.elevation))</coordinates></Point>\n</Placemark>\n"
        }
        for route in library.routes {
            let coordinates = route.points.map { coordinate($0.coordinate, elevation: $0.elevation) }.joined(separator: " ")
            out += "<Placemark>\n<name>\(escape(route.name))</name>\n<LineString><tessellate>1</tessellate><coordinates>\(coordinates)</coordinates></LineString>\n</Placemark>\n"
        }
        for track in library.tracks {
            // A track with several segments becomes a MultiGeometry, one line per segment.
            let lines = track.segments.map { segment in
                "<LineString><tessellate>1</tessellate><coordinates>"
                    + segment.map { coordinate($0.coordinate, elevation: $0.elevation) }.joined(separator: " ")
                    + "</coordinates></LineString>"
            }
            out += "<Placemark>\n<name>\(escape(track.name))</name>\n<MultiGeometry>\(lines.joined())</MultiGeometry>\n</Placemark>\n"
        }
        out += "</Document>\n</kml>\n"
        return Data(out.utf8)
    }

    /// Reads points as waypoints and lines as tracks. A placemark with several lines becomes one track.
    public static func read(_ data: Data) throws -> Library {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [])
        } catch {
            throw ExchangeError.unreadable(error.localizedDescription)
        }
        var library = Library()
        for placemark in try document.nodes(forXPath: "//*[local-name()='Placemark']") {
            let name = try text(placemark, "./*[local-name()='name']") ?? ""
            let comment = try text(placemark, "./*[local-name()='description']")
            for point in try placemark.nodes(forXPath: ".//*[local-name()='Point']") {
                for coordinates in try point.nodes(forXPath: ".//*[local-name()='coordinates']") {
                    for position in parseCoordinates(coordinates.stringValue ?? "") {
                        library.waypoints.append(Waypoint(
                            name: name,
                            coordinate: position.coordinate,
                            elevation: position.elevation,
                            comment: comment
                        ))
                    }
                }
            }
            var segments: [[TrackPoint]] = []
            for line in try placemark.nodes(forXPath: ".//*[local-name()='LineString']") {
                for coordinates in try line.nodes(forXPath: ".//*[local-name()='coordinates']") {
                    let points = parseCoordinates(coordinates.stringValue ?? "").map {
                        TrackPoint(coordinate: $0.coordinate, elevation: $0.elevation)
                    }
                    if !points.isEmpty {
                        segments.append(points)
                    }
                }
            }
            if !segments.isEmpty {
                library.tracks.append(Track(name: name, segments: segments))
            }
        }
        return library
    }

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"

    /// KML writes longitude, latitude, then optional altitude.
    private static func coordinate(_ coordinate: Coordinate, elevation: Double?) -> String {
        let height = elevation.map { String($0) } ?? "0"
        return "\(coordinate.longitude),\(coordinate.latitude),\(height)"
    }

    /// Parses "lon,lat[,alt] lon,lat[,alt] …".
    static func parseCoordinates(_ text: String) -> [(coordinate: Coordinate, elevation: Double?)] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { item in
            let parts = item.split(separator: ",").map { String($0) }
            guard parts.count >= 2, let longitude = Double(parts[0]), let latitude = Double(parts[1]) else { return nil }
            let elevation = parts.count >= 3 ? Double(parts[2]) : nil
            return (Coordinate(latitude: latitude, longitude: longitude), elevation)
        }
    }
}

/// Garmin's TCX courses and activities. Routes and tracks are written as courses, and both are read back.
public enum TCX {
    /// A course: one lap, and every point of the route or track.
    public static func course(name: String, points: [CoursePoint], start: Date = Date()) -> Data {
        let distance = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            total + Geodesy.distance(from: pair.0.coordinate, to: pair.1.coordinate)
        }
        var out = header + "<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\">\n<Courses>\n<Course>\n"
        out += "<Name>\(escape(String(name.prefix(15))))</Name>\n"
        if let first = points.first, let last = points.last {
            out += "<Lap>\n<TotalTimeSeconds>\(max(0, points.count - 1))</TotalTimeSeconds>\n<DistanceMeters>\(String(format: "%.1f", distance))</DistanceMeters>\n"
            out += "<BeginPosition>\(position(first.coordinate))</BeginPosition>\n<EndPosition>\(position(last.coordinate))</EndPosition>\n"
            out += "<Intensity>Active</Intensity>\n</Lap>\n"
        }
        out += "<Track>\n"
        var travelled = 0.0
        for (index, point) in points.enumerated() {
            if index > 0 {
                travelled += Geodesy.distance(from: points[index - 1].coordinate, to: point.coordinate)
            }
            out += "<Trackpoint>\n<Time>\(iso8601(start.addingTimeInterval(Double(index))))</Time>\n"
            out += "<Position>\(position(point.coordinate))</Position>\n"
            if let elevation = point.elevation {
                out += "<AltitudeMeters>\(String(format: "%.1f", elevation))</AltitudeMeters>\n"
            }
            out += "<DistanceMeters>\(String(format: "%.1f", travelled))</DistanceMeters>\n</Trackpoint>\n"
        }
        out += "</Track>\n</Course>\n</Courses>\n</TrainingCenterDatabase>\n"
        return Data(out.utf8)
    }

    /// Reads courses and activities. Every `Track` element becomes one track segment.
    public static func read(_ data: Data) throws -> Library {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [])
        } catch {
            throw ExchangeError.unreadable(error.localizedDescription)
        }
        var library = Library()
        let courses = try document.nodes(forXPath: "//*[local-name()='Course']")
        let activities = try document.nodes(forXPath: "//*[local-name()='Activity']")
        let owners = courses + activities
        for owner in owners {
            let name = try text(owner, "./*[local-name()='Name']") ?? text(owner, "./*[local-name()='Id']") ?? "Imported"
            var segments: [[TrackPoint]] = []
            for track in try owner.nodes(forXPath: "./*[local-name()='Lap']/*[local-name()='Track'] | ./*[local-name()='Track']") {
                var points: [TrackPoint] = []
                for trackpoint in try track.nodes(forXPath: "./*[local-name()='Trackpoint']") {
                    guard let latitude = Double(try text(trackpoint, ".//*[local-name()='LatitudeDegrees']") ?? ""),
                          let longitude = Double(try text(trackpoint, ".//*[local-name()='LongitudeDegrees']") ?? "") else { continue }
                    let elevation = Double(try text(trackpoint, "./*[local-name()='AltitudeMeters']") ?? "")
                    let time = try text(trackpoint, "./*[local-name()='Time']").flatMap(parseISO8601)
                    points.append(TrackPoint(
                        coordinate: Coordinate(latitude: latitude, longitude: longitude),
                        elevation: elevation,
                        time: time
                    ))
                }
                if !points.isEmpty {
                    segments.append(points)
                }
            }
            if !segments.isEmpty {
                library.tracks.append(Track(name: name, segments: segments))
            }
        }
        return library
    }

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"

    private static func position(_ coordinate: Coordinate) -> String {
        "<LatitudeDegrees>\(String(format: "%.7f", coordinate.latitude))</LatitudeDegrees><LongitudeDegrees>\(String(format: "%.7f", coordinate.longitude))</LongitudeDegrees>"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Comma-separated waypoints, for spreadsheets.
public enum CSV {
    public static func waypoints(_ waypoints: [Waypoint]) -> Data {
        var lines = ["Name,Latitude,Longitude,Elevation (m),Time,Symbol,Comment"]
        let formatter = ISO8601DateFormatter()
        for waypoint in waypoints {
            lines.append([
                field(waypoint.name),
                String(format: "%.6f", waypoint.coordinate.latitude),
                String(format: "%.6f", waypoint.coordinate.longitude),
                waypoint.elevation.map { String(format: "%.1f", $0) } ?? "",
                waypoint.time.map { formatter.string(from: $0) } ?? "",
                field(waypoint.symbol ?? ""),
                field(waypoint.comment ?? ""),
            ].joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Quotes a field when it contains a comma, a quote or a line break.
    static func field(_ text: String) -> String {
        guard text.contains(where: { ",\"\r\n".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private func text(_ node: XMLNode, _ xpath: String) throws -> String? {
    try node.nodes(forXPath: xpath).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
