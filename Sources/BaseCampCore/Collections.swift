import Foundation

/// An item of the library that a collection can refer to.
public enum CollectionItem: Hashable, Codable, Sendable {
    case waypoint(UUID)
    case route(UUID)
    case track(UUID)
}

/// A list, as BaseCamp calls it: a named group of waypoints, routes and tracks of My Collection (the library).
/// An item can be in several lists. A list sits in a list folder, or at the top when `folderID` is nil.
public struct LibraryCollection: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [CollectionItem]
    /// The list folder it is in; nil at the top. Files saved before folders have none.
    public var folderID: UUID?

    public init(id: UUID = UUID(), name: String, items: [CollectionItem] = [], folderID: UUID? = nil) {
        self.id = id
        self.name = name
        self.items = items
        self.folderID = folderID
    }
}
