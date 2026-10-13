import Foundation

/// One point of a route's line, as drawn, measured and sent to the device.
public struct RoutePoint: Equatable, Codable, Sendable {
    public var name: String?
    public var coordinate: Coordinate
    /// Set for calculated routes, which carry the terrain height at each point.
    public var elevation: Double?

    public init(name: String? = nil, coordinate: Coordinate, elevation: Double? = nil) {
        self.name = name
        self.coordinate = coordinate
        self.elevation = elevation
    }
}

/// A point the route is planned through, as BaseCamp's via and shaping points: the user places, moves and deletes
/// these, and the line between two stops (a leg) is calculated from them.
public struct RouteStop: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String?
    public var coordinate: Coordinate
    public var elevation: Double?
    /// A shaping point only steers the route; a via point (false) is also announced on the device.
    public var isShaping: Bool

    public init(id: UUID = UUID(), name: String? = nil, coordinate: Coordinate, elevation: Double? = nil, isShaping: Bool = false) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.elevation = elevation
        self.isShaping = isShaping
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        coordinate = try values.decode(Coordinate.self, forKey: .coordinate)
        elevation = try values.decodeIfPresent(Double.self, forKey: .elevation)
        isShaping = try values.decodeIfPresent(Bool.self, forKey: .isShaping) ?? false
    }

    var point: RoutePoint {
        RoutePoint(name: name, coordinate: coordinate, elevation: elevation)
    }
}

/// The line from one stop to the next.
public struct RouteLeg: Equatable, Codable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// A straight line: no shape points.
        case direct
        /// Calculated by the router with `profileID`.
        case calculated
        /// Taken as it came, from a file or an older library: kept until a stop at either end moves.
        case imported
    }

    /// The points strictly between the leg's two stops.
    public var shape: [RoutePoint]
    public var method: Method
    /// The routing profile a calculated leg was planned with.
    public var profileID: UUID?
    /// Set when a stop at either end changed since the leg was calculated. The leg is drawn straight until the
    /// router has recalculated it.
    public var needsRecalculation: Bool

    public init(shape: [RoutePoint] = [], method: Method = .direct, profileID: UUID? = nil, needsRecalculation: Bool = false) {
        self.shape = shape
        self.method = method
        self.profileID = profileID
        self.needsRecalculation = needsRecalculation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shape = try values.decodeIfPresent([RoutePoint].self, forKey: .shape) ?? []
        method = try values.decodeIfPresent(Method.self, forKey: .method) ?? .direct
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        needsRecalculation = try values.decodeIfPresent(Bool.self, forKey: .needsRecalculation) ?? false
    }
}

