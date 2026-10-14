import Foundation

/// Distances along a track or route, as its profile measures them: from the first point, along each segment, with
/// the gaps between segments not counted. The profile cursor and a picked stretch are distances, so the map can show
/// them at the right place even where a loop passes the same spot twice.
public struct LineMeasure: Equatable, Sendable {
    public let segments: [[Coordinate]]
    /// The distance of each point from the first one, in metres, segment by segment.
    public let distances: [[Double]]

    public init(segments: [[Coordinate]]) {
        self.segments = segments
        var total = 0.0
        distances = segments.map { segment in
            var previous: Coordinate?
            return segment.map { coordinate in
                if let previous {
                    total += Geodesy.distance(from: previous, to: coordinate)
                }
                previous = coordinate
                return total
            }
        }
    }

    /// The length of the line in metres.
    public var length: Double {
        distances.last(where: { !$0.isEmpty })?.last ?? 0
    }

    /// The place at `distance` metres along the line, between the two points either side of it. Distances outside
    /// the line give its ends. Nil for an empty line.
    public func coordinate(at distance: Double) -> Coordinate? {
        for (segmentIndex, segment) in segments.enumerated() where !segment.isEmpty {
            let along = distances[segmentIndex]
            if distance <= along[0] {
                return segment[0]
            }
            if distance <= along[along.count - 1] {
                let next = Self.firstIndex(in: along, atLeast: distance)
                return Self.interpolate(segment, along, between: next - 1, and: next, at: distance)
            }
        }
        return segments.last(where: { !$0.isEmpty })?.last
    }

    /// The parts of the line from `range.lowerBound` to `range.upperBound` metres, with ends placed between points.
    /// One piece per segment the range touches; pieces of fewer than two points are left out.
    public func section(_ range: ClosedRange<Double>) -> [[Coordinate]] {
        var pieces: [[Coordinate]] = []
        for (segmentIndex, segment) in segments.enumerated() where segment.count > 1 {
            let along = distances[segmentIndex]
            let from = max(range.lowerBound, along[0])
            let to = min(range.upperBound, along[along.count - 1])
            guard from < to else { continue }
            let first = Self.firstIndex(in: along, atLeast: from)
            var piece = [Self.interpolate(segment, along, between: max(first - 1, 0), and: first, at: from)]
            var index = first
            while index < segment.count, along[index] < to {
                if along[index] > from {
                    piece.append(segment[index])
                }
                index += 1
            }
            piece.append(Self.interpolate(segment, along, between: max(index - 1, 0), and: min(index, segment.count - 1), at: to))
            pieces.append(piece)
        }
        return pieces
    }

    /// The distance along the line of the place on segment `segment`, between points `index` and `index + 1`, at
    /// `fraction` of the way. Used when the pointer is over the line on the map.
    public func distance(segment: Int, index: Int, fraction: Double) -> Double {
        let along = distances[segment]
        guard index + 1 < along.count else { return along[index] }
        return along[index] + (along[index + 1] - along[index]) * min(max(fraction, 0), 1)
    }

    /// The first index whose distance is at least `distance`; the last index if there is none.
    private static func firstIndex(in along: [Double], atLeast distance: Double) -> Int {
        var low = 0
        var high = along.count - 1
        while low < high {
            let middle = (low + high) / 2
            if along[middle] < distance {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func interpolate(_ segment: [Coordinate], _ along: [Double], between a: Int, and b: Int, at distance: Double) -> Coordinate {
        let span = along[b] - along[a]
        guard span > 0 else { return segment[b] }
        let t = (distance - along[a]) / span
        return Coordinate(
            latitude: segment[a].latitude + (segment[b].latitude - segment[a].latitude) * t,
            longitude: segment[a].longitude + (segment[b].longitude - segment[a].longitude) * t
        )
    }
}

public extension Track {
    /// Distances along the track, as its profile measures them.
    var measure: LineMeasure {
        LineMeasure(segments: segments.map { $0.map(\.coordinate) })
    }

    /// The track cut in two at the point nearest to `distance` metres along it (see `LineMeasure`). The point is
    /// the end of the first part and the start of the second. Nil when that would leave a part with a single point.
    func split(atDistance distance: Double) -> (Track, Track)? {
        let along = pointDistances
        var best: (segment: Int, point: Int)?
        var bestGap = Double.infinity
        for (segmentIndex, segment) in along.enumerated() {
            for (pointIndex, value) in segment.enumerated() where abs(value - distance) < bestGap {
                bestGap = abs(value - distance)
                best = (segmentIndex, pointIndex)
            }
        }
        guard let best else { return nil }
        let isFirst = best.segment == 0 && best.point == 0
        let isLast = best.segment == segments.count - 1 && best.point == segments[best.segment].count - 1
        guard !isFirst, !isLast else { return nil }
        return split(segment: best.segment, point: best.point)
    }
}

public extension Route {
    /// Distances along the route's line, as its profile measures them.
    var measure: LineMeasure {
        LineMeasure(segments: [points.map(\.coordinate)])
    }
}

public extension Array where Element == ElevationProfilePoint {
    /// The value at `distance` metres, between the profile points either side of it. Nil for an empty profile or a
    /// distance outside it.
    func value(at distance: Double) -> Double? {
        guard let first, let last, distance >= first.distanceMeters, distance <= last.distanceMeters else { return nil }
        var low = 0
        var high = count - 1
        while low < high {
            let middle = (low + high) / 2
            if self[middle].distanceMeters < distance {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return self[0].value }
        let a = self[low - 1], b = self[low]
        let span = b.distanceMeters - a.distanceMeters
        guard span > 0 else { return b.value }
        return a.value + (b.value - a.value) * (distance - a.distanceMeters) / span
    }

    /// The grade in percent around `distance`, from the values `window` metres before and after it. For a height
    /// profile. Nil where the profile does not reach.
    func grade(at distance: Double, window: Double = 25) -> Double? {
        guard let first, let last, last.distanceMeters - first.distanceMeters > 0 else { return nil }
        let from = Swift.max(first.distanceMeters, distance - window)
        let to = Swift.min(last.distanceMeters, distance + window)
        guard to > from, let low = value(at: from), let high = value(at: to) else { return nil }
        return (high - low) / (to - from) * 100
    }

    /// At most about `limit` points for drawing, keeping the lowest and highest point of each stretch so peaks and
    /// dips stay visible. The first and last points are kept. Profiles within the limit are returned as they are.
    func thinnedForDrawing(limit: Int) -> [ElevationProfilePoint] {
        guard count > limit, limit >= 4 else { return self }
        let buckets = limit / 2
        let size = Double(count) / Double(buckets)
        var result: [ElevationProfilePoint] = [self[0]]
        for bucket in 0..<buckets {
            let start = Int(Double(bucket) * size)
            let end = Swift.min(count, Int(Double(bucket + 1) * size))
            guard start < end else { continue }
            let slice = self[start..<end]
            guard let low = slice.min(by: { $0.value < $1.value }), let high = slice.max(by: { $0.value < $1.value }) else { continue }
            let pair = low.distanceMeters <= high.distanceMeters ? [low, high] : [high, low]
            for point in pair where point.id != result.last?.id {
                result.append(point)
            }
        }
        if let last, result.last?.id != last.id {
            result.append(last)
        }
        return result
    }
}
