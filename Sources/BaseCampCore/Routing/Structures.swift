import Foundation

/// Tunnels and bridges along a line. A terrain model gives the ground above a tunnel and, as IGN's bare-earth
/// models have no bridges, the valley under a bridge; the road runs straight from one end to the other. Their
/// heights are drawn straight across.
public enum Structures {
    /// `heights` at `distances` along a line, with those inside each stretch replaced by a straight line between
    /// the last point at or before the stretch and the first at or after it. A stretch whose end has no height is
    /// left as it is.
    public static func level(_ heights: [Double?], at distances: [Double], over stretches: [ClosedRange<Double>]) -> [Double?] {
        guard heights.count == distances.count, !stretches.isEmpty else { return heights }
        var result = heights
        for stretch in stretches {
            guard let start = distances.lastIndex(where: { $0 <= stretch.lowerBound }),
                  let end = distances.firstIndex(where: { $0 >= stretch.upperBound }),
                  end > start + 1, let from = result[start], let to = result[end] else { continue }
            let run = distances[end] - distances[start]
            for index in (start + 1)..<end {
                result[index] = run > 0 ? from + (to - from) * (distances[index] - distances[start]) / run : from
            }
        }
        return result
    }

    /// Whether a way's tags, as BRouter reports them, say it is a tunnel or a bridge.
    static func isStructure(_ tags: String) -> Bool {
        tags.split(separator: " ").contains { tag in
            (tag.hasPrefix("tunnel=") || tag.hasPrefix("bridge=")) && !tag.hasSuffix("=no")
        }
    }

    /// The stretches of a BRouter answer's line that are tunnels or bridges, in metres along `points`. Each row of
    /// BRouter's messages ends where the way changes, and its tags are those of the way since the previous row.
    static func stretches(messages: [[String]], points: [CoursePoint]) -> [ClosedRange<Double>] {
        guard let header = messages.first, let longitude = header.firstIndex(of: "Longitude"),
              let latitude = header.firstIndex(of: "Latitude"), let tags = header.firstIndex(of: "WayTags") else { return [] }
        let distances = GradeAnalysis.cumulativeDistances(points)
        var result: [ClosedRange<Double>] = []
        var previous = 0
        for row in messages.dropFirst() {
            guard row.count > max(longitude, latitude, tags), let x = Double(row[longitude]), let y = Double(row[latitude]) else { continue }
            // Rows give degrees in millionths; find the row's end among the line's points, from the previous one on.
            guard let end = points.indices.dropFirst(previous).first(where: { index in
                abs(points[index].coordinate.longitude * 1_000_000 - x) <= 1.5 && abs(points[index].coordinate.latitude * 1_000_000 - y) <= 1.5
            }) else { continue }
            if isStructure(row[tags]), end > previous {
                if let last = result.last, last.upperBound == distances[previous] {
                    result[result.count - 1] = last.lowerBound...distances[end]
                } else {
                    result.append(distances[previous]...distances[end])
                }
            }
            previous = end
        }
        return result
    }
}

public extension Array where Element == ElevationProfilePoint {
    /// The profile with its values drawn straight across each stretch (see `Structures.level`).
    func leveled(over stretches: [ClosedRange<Double>]) -> [ElevationProfilePoint] {
        guard !stretches.isEmpty else { return self }
        let values = Structures.level(map(\.value), at: map(\.distanceMeters), over: stretches)
        var result = self
        for index in result.indices {
            result[index].value = values[index] ?? result[index].value
        }
        return result
    }
}

public extension Route {
    /// The tunnels and bridges of the calculated legs, in metres from the route's start.
    var structureStretches: [ClosedRange<Double>] {
        let starts = stopDistances()
        return legs.indices.flatMap { index in
            (legs[index].structures ?? []).map { (starts[index] + $0.lowerBound)...(starts[index] + $0.upperBound) }
        }
    }

    /// The route with its points' heights drawn straight across its tunnels and bridges.
    func levelingStructures() -> Route {
        let stretches = structureStretches
        guard !stretches.isEmpty else { return self }
        let points = self.points
        let heights = Structures.level(points.map(\.elevation), at: GradeAnalysis.cumulativeDistances(points.map { CoursePoint(coordinate: $0.coordinate) }), over: stretches)
        var updated = points
        for index in updated.indices {
            updated[index].elevation = heights[index]
        }
        return replacingPoints(updated) ?? self
    }
}
