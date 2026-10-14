import Foundation

/// Point-level edits: removing a stretch of a track by its distance, and thinning it to a point every so many
/// seconds or metres. Both keep each point's own readings, so elevations and sensor values stay with their points.
public extension Track {
    /// The distance in metres of each point from the first point, along the track. It is the distance the elevation
    /// profile plots: gaps between segments are not counted, and the distance carries on across them.
    var pointDistances: [[Double]] {
        var total = 0.0
        return segments.map { segment in
            var previous: Coordinate?
            return segment.map { point in
                if let previous {
                    total += Geodesy.distance(from: previous, to: point.coordinate)
                }
                previous = point.coordinate
                return total
            }
        }
    }

    /// The track without the points whose distance along it (see `pointDistances`) lies in `range`. Segments left
    /// with no points are dropped. Returns nil when no point lies in the range.
    func removingPoints(distanceIn range: ClosedRange<Double>) -> Track? {
        let distances = pointDistances
        var removedAny = false
        var kept: [[TrackPoint]] = []
        for (segmentIndex, segment) in segments.enumerated() {
            var points: [TrackPoint] = []
            for (pointIndex, point) in segment.enumerated() {
                if range.contains(distances[segmentIndex][pointIndex]) {
                    removedAny = true
                } else {
                    points.append(point)
                }
            }
            if !points.isEmpty {
                kept.append(points)
            }
        }
        guard removedAny else { return nil }
        var copy = self
        copy.segments = kept
        return copy
    }

    /// Keeps a point only when at least `seconds` have passed since the last kept point. Each segment keeps its first
    /// and last points. A point is also kept when either time is missing, since there is nothing to compare.
    func thinned(everySeconds seconds: TimeInterval) -> Track {
        thinning { segmentIndex, last, next in
            guard let from = segments[segmentIndex][last].time, let to = segments[segmentIndex][next].time else { return true }
            return to.timeIntervalSince(from) >= seconds
        }
    }

    /// Keeps a point only when at least `metres` along the track separate it from the last kept point. Each segment
    /// keeps its first and last points.
    func thinned(everyMetres metres: Double) -> Track {
        let distances = pointDistances
        return thinning { segmentIndex, last, next in
            distances[segmentIndex][next] - distances[segmentIndex][last] >= metres
        }
    }

    /// Keeps the first and last point of each segment, and each other point that `isFarEnough` accepts against the
    /// last point kept before it. `isFarEnough` takes the segment index and the indices of the two points in it.
    private func thinning(isFarEnough: (_ segment: Int, _ last: Int, _ next: Int) -> Bool) -> Track {
        var copy = self
        copy.segments = segments.indices.map { segmentIndex in
            let segment = segments[segmentIndex]
            guard segment.count > 1 else { return segment }
            var kept = [0]
            for index in 1..<segment.count {
                let lastKept = kept[kept.count - 1]
                if index == segment.count - 1 || isFarEnough(segmentIndex, lastKept, index) {
                    kept.append(index)
                }
            }
            return kept.map { segment[$0] }
        }
        return copy
    }
}
