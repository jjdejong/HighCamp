import Foundation

/// A name for a route stop from what the map shows at it, as BaseCamp names route points: a named point of interest
/// on it (a pass, a hut, a car park), else the street or path it is on, else the nearest village or hamlet, else the
/// forest or park it is in, else a place farther away.
public enum StopNames {
    /// How near a point of interest must be to name the stop.
    public static let pointReach = 50.0
    /// How near a street or path must be.
    public static let lineReach = 30.0
    /// A place this near names the stop before the area it is in.
    public static let nearPlaceReach = 1000.0
    /// The farthest place that still names it.
    public static let farPlaceReach = 3000.0

    public static func name(
        at coordinate: Coordinate,
        points: [MapPOI],
        lines: [NamedLine],
        places: [MapPlace],
        areas: [NamedArea]
    ) -> String? {
        found(at: coordinate, points: points, lines: lines, places: places, areas: areas).map(tidied)
    }

    /// Without what a map adds in brackets after a name, such as a bus stop's lines: "Hauts de Seyssins (Bus T65)".
    static func tidied(_ name: String) -> String {
        let trimmed = name.replacing(#/\s*\([^()]*\)\s*$/#, with: "")
        return trimmed.isEmpty ? name : trimmed
    }

    private static func found(
        at coordinate: Coordinate,
        points: [MapPOI],
        lines: [NamedLine],
        places: [MapPlace],
        areas: [NamedArea]
    ) -> String? {
        if let point = nearest(points.filter { $0.name != nil }, to: coordinate, within: pointReach, at: \.coordinate) {
            return point.name
        }
        var bestLine: (name: String, gap: Double)?
        for line in lines where !line.isWater {
            let gap = distance(from: coordinate, toLine: line.coordinates)
            if gap <= lineReach, gap < (bestLine?.gap ?? .infinity) {
                bestLine = (line.name, gap)
            }
        }
        if let bestLine {
            return bestLine.name
        }
        if let place = nearest(places, to: coordinate, within: nearPlaceReach, at: \.coordinate) {
            return place.name
        }
        if let area = areas.first(where: { area in area.rings.contains { contains($0, coordinate) } }) {
            return area.name
        }
        return nearest(places, to: coordinate, within: farPlaceReach, at: \.coordinate)?.name
    }

    private static func nearest<T>(_ items: [T], to coordinate: Coordinate, within reach: Double, at location: KeyPath<T, Coordinate>) -> T? {
        items.map { ($0, Geodesy.distance(from: coordinate, to: $0[keyPath: location])) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    /// Metres from a point to a line, on a flat projection around the point (lines here are a few hundred metres).
    static func distance(from point: Coordinate, toLine line: [Coordinate]) -> Double {
        let metresPerDegree = 111_320.0
        let east = cos(point.latitude * .pi / 180) * metresPerDegree
        func flat(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - point.longitude) * east, (c.latitude - point.latitude) * metresPerDegree)
        }
        guard let first = line.first else { return .infinity }
        var best = hypot(flat(first).x, flat(first).y)
        for (a, b) in zip(line, line.dropFirst()) {
            let p = flat(a), q = flat(b)
            let dx = q.x - p.x, dy = q.y - p.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / lengthSquared)) : 0
            best = min(best, hypot(p.x + t * dx, p.y + t * dy))
        }
        return best
    }

    /// Whether a ring holds the point (even-odd rule).
    static func contains(_ ring: [Coordinate], _ point: Coordinate) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
               point.longitude < (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