/// A route as BaseCamp keeps one: the stops the user placed, and between each two a leg with the calculated
/// shape. `points` is the whole line, stops and shapes in order, for drawing, statistics and export.
public struct Route: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Never fewer legs than needed: `legs.count == max(0, stops.count - 1)`, kept by every change below.
    public private(set) var stops: [RouteStop]
    public private(set) var legs: [RouteLeg]
    /// The routing profile that recalculates legs after a stop changes. Nil keeps changed legs straight.
    public var profileID: UUID?
    /// The colour the route is drawn in. Nil means the default colour. Files from before colours have none.
    public var color: ItemColor?

    /// Routes from lists of points with more points than this keep only their ends and named points as stops;
    /// the rest becomes the legs' shape. Shorter lists, as clicked by hand, keep every point as a stop.
    public static let maximumStopsFromPoints = 200

    public init(id: UUID = UUID(), name: String, stops: [RouteStop], legs: [RouteLeg]? = nil, profileID: UUID? = nil, color: ItemColor? = nil) {
        self.id = id
        self.name = name
        self.stops = stops
        let needed = max(0, stops.count - 1)
        if let legs, legs.count == needed {
            self.legs = legs
        } else {
            self.legs = Array(repeating: RouteLeg(), count: needed)
        }
        self.profileID = profileID
        self.color = color
    }

    /// A route from a plain list of points, as in a GPX file without shape points or an older library. Up to
    /// `maximumStopsFromPoints` points, each is a stop joined by straight legs. Longer lists keep their ends and
    /// named points as stops, and the points between as imported legs.
    public init(id: UUID = UUID(), name: String, points: [RoutePoint] = [], color: ItemColor? = nil) {
        guard points.count > Self.maximumStopsFromPoints else {
            self.init(id: id, name: name, stops: points.map(Self.stop), color: color)
            return
        }
        let stopIndices = points.indices.filter { $0 == 0 || $0 == points.count - 1 || points[$0].name != nil }
        let legs = zip(stopIndices, stopIndices.dropFirst()).map { start, end in
            RouteLeg(shape: Array(points[(start + 1)..<end]), method: .imported)
        }
        self.init(id: id, name: name, stops: stopIndices.map { Self.stop(points[$0]) }, legs: legs, color: color)
    }

    /// A route planned by the router through `stops`: the planned line is cut at each stop into calculated legs,
    /// and each stop is moved onto the line, where the router put it.
    public static func planned(
        id: UUID = UUID(), name: String, stops: [RouteStop], line: [RoutePoint], profileID: UUID?, color: ItemColor? = nil
    ) -> Route {
        guard stops.count >= 2, line.count >= 2 else {
            return Route(id: id, name: name, stops: stops, profileID: profileID, color: color)
        }
        let indices = cutIndices(of: line, at: stops.map(\.coordinate))
        var placed = stops
        for (stop, index) in indices.enumerated() {
            placed[stop].coordinate = line[index].coordinate
            placed[stop].elevation = line[index].elevation
        }
        let legs = zip(indices, indices.dropFirst()).map { start, end in
            RouteLeg(shape: start + 1 < end ? Array(line[(start + 1)..<end]) : [], method: .calculated, profileID: profileID)
        }
        return Route(id: id, name: name, stops: placed, legs: legs, profileID: profileID, color: color)
    }

    /// The whole line: each stop followed by the shape of the leg after it.
    public var points: [RoutePoint] {
        var result: [RoutePoint] = []
        result.reserveCapacity(stops.count + legs.reduce(0) { $0 + $1.shape.count })
        for (index, stop) in stops.enumerated() {
            result.append(stop.point)
            if index < legs.count {
                result += legs[index].shape
            }
        }
        return result
    }

    // MARK: Editing stops

    /// Moves a stop. The legs on either side no longer reach it, so they become straight, waiting for the router.
    public mutating func moveStop(at index: Int, to coordinate: Coordinate) {
        guard stops.indices.contains(index) else { return }
        stops[index].coordinate = coordinate
        stops[index].elevation = nil
        invalidateLegs(around: index)
    }

    /// Deletes a stop. Its two legs become one straight leg, waiting for the router.
    public mutating func removeStop(at index: Int) {
        guard stops.indices.contains(index) else { return }
        stops.remove(at: index)
        if legs.isEmpty { return }
        if index == 0 {
            legs.removeFirst()
        } else if index >= legs.count {
            legs.removeLast()
        } else {
            legs.remove(at: index)
            legs[index - 1] = changedLeg()
        }
    }

    /// Inserts a stop at `index` (0 for the start, `stops.count` for the end). The legs it splits or adds are
    /// straight, waiting for the router.
    public mutating func insertStop(_ stop: RouteStop, at index: Int) {
        let index = min(max(0, index), stops.count)
        stops.insert(stop, at: index)
        guard stops.count >= 2 else { return }
        if index == 0 {
            legs.insert(changedLeg(), at: 0)
        } else if index == stops.count - 1 {
            legs.append(changedLeg())
        } else {
            legs[index - 1] = changedLeg()
            legs.insert(changedLeg(), at: index)
        }
    }

    /// Changes a stop's name or kind, which leaves the line as it is.
    public mutating func updateStop(at index: Int, _ change: (inout RouteStop) -> Void) {
        guard stops.indices.contains(index) else { return }
        let id = stops[index].id
        let coordinate = stops[index].coordinate
        change(&stops[index])
        stops[index].id = id
        stops[index].coordinate = coordinate
    }

    /// Puts a leg the router calculated in place. Returns false when the stops at its ends are no longer where
    /// they were when it was asked for, so the result is stale.
    @discardableResult
    public mutating func setLeg(at index: Int, from start: RouteStop, to end: RouteStop, _ leg: RouteLeg) -> Bool {
        guard legs.indices.contains(index), stops[index] == start, stops[index + 1] == end else { return false }
        legs[index] = leg
        return true
    }

    /// The same route with each point of `points` replaced by the point at the same place in `updated`, which must
    /// have as many points. Used to put in heights read for the whole line.
    public func replacingPoints(_ updated: [RoutePoint]) -> Route? {
        guard updated.count == points.count else { return nil }
        var copy = self
        var next = 0
        for index in stops.indices {
            copy.stops[index].coordinate = updated[next].coordinate
            copy.stops[index].elevation = updated[next].elevation
            next += 1
            if index < legs.count {
                let count = legs[index].shape.count
                copy.legs[index].shape = Array(updated[next..<(next + count)])
                next += count
            }
        }
        return copy
    }

    /// The same route run the other way.
    public func reversed() -> Route {
        var copy = self
        copy.stops = stops.reversed()
        copy.legs = legs.reversed().map { leg in
            var reversed = leg
            reversed.shape = leg.shape.reversed()
            return reversed
        }
        return copy
    }

    /// Fewer shape points, each leg kept to within `tolerance` metres. Stops are kept.
    public func simplified(tolerance: Double) -> Route {
        var copy = self
        for index in legs.indices {
            let line = [stops[index].point] + legs[index].shape + [stops[index + 1].point]
            let kept = DouglasPeucker.simplify(line, tolerance: tolerance, coordinate: \.coordinate)
            copy.legs[index].shape = Array(kept.dropFirst().dropLast())
        }
        return copy
    }

    // MARK: Helpers

    private static func stop(_ point: RoutePoint) -> RouteStop {
        RouteStop(name: point.name, coordinate: point.coordinate, elevation: point.elevation)
    }

    private func changedLeg() -> RouteLeg {
        RouteLeg(method: .direct, profileID: profileID, needsRecalculation: profileID != nil)
    }

    private mutating func invalidateLegs(around index: Int) {
        if index > 0 {
            legs[index - 1] = changedLeg()
        }
        if index < legs.count {
            legs[index] = changedLeg()
        }
    }

    /// Where the line passes each stop, in order: the first point within 30 m of the stop after the previous
    /// stop's point, or else the nearest; the first and last stops are the line's ends.
    static func cutIndices(of line: [RoutePoint], at stops: [Coordinate]) -> [Int] {
        var indices = [0]
        for (number, stop) in stops.enumerated().dropFirst().dropLast() {
            let first = indices[indices.count - 1] + 1
            let last = line.count - 1 - (stops.count - 1 - number)
            guard first <= last else {
                indices.append(min(first, line.count - 1))
                continue
            }
            let window = first...last
            let close = window.first { Geodesy.distance(from: line[$0].coordinate, to: stop) <= 30 }
            let nearest = window.min {
                Geodesy.distance(from: line[$0].coordinate, to: stop) < Geodesy.distance(from: line[$1].coordinate, to: stop)
            }
            indices.append(close ?? nearest ?? first)
        }
        indices.append(line.count - 1)
        return indices
    }
}

extension Route: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, stops, legs, profileID, color
        /// Library version 1 kept a route as its points only.
        case points
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let name = try values.decode(String.self, forKey: .name)
        let color = try values.decodeIfPresent(ItemColor.self, forKey: .color)
        if let stops = try values.decodeIfPresent([RouteStop].self, forKey: .stops) {
            self.init(
                id: id, name: name, stops: stops,
                legs: try values.decodeIfPresent([RouteLeg].self, forKey: .legs),
                profileID: try values.decodeIfPresent(UUID.self, forKey: .profileID), color: color
            )
        } else {
            let points = try values.decodeIfPresent([RoutePoint].self, forKey: .points) ?? []
            self.init(id: id, name: name, points: points, color: color)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(stops, forKey: .stops)
        try values.encode(legs, forKey: .legs)
        try values.encodeIfPresent(profileID, forKey: .profileID)
        try values.encodeIfPresent(color, forKey: .color)
    }
}
