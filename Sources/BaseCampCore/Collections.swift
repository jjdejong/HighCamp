import Foundation

/// An item of the library that a collection can refer to.
public enum CollectionItem: Hashable, Codable, Sendable {
    case waypoint(UUID)
    case route(UUID)
    case track(UUID)
}

/// A named group of waypoints, routes and tracks. An item can be in several collections.
public struct LibraryCollection: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [CollectionItem]

    public init(id: UUID = UUID(), name: String, items: [CollectionItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}
