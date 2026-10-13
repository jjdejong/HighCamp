import Foundation

/// One row of the items table. Lengths and ascent are in metres. A figure is nil when it does not apply
/// (a waypoint has no length) or when the data is missing (a track without heights has no ascent).
public struct ItemSummary: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case waypoint = "Waypoint"
        case route = "Route"
        case track = "Track"
    }

    public var kind: Kind
    public var id: UUID
    public var name: String
    public var lengthMeters: Double?
    public var date: Date?
    public var ascentMeters: Double?
}

public extension Library {
    /// One summary for every waypoint, route and track: waypoints first, then routes, then tracks, each in library order.
    var itemSummaries: [ItemSummary] {
        waypoints.map {
            ItemSummary(kind: .waypoint, id: $0.id, name: $0.name, lengthMeters: nil, date: $0.time, ascentMeters: nil)
        } + routes.map {
            ItemSummary(kind: .route, id: $0.id, name: $0.name, lengthMeters: $0.lengthMeters, date: nil, ascentMeters: $0.statistics.ascentMeters)
        } + tracks.map {
            ItemSummary(kind: .track, id: $0.id, name: $0.name, lengthMeters: $0.lengthMeters, date: $0.timeSpan?.lowerBound, ascentMeters: $0.statistics.ascentMeters)
        }
    }
}
