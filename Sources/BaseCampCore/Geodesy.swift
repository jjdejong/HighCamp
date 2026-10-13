import Foundation

public enum Geodesy {
    static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance in metres between two coordinates (haversine formula).
    public static func distance(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Sum of distances between consecutive coordinates, in metres.
    static func length(of coordinates: [Coordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + distance(from: pair.0, to: pair.1)
        }
    }
}

public extension Route {
    /// Length along the route's points, in metres.
    var lengthMeters: Double {
        Geodesy.length(of: points.map(\.coordinate))
    }
}

public extension Track {
    /// Length of all segments, in metres. Gaps between segments are not counted.
    var lengthMeters: Double {
        segments.reduce(0) { total, segment in
            total + Geodesy.length(of: segment.map(\.coordinate))
        }
    }

    var pointCount: Int {
        segments.reduce(0) { $0 + $1.count }
    }

    /// First and last timestamps in the track, if the track has any.
    var timeSpan: ClosedRange<Date>? {
        let times = segments.flatMap { $0 }.compactMap(\.time)
        guard let first = times.min(), let last = times.max() else { return nil }
        return first...last
    }
}

public extension Library {
    /// Every coordinate in the library, for fitting a map view to its contents.
    var coordinates: [Coordinate] {
        waypoints.map(\.coordinate)
            + routes.flatMap { $0.points.map(\.coordinate) }
            + tracks.flatMap { $0.segments.flatMap { $0.map(\.coordinate) } }
    }
}
