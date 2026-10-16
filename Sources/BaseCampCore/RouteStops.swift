import Foundation

public extension Route {
    /// The distance in metres from the start of the route to each stop, along the line. The last stop is at the end.
    func stopDistances() -> [Double] {
        var distances: [Double] = []
        var total = 0.0
        for index in stops.indices {
            distances.append(total)
            guard index < legs.count else { break }
            let chain = [stops[index].coordinate] + legs[index].shape.map(\.coordinate) + [stops[index + 1].coordinate]
            total += Geodesy.length(of: chain)
        }
        return distances
    }

    /// Makes a stop a shaping point (true) or a via point (false). The first and last stops are always via points,
    /// so for them the value is always false.
    mutating func setShaping(_ isShaping: Bool, at index: Int) {
        guard stops.indices.contains(index) else { return }
        let isMiddle = index != 0 && index != stops.count - 1
        updateStop(at: index) { $0.isShaping = isShaping && isMiddle }
    }
}

public extension RouteLeg {
    /// How a leg was made, as the inspector describes it.
    enum State: Equatable, Sendable {
        /// A straight line, with no shape points.
        case straight
        /// Kept straight by the user: never sent to the router.
        case keptStraight
        /// Calculated by the router with this profile. Nil when the profile is not known.
        case calculated(profileID: UUID?)
        /// Taken as it came, from a file or an older library.
        case imported
        /// A stop at one end changed, and the router has not yet recalculated the leg.
        case waiting
    }

    var state: State {
        if keepsStraight { return .keptStraight }
        if needsRecalculation { return .waiting }
        switch method {
        case .direct: return .straight
        case .calculated: return .calculated(profileID: profileID)
        case .imported: return .imported
        }
    }
}
