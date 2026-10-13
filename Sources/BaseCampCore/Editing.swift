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

/// Edits that replace items with new ones. Each one moves the collections over with the item:
/// a collection that held the old item holds the new one in its place, and references to removed items are pruned.
public extension Library {
    /// Joins the tracks `ids` into `combined`, which takes the place of the first of them.
    /// Returns false when the first id is not a track in the library.
    @discardableResult
    mutating func combineTracks(_ ids: [UUID], into combined: Track) -> Bool {
        guard let first = ids.first, let index = tracks.firstIndex(where: { $0.id == first }) else { return false }
        tracks[index] = combined
        tracks.removeAll { ids.contains($0.id) }
        replaceCollectionItems(ids.map(CollectionItem.track), with: [.track(combined.id)])
        pruneCollections()
        return true
    }

    /// Replaces a track with its two pieces, which take its place. Returns false when there is no such track.
    @discardableResult
    mutating func splitTrack(_ id: UUID, into pieces: (Track, Track)) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        tracks.replaceSubrange(index...index, with: [pieces.0, pieces.1])
        replaceCollectionItems([.track(id)], with: [.track(pieces.0.id), .track(pieces.1.id)])
        pruneCollections()
        return true
    }

    /// Replaces a track with a route, which takes its place in the collections. Returns false when there is no such track.
    @discardableResult
    mutating func convertTrack(_ id: UUID, to route: Route) -> Bool {
        guard tracks.contains(where: { $0.id == id }) else { return false }
        tracks.removeAll { $0.id == id }
        routes.append(route)
        replaceCollectionItems([.track(id)], with: [.route(route.id)])
        pruneCollections()
        return true
    }

    /// Replaces a route with a track, which takes its place in the collections. Returns false when there is no such route.
    @discardableResult
    mutating func convertRoute(_ id: UUID, to track: Track) -> Bool {
        guard routes.contains(where: { $0.id == id }) else { return false }
        routes.removeAll { $0.id == id }
        tracks.append(track)
        replaceCollectionItems([.route(id)], with: [.track(track.id)])
        pruneCollections()
        return true
    }

    /// In each collection that holds any of `old`, puts `new` where the first of them was and drops the rest.
    private mutating func replaceCollectionItems(_ old: [CollectionItem], with new: [CollectionItem]) {
        for index in collections.indices where collections[index].items.contains(where: { old.contains($0) }) {
            var items: [CollectionItem] = []
            for item in collections[index].items {
                if !old.contains(item) {
                    items.append(item)
                } else if !items.contains(where: { new.contains($0) }) {
                    items += new
                }
            }
            collections[index].items = items
        }
    }
}

/// Copies the heights that `filled` added to `original` onto `points`. A point takes the new height only if its own
/// height is still the one it had in `original`, so a height edited in the meantime is kept. Returns nil unless
/// `points` has the same coordinates as `original`, in the same order, so the heights cannot land on the wrong points.
private func withAddedHeights<Point>(
    _ points: [Point],
    filled: [Point],
    original: [Point],
    coordinate: KeyPath<Point, Coordinate>,
    elevation: WritableKeyPath<Point, Double?>
) -> [Point]? {
    guard points.count == original.count, filled.count == original.count,
          zip(points, original).allSatisfy({ $0[keyPath: coordinate] == $1[keyPath: coordinate] }) else { return nil }
    var result = points
    for index in result.indices {
        let before = original[index][keyPath: elevation]
        let added = filled[index][keyPath: elevation]
        if added != before && result[index][keyPath: elevation] == before {
            result[index][keyPath: elevation] = added
        }
    }
    return result
}

public extension Track {
    /// This track with the heights that `filled` added to `original` (see `withAddedHeights`). Nil when this track
    /// no longer has the same points as `original`.
    func applyingElevations(from filled: Track, computedFrom original: Track) -> Track? {
        guard let points = withAddedHeights(
            segments.flatMap { $0 },
            filled: filled.segments.flatMap { $0 },
            original: original.segments.flatMap { $0 },
            coordinate: \.coordinate,
            elevation: \.elevation
        ) else { return nil }
        var copy = self
        var start = 0
        copy.segments = segments.map { segment in
            let slice = Array(points[start..<start + segment.count])
            start += segment.count
            return slice
        }
        return copy
    }
}

public extension Route {
    /// This route with the heights that `filled` added to `original` (see `withAddedHeights`). Nil when this route
    /// no longer has the same points as `original`.
    func applyingElevations(from filled: Route, computedFrom original: Route) -> Route? {
        guard let updated = withAddedHeights(
            points,
            filled: filled.points,
            original: original.points,
            coordinate: \.coordinate,
            elevation: \.elevation
        ) else { return nil }
        var copy = self
        copy.points = updated
        return copy
    }
}
