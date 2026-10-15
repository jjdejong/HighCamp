import Foundation

/// A list folder, as BaseCamp has them: it holds lists and other list folders, never items. At the top when
/// `parentID` is nil.
public struct ListFolder: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

/// BaseCamp's organisation of My Collection: lists, list folders, and the items in no list ("Unlisted Data").
public extension Library {
    // MARK: The tree

    /// The folders and lists directly in a folder (nil: at the top), each by name.
    func children(of folder: UUID?) -> (folders: [ListFolder], lists: [LibraryCollection]) {
        let byName = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        return (
            folders.filter { $0.parentID == folder }.sorted { byName($0.name, $1.name) },
            collections.filter { $0.folderID == folder }.sorted { byName($0.name, $1.name) }
        )
    }

    /// A folder and every folder inside it, at any depth.
    func folderTree(_ id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var added = true
        while added {
            added = false
            for folder in folders where folder.parentID.map(found.contains) == true && !found.contains(folder.id) {
                found.insert(folder.id)
                added = true
            }
        }
        return found
    }

    /// The lists in a folder, at any depth.
    func lists(inFolder id: UUID) -> [LibraryCollection] {
        let tree = folderTree(id)
        return collections.filter { $0.folderID.map(tree.contains) == true }
    }

    /// The items of the lists in a folder, at any depth.
    func items(inFolder id: UUID) -> Set<CollectionItem> {
        Set(lists(inFolder: id).flatMap(\.items))
    }

    /// Items in My Collection that are in no list: BaseCamp's "Unlisted Data".
    var unlistedItems: Set<CollectionItem> {
        let listed = Set(collections.flatMap(\.items))
        return Set(allItems).subtracting(listed)
    }

    /// Every item of My Collection.
    var allItems: [CollectionItem] {
        waypoints.map { .waypoint($0.id) } + routes.map { .route($0.id) } + tracks.map { .track($0.id) }
    }

