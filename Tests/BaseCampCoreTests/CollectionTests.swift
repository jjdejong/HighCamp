import Foundation
import XCTest
@testable import BaseCampCore

final class CollectionTests: XCTestCase {
    func testLibraryWithCollectionsRoundTrips() throws {
        let waypoint = Waypoint(name: "Cafe", coordinate: Coordinate(latitude: 45, longitude: 5))
        let collection = LibraryCollection(name: "Day 1", items: [.waypoint(waypoint.id)])
        let library = Library(waypoints: [waypoint], collections: [collection])
        let data = try JSONEncoder().encode(library)
        let back = try JSONDecoder().decode(Library.self, from: data)
        XCTAssertEqual(back, library)
        XCTAssertEqual(back.collections.first?.name, "Day 1")
    }

    func testOlderFilesWithoutCollectionsStillLoad() throws {
        let json = #"{"waypoints":[],"routes":[],"tracks":[]}"#
        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        XCTAssertTrue(library.collections.isEmpty)
    }

    func testPruneRemovesReferencesToMissingItems() {
        let kept = Waypoint(name: "Kept", coordinate: Coordinate(latitude: 45, longitude: 5))
        let gone = UUID()
        var library = Library(waypoints: [kept], collections: [
            LibraryCollection(name: "Mixed", items: [.waypoint(kept.id), .waypoint(gone), .track(gone)]),
        ])
        library.pruneCollections()
        XCTAssertEqual(library.collections[0].items, [.waypoint(kept.id)])
    }

    func testRenameTrimsAndRejectsBlankNames() {
        let collection = LibraryCollection(name: "Day 1")
        var library = Library(collections: [collection])
        XCTAssertTrue(library.renameCollection(collection.id, to: "  Day 2 \n"))
        XCTAssertEqual(library.collections[0].name, "Day 2")
        XCTAssertFalse(library.renameCollection(collection.id, to: "   "))
        XCTAssertEqual(library.collections[0].name, "Day 2")
        XCTAssertFalse(library.renameCollection(UUID(), to: "Other"))
    }
}
