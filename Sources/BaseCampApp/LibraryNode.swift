import BaseCampCore
import Foundation

/// A place in the library tree, as BaseCamp's library pane has them: My Collection (every item), the list folders
/// and lists that organise it, the items in no list, and the folders of the connected device.
enum LibraryNode: Hashable {
    case myCollection
    case unlisted
    case folder(UUID)
    case list(UUID)
    case device(DeviceGroup.Kind)

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// Library items selected for deleting, and the list they were selected in, if any (see `LibraryStore.deleteSelection`).
struct ItemDeletion: Equatable {
    let items: Set<LibraryItem>
    let list: UUID?
}

/// New items made while a list folder was selected, waiting for a list in that folder.
struct ListChoice: Equatable {
    let items: [CollectionItem]
    let folder: UUID
}

extension LibraryItem {
    init(_ item: CollectionItem) {
        switch item {
        case .waypoint(let id): self = .waypoint(id)
        case .route(let id): self = .route(id)
        case .track(let id): self = .track(id)
        }
    }
}

extension CollectionItem {
    init(_ item: LibraryItem) {
        switch item {
        case .waypoint(let id): self = .waypoint(id)
        case .route(let id): self = .route(id)
        case .track(let id): self = .track(id)
        }
    }
}
