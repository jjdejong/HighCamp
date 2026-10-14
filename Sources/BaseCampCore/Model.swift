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
    /// The proximity alarm distance in metres, as Garmin's GPX extension gives it. Nil when none is set.
    public var proximity: Double?
    /// The place's address and phone number. Nil when none is set. Files from before these fields have none.
    public var address: WaypointAddress?

    public init(
        id: UUID = UUID(),
        name: String,
        coordinate: Coordinate,
        elevation: Double? = nil,
        time: Date? = nil,
        comment: String? = nil,
        symbol: String? = nil,
        proximity: Double? = nil,
        address: WaypointAddress? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.elevation = elevation
        self.time = time
        self.comment = comment
        self.symbol = symbol
        self.proximity = proximity
        self.address = address
    }
}

/// A waypoint's address and phone number, as Garmin's GPX waypoint extension holds them. Each part is optional.
public struct WaypointAddress: Equatable, Codable, Sendable {
    public var street: String?
    public var city: String?
    public var state: String?
    public var postalCode: String?
    public var country: String?
    public var phone: String?

    public init(
        street: String? = nil,
        city: String? = nil,
        state: String? = nil,
        postalCode: String? = nil,
        country: String? = nil,
        phone: String? = nil
    ) {
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.phone = phone
    }
}

/// The colour an item is drawn in on the map. Components run from 0 to 1.
public struct ItemColor: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct TrackPoint: Equatable, Codable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?
    public var time: Date?
    /// Sensor readings from the device, where it recorded them. Files from before these fields have none.
    public var heartRate: Double?
    /// Revolutions per minute.
    public var cadence: Double?
    /// Watts.
    public var power: Double?
    /// Degrees Celsius.
    public var temperature: Double?

    public init(
        coordinate: Coordinate,
        elevation: Double? = nil,
        time: Date? = nil,
        heartRate: Double? = nil,
        cadence: Double? = nil,
        power: Double? = nil,
        temperature: Double? = nil
    ) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.time = time
        self.heartRate = heartRate
        self.cadence = cadence
        self.power = power
        self.temperature = temperature
    }
}

public struct Track: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Each segment is a contiguous run of points. GPX allows gaps between segments.
    public var segments: [[TrackPoint]]
    /// The colour the track is drawn in. Nil means the default colour. Files from before colours have none.
    public var color: ItemColor?

    public init(id: UUID = UUID(), name: String, segments: [[TrackPoint]] = [], color: ItemColor? = nil) {
        self.id = id
        self.name = name
        self.segments = segments
        self.color = color
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

    /// The name for a new collection: the lowest "Collection N" that no collection uses yet.
    public func nextCollectionName() -> String {
        let used = Set(collections.map(\.name))
        var number = 1
        while used.contains("Collection \(number)") { number += 1 }
        return "Collection \(number)"
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
