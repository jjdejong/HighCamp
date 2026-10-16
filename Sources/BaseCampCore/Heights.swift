import Foundation

/// Heights for a line or a place from two sources, such as the elevation models in a folder and the Garmin maps'
/// own heights. Mixing two sources inside one line puts false climbs where they meet (they differ by a few metres),
/// so a line takes all its heights from one source when one covers it.
public enum HeightChoice {
    /// One height per point: `preferred` when it has every point, else `other` when that has every point. Else,
    /// with `mixing`, point by point, `preferred` first; without, `preferred` as it is.
    public static func combine(_ preferred: [Double?], _ other: [Double?], mixing: Bool = true) -> [Double?] {
        precondition(preferred.count == other.count)
        if covers(preferred) { return preferred }
        if covers(other) { return other }
        guard mixing else { return preferred }
        return zip(preferred, other).map { $0 ?? $1 }
    }

    /// Whether every point has a height.
    public static func covers(_ heights: [Double?]) -> Bool {
        heights.allSatisfy { $0 != nil }
    }
}

public extension Track {
    /// The track's points, segment after segment, as `withElevations(_:replaceExisting:)` takes their heights.
    var allCoordinates: [Coordinate] {
        segments.flatMap { $0.map(\.coordinate) }
    }

    /// The track with `heights`, one per point in `allCoordinates` order, nil where there is none. With
    /// `replaceExisting` false, only points without a height are filled.
    func withElevations(_ heights: [Double?], replaceExisting: Bool) -> (Track, filled: Int, missing: Int) {
        var copy = self
        var filled = 0
        var missing = 0
        var next = 0
        for segmentIndex in copy.segments.indices {
            for pointIndex in copy.segments[segmentIndex].indices {
                defer { next += 1 }
                if copy.segments[segmentIndex][pointIndex].elevation != nil && !replaceExisting { continue }
                if next < heights.count, let height = heights[next] {
                    copy.segments[segmentIndex][pointIndex].elevation = height
                    filled += 1
                } else {
                    missing += 1
                }
            }
        }
        return (copy, filled, missing)
    }
}

public extension Route {
    /// The route with `heights`, one per point of `points`, nil where there is none. With `replaceExisting` false,
    /// only points without a height are filled.
    func withElevations(_ heights: [Double?], replaceExisting: Bool) -> (Route, filled: Int, missing: Int) {
        var points = self.points
        var filled = 0
        var missing = 0
        for index in points.indices {
            if points[index].elevation != nil && !replaceExisting { continue }
            if index < heights.count, let height = heights[index] {
                points[index].elevation = height
                filled += 1
            } else {
                missing += 1
            }
        }
        // Heights from a terrain model are not the road's in tunnels and on bridges.
        return ((replacingPoints(points) ?? self).levelingStructures(), filled, missing)
    }
}
