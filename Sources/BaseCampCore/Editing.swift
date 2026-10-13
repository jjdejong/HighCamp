import Foundation

public extension Track {
    /// The same track run the other way. Timestamps are mirrored across the track's time span, so they still
    /// run forward and the duration, moving time and speeds stay the same.
    func reversed() -> Track {
        var copy = self
        let times = segments.flatMap { $0 }.compactMap(\.time)
        let sum: TimeInterval? = {
            guard let first = times.min(), let last = times.max() else { return nil }
            return first.timeIntervalSince1970 + last.timeIntervalSince1970
        }()
        copy.segments = segments.reversed().map { segment in
            segment.reversed().map { point in
                var point = point
                if let sum, let time = point.time {
                    point.time = Date(timeIntervalSince1970: sum - time.timeIntervalSince1970)
                }
                return point
            }
        }
        return copy
    }

    /// Joins the segments of all tracks, in order, into one track named `name`.
    static func combined(_ tracks: [Track], name: String) -> Track {
        Track(name: name, segments: tracks.flatMap(\.segments))
    }

    /// Cuts the track into two tracks at the point nearest to `coordinate`. The cut point is in both halves.
    /// Returns nil when the track has no points.
    func split(nearest coordinate: Coordinate) -> (Track, Track)? {
        guard let (segmentIndex, pointIndex) = nearestPoint(to: coordinate) else { return nil }
        var before: [[TrackPoint]] = Array(segments[..<segmentIndex])
        var after: [[TrackPoint]] = Array(segments[(segmentIndex + 1)...])
        let segment = segments[segmentIndex]
        before.append(Array(segment[...pointIndex]))
        after.insert(Array(segment[pointIndex...]), at: 0)
        let first = Track(name: name + " (1)", segments: before)
        let second = Track(name: name + " (2)", segments: after)
        return (first, second)
    }

    /// Fewer points, with the shape kept to within `tolerance` metres (Douglas-Peucker, per segment).
    /// Points keep their timestamps and elevations.
    func simplified(tolerance: Double) -> Track {
        var copy = self
        copy.segments = segments.map { DouglasPeucker.simplify($0, tolerance: tolerance, coordinate: \.coordinate) }
        return copy
    }

    /// The track as a route: every point, with its elevation.
    func asRoute() -> Route {
        Route(name: name, points: segments.flatMap { $0 }.map {
            RoutePoint(coordinate: $0.coordinate, elevation: $0.elevation)
        })
    }

    /// Index of the segment and point nearest to a coordinate, or nil for an empty track.
    func nearestPoint(to coordinate: Coordinate) -> (Int, Int)? {
        var best: (Int, Int)?
        var bestDistance = Double.infinity
        for (segmentIndex, segment) in segments.enumerated() {
            for (pointIndex, point) in segment.enumerated() {
                let distance = Geodesy.distance(from: point.coordinate, to: coordinate)
                if distance < bestDistance {
                    bestDistance = distance
                    best = (segmentIndex, pointIndex)
                }
            }
        }
        return best
    }
}

public extension Route {
    /// The same route run the other way.
    func reversed() -> Route {
        Route(id: id, name: name, points: points.reversed())
    }

    /// The route as a track: one segment with its points.
    func asTrack() -> Track {
        Track(name: name, segments: [points.map {
            TrackPoint(coordinate: $0.coordinate, elevation: $0.elevation)
        }])
    }

    /// Fewer points, with the shape kept to within `tolerance` metres.
    func simplified(tolerance: Double) -> Route {
        Route(id: id, name: name, points: DouglasPeucker.simplify(points, tolerance: tolerance, coordinate: \.coordinate))
    }
}

/// Keeps the points that define a line's shape. Points closer than `tolerance` metres to the line
/// between their kept neighbours are dropped.
enum DouglasPeucker {
    static func simplify<Point>(_ points: [Point], tolerance: Double, coordinate: KeyPath<Point, Coordinate>) -> [Point] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            var worst = 0.0
            var worstIndex = 0
            for index in (start + 1)..<end {
                let distance = distanceToSegment(
                    points[index][keyPath: coordinate],
                    from: points[start][keyPath: coordinate],
                    to: points[end][keyPath: coordinate]
                )
                if distance > worst {
                    worst = distance
                    worstIndex = index
                }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((start, worstIndex))
                stack.append((worstIndex, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Distance in metres from a point to a segment, using a flat approximation around the segment.
    static func distanceToSegment(_ point: Coordinate, from a: Coordinate, to b: Coordinate) -> Double {
        let metresPerDegreeLatitude = 111_195.0
        let metresPerDegreeLongitude = 111_195.0 * cos(a.latitude * .pi / 180)
        func planar(_ c: Coordinate) -> (Double, Double) {
            ((c.longitude - a.longitude) * metresPerDegreeLongitude, (c.latitude - a.latitude) * metresPerDegreeLatitude)
        }
        let (px, py) = planar(point)
        let (bx, by) = planar(b)
        let lengthSquared = bx * bx + by * by
        guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
        let t = max(0, min(1, (px * bx + py * by) / lengthSquared))
        let dx = px - t * bx
        let dy = py - t * by
        return (dx * dx + dy * dy).squareRoot()
    }
}
