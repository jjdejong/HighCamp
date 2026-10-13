import Foundation

/// A WGS 84 position in decimal degrees.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct Waypoint: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var coordinate: Coordinate
    public var elevation: Double?
    public var time: Date?
    public var comment: String?
    public var symbol: String?

    public init(
        id: UUID = UUID(),
        name: String,
        coordinate: Coordinate,
        elevation: Double? = nil,
        time: Date? = nil,
        comment: String? = nil,
        symbol: String? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.elevation = elevation
        self.time = time
        self.comment = comment
        self.symbol = symbol
    }
}

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

public struct Route: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var points: [RoutePoint]

    public init(id: UUID = UUID(), name: String, points: [RoutePoint] = []) {
        self.id = id
        self.name = name
        self.points = points
    }
}

public struct TrackPoint: Equatable, Codable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?
    public var time: Date?

    public init(coordinate: Coordinate, elevation: Double? = nil, time: Date? = nil) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.time = time
    }
}

public struct Track: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Each segment is a contiguous run of points. GPX allows gaps between segments.
    public var segments: [[TrackPoint]]

    public init(id: UUID = UUID(), name: String, segments: [[TrackPoint]] = []) {
        self.id = id
        self.name = name
        self.segments = segments
    }
}

/// The contents of one planning file: waypoints, routes, tracks and the collections that group them.
public struct Library: Equatable, Codable, Sendable {
    public var waypoints: [Waypoint]
    public var routes: [Route]
    public var tracks: [Track]
    public var collections: [LibraryCollection]

    public init(waypoints: [Waypoint] = [], routes: [Route] = [], tracks: [Track] = [], collections: [LibraryCollection] = []) {
        self.waypoints = waypoints
        self.routes = routes
        self.tracks = tracks
        self.collections = collections
    }

    /// Files saved before collections existed have none.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        waypoints = try values.decodeIfPresent([Waypoint].self, forKey: .waypoints) ?? []
        routes = try values.decodeIfPresent([Route].self, forKey: .routes) ?? []
        tracks = try values.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        collections = try values.decodeIfPresent([LibraryCollection].self, forKey: .collections) ?? []
    }

    public var isEmpty: Bool {
        waypoints.isEmpty && routes.isEmpty && tracks.isEmpty
    }

    /// Renames a collection. Returns false when there is no such collection or the name is blank.
    @discardableResult
    public mutating func renameCollection(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        collections[index].name = trimmed
        return true
    }

    /// Removes the references to items that are no longer in the library, from every collection.
    public mutating func pruneCollections() {
        let waypointIDs = Set(waypoints.map(\.id))
        let routeIDs = Set(routes.map(\.id))
        let trackIDs = Set(tracks.map(\.id))
        for index in collections.indices {
            collections[index].items.removeAll { item in
                switch item {
                case .waypoint(let id): !waypointIDs.contains(id)
                case .route(let id): !routeIDs.contains(id)
                case .track(let id): !trackIDs.contains(id)
                }
            }
        }
    }

    /// Adds every item from `other`. Items keep their identifiers.
    public mutating func merge(_ other: Library) {
        waypoints.append(contentsOf: other.waypoints)
        routes.append(contentsOf: other.routes)
        tracks.append(contentsOf: other.tracks)
    }
}
