import Foundation

public extension Route {
    /// The legs the router still has to recalculate, in order.
    var legsWaitingForRouter: [Int] {
        legs.indices.filter { legs[$0].needsRecalculation }
    }

    /// The leg's line, from its start stop to its end stop.
    func legLine(_ index: Int) -> [Coordinate] {
        guard legs.indices.contains(index) else { return [] }
        return [stops[index].coordinate] + legs[index].shape.map(\.coordinate) + [stops[index + 1].coordinate]
    }

    /// The point halfway along a leg, where a handle to insert a stop is drawn.
    func legMidpoint(_ index: Int) -> Coordinate? {
        let line = legLine(index)
        guard line.count >= 2 else { return nil }
        let half = Geodesy.length(of: line) / 2
        var travelled = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let step = Geodesy.distance(from: a, to: b)
            if travelled + step >= half, step > 0 {
                let fraction = (half - travelled) / step
                return Coordinate(
                    latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                    longitude: a.longitude + (b.longitude - a.longitude) * fraction
                )
            }
            travelled += step
        }
        return line[0]
    }
}

public extension RouteLeg {
    /// A leg from the line the router gave between its two stops. The router starts and ends on the nearest road,
    /// so the line's ends are kept as shape points; only points on the stops themselves are dropped.
    static func calculated(line: [RoutePoint], from start: Coordinate, to end: Coordinate, profileID: UUID?) -> RouteLeg {
        RouteLeg(
            shape: line.filter { $0.coordinate != start && $0.coordinate != end },
            method: .calculated,
            profileID: profileID
        )
    }
}