    /// The lists an item is in, by name.
    func lists(containing item: CollectionItem) -> [LibraryCollection] {
        collections.filter { $0.items.contains(item) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Names

    /// Whether a list (or, with `folder`, a folder) of this name is already in the folder `parent`, other than `id`.
    /// BaseCamp keeps the names of lists, and of folders, unique within a folder.
    func nameIsTaken(_ name: String, in parent: UUID?, folder: Bool, except id: UUID? = nil) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if folder {
            return folders.contains { $0.parentID == parent && $0.id != id && $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        return collections.contains { $0.folderID == parent && $0.id != id && $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// `base` when free in `parent`, else "base 2", "base 3"…
    func freeName(_ base: String, in parent: UUID?, folder: Bool) -> String {
        guard nameIsTaken(base, in: parent, folder: folder) else { return base }
        var number = 2
        while nameIsTaken("\(base) \(number)", in: parent, folder: folder) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Changes

    /// Adds a list named "New List" (numbered if taken) to a folder, and returns it.
    @discardableResult
    mutating func createList(in folder: UUID?, name: String = "New List", items: [CollectionItem] = []) -> UUID {
        let list = LibraryCollection(name: freeName(name, in: folder, folder: false), items: items, folderID: folder)
        collections.append(list)
        return list.id
    }

    /// Adds a list folder named "New Folder" (numbered if taken) to a folder, and returns it.
    @discardableResult
    mutating func createFolder(in parent: UUID?, name: String = "New Folder") -> UUID {
        let folder = ListFolder(name: freeName(name, in: parent, folder: true), parentID: parent)
        folders.append(folder)
        return folder.id
    }

    /// Renames a folder. False when the name is blank or another folder beside it has it.
    @discardableResult
    mutating func renameFolder(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }),
              !nameIsTaken(trimmed, in: folders[index].parentID, folder: true, except: id) else { return false }
        folders[index].name = trimmed
        return true
    }

    /// Moves a list into a folder (nil: to the top). False when a list of the same name is there already.
    @discardableResult
    mutating func moveList(_ id: UUID, to folder: UUID?) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == id }),
              folder == nil || folders.contains(where: { $0.id == folder }),
              !nameIsTaken(collections[index].name, in: folder, folder: false, except: id) else { return false }
        collections[index].folderID = folder
        return true
    }

    /// Moves a folder into another (nil: to the top). False for a move into itself or a folder inside it, or when
    /// a folder of the same name is there already.
    @discardableResult
    mutating func moveFolder(_ id: UUID, to parent: UUID?) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }),
              parent.map({ !folderTree(id).contains($0) }) ?? true,
              parent == nil || folders.contains(where: { $0.id == parent }),
              !nameIsTaken(folders[index].name, in: parent, folder: true, except: id) else { return false }
        folders[index].parentID = parent
        return true
    }

    /// Adds items to a list, each once. Returns the items that were in it already.
    @discardableResult
    mutating func add(_ items: [CollectionItem], toList id: UUID) -> [CollectionItem] {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return [] }
        var already: [CollectionItem] = []
        for item in items {
            if collections[index].items.contains(item) {
                already.append(item)
            } else {
                collections[index].items.append(item)
            }
        }
        return already
    }

    /// Takes items out of a list. They stay in My Collection.
    mutating func remove(_ items: Set<CollectionItem>, fromList id: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].items.removeAll { items.contains($0) }
    }

    /// The items of a list that are in no other list: those that would be left only in My Collection without it.
    func uniqueItems(ofList id: UUID) -> Set<CollectionItem> {
        guard let list = collections.first(where: { $0.id == id }) else { return [] }
        let elsewhere = Set(collections.filter { $0.id != id }.flatMap(\.items))
        return Set(list.items).subtracting(elsewhere)
    }

    /// The items of a folder's lists that are in no list outside it.
    func uniqueItems(ofFolder id: UUID) -> Set<CollectionItem> {
        let inside = Set(lists(inFolder: id).map(\.id))
        let elsewhere = Set(collections.filter { !inside.contains($0.id) }.flatMap(\.items))
        return items(inFolder: id).subtracting(elsewhere)
    }

    /// Removes a list. Its items stay in My Collection, unless `deletingUniqueItems`: then those in no other list
    /// are deleted from My Collection too.
    mutating func removeList(_ id: UUID, deletingUniqueItems: Bool) {
        let unique = deletingUniqueItems ? uniqueItems(ofList: id) : []
        collections.removeAll { $0.id == id }
        deleteItems(unique)
    }

    /// Removes a folder with the folders and lists inside it. Their items stay in My Collection, unless
    /// `deletingUniqueItems`: then those in no list outside the folder are deleted too.
    mutating func removeFolder(_ id: UUID, deletingUniqueItems: Bool) {
        let unique = deletingUniqueItems ? uniqueItems(ofFolder: id) : []
        let tree = folderTree(id)
        collections.removeAll { $0.folderID.map(tree.contains) == true }
        folders.removeAll { tree.contains($0.id) }
        deleteItems(unique)
    }

    /// A copy of a list beside it, named "… copy". With `copyingItems`, its items are duplicated in My Collection
    /// and the copy holds the duplicates; else it holds the same items. Returns the copy.
    @discardableResult
    mutating func duplicateList(_ id: UUID, copyingItems: Bool) -> UUID? {
        guard let list = collections.first(where: { $0.id == id }) else { return nil }
        var items = list.items
        if copyingItems {
            items = list.items.compactMap { item -> CollectionItem? in
                switch item {
                case .waypoint(let id):
                    guard var copy = waypoints.first(where: { $0.id == id }) else { return nil }
                    copy.id = UUID()
                    waypoints.append(copy)
                    return .waypoint(copy.id)
                case .route(let id):
                    guard var copy = routes.first(where: { $0.id == id }) else { return nil }
                    copy.id = UUID()
                    routes.append(copy)
                    return .route(copy.id)
                case .track(let id):
                    guard var copy = tracks.first(where: { $0.id == id }) else { return nil }
                    copy.id = UUID()
                    tracks.append(copy)
                    return .track(copy.id)
                }
            }
        }
        return createList(in: list.folderID, name: "\(list.name) copy", items: items)
    }

    /// Deletes items from My Collection, and so from every list.
    mutating func deleteItems(_ items: Set<CollectionItem>) {
        guard !items.isEmpty else { return }
        waypoints.removeAll { items.contains(.waypoint($0.id)) }
        routes.removeAll { items.contains(.route($0.id)) }
        tracks.removeAll { items.contains(.track($0.id)) }
        pruneCollections()
    }
}
