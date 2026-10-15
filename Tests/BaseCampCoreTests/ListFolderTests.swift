import XCTest
@testable import BaseCampCore

/// BaseCamp's organisation: lists in list folders, folders in folders, My Collection holding every item.
final class ListFolderTests: XCTestCase {
    private func track(_ name: String) -> Track {
        Track(name: name, segments: [[TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5))]])
    }

    func testOlderFilesHaveNoFoldersAndTheirListsAreAtTheTop() throws {
        let old = #"{"waypoints":[],"routes":[],"tracks":[],"collections":[{"id":"7D3C0F7A-6F55-4D8B-9C3E-2B1A0E9D4C11","name":"Day 1","items":[]}]}"#

        let library = try JSONDecoder().decode(Library.self, from: Data(old.utf8))

        XCTAssertTrue(library.folders.isEmpty)
        XCTAssertNil(library.collections[0].folderID)
        XCTAssertEqual(library.children(of: nil).lists.map(\.name), ["Day 1"])
    }

    func testFoldersHoldListsAndFolders() throws {
        var library = Library()
        let vercors = library.createFolder(in: nil, name: "Vercors")
        let rides = library.createFolder(in: vercors, name: "Rides")
        let list = library.createList(in: rides, name: "2026")
        let top = library.createList(in: nil)

        XCTAssertEqual(library.children(of: nil).folders.map(\.name), ["Vercors"])
        XCTAssertEqual(library.children(of: nil).lists.map(\.id), [top])
        XCTAssertEqual(library.children(of: vercors).folders.map(\.id), [rides])
        XCTAssertEqual(library.lists(inFolder: vercors).map(\.id), [list], "lists at any depth")

        let back = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(back, library)
    }

    func testNamesAreUniqueWithinAFolder() {
        var library = Library()
        let folder = library.createFolder(in: nil)
        let first = library.createList(in: nil)
        let second = library.createList(in: nil)
        _ = library.createList(in: folder)

        XCTAssertEqual(library.children(of: nil).lists.map(\.name), ["New List", "New List 2"])
        XCTAssertEqual(library.children(of: folder).lists.map(\.name), ["New List"], "another folder may have the same name")
        XCTAssertFalse(library.renameCollection(second, to: " new list "), "taken in this folder, whatever the case")
        XCTAssertFalse(library.moveList(first, to: folder), "the folder has a New List already")
        XCTAssertTrue(library.moveList(second, to: folder))
        XCTAssertFalse(library.renameFolder(folder, to: ""))
    }

    func testAFolderCannotGoIntoItself() {
        var library = Library()
        let outer = library.createFolder(in: nil, name: "Outer")
        let inner = library.createFolder(in: outer, name: "Inner")

        XCTAssertFalse(library.moveFolder(outer, to: outer))
        XCTAssertFalse(library.moveFolder(outer, to: inner))
        XCTAssertTrue(library.moveFolder(inner, to: nil))
    }

    func testItemsInNoListAreUnlisted() {
        let listed = track("Listed"), unlisted = track("Unlisted")
        var library = Library(tracks: [listed, unlisted])
        let list = library.createList(in: nil)
        library.add([.track(listed.id)], toList: list)

        XCTAssertEqual(library.unlistedItems, [.track(unlisted.id)])
        XCTAssertEqual(library.add([.track(listed.id)], toList: list), [.track(listed.id)], "already in the list")
        XCTAssertEqual(library.lists(containing: .track(listed.id)).map(\.id), [list])
    }

    func testRemovingAListKeepsItsItemsUnlessAskedToDeleteTheUniqueOnes() {
        let shared = track("Shared"), alone = track("Alone")
        var library = Library(tracks: [shared, alone])
        let first = library.createList(in: nil, items: [.track(shared.id), .track(alone.id)])
        _ = library.createList(in: nil, items: [.track(shared.id)])

        XCTAssertEqual(library.uniqueItems(ofList: first), [.track(alone.id)])
        var kept = library
        kept.removeList(first, deletingUniqueItems: false)
        XCTAssertEqual(kept.tracks.count, 2, "items stay in My Collection")

        library.removeList(first, deletingUniqueItems: true)
        XCTAssertEqual(library.tracks.map(\.name), ["Shared"])
    }

    func testRemovingAFolderRemovesWhatIsInside() {
        let a = track("A"), b = track("B")
        var library = Library(tracks: [a, b])
        let folder = library.createFolder(in: nil)
        let sub = library.createFolder(in: folder)
        _ = library.createList(in: sub, items: [.track(a.id)])
        _ = library.createList(in: nil, items: [.track(b.id)])

        XCTAssertEqual(library.uniqueItems(ofFolder: folder), [.track(a.id)])
        library.removeFolder(folder, deletingUniqueItems: true)

        XCTAssertTrue(library.folders.isEmpty)
        XCTAssertEqual(library.collections.count, 1)
        XCTAssertEqual(library.tracks.map(\.name), ["B"])
    }

    func testDuplicatingAListCanCopyItsItems() throws {
        let a = track("A")
        var library = Library(tracks: [a])
        let list = library.createList(in: nil, name: "Trip", items: [.track(a.id)])

        let sameItems = try XCTUnwrap(library.duplicateList(list, copyingItems: false))
        let copies = try XCTUnwrap(library.duplicateList(list, copyingItems: true))

        XCTAssertEqual(library.collections.first { $0.id == sameItems }?.items, [.track(a.id)])
        XCTAssertEqual(library.collections.first { $0.id == sameItems }?.name, "Trip copy")
        XCTAssertEqual(library.collections.first { $0.id == copies }?.name, "Trip copy 2")
        XCTAssertEqual(library.tracks.count, 2, "the copied list holds new items")
        XCTAssertNotEqual(library.collections.first { $0.id == copies }?.items, [.track(a.id)])
    }
}
