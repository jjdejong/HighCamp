import XCTest
@testable import BaseCampCore

final class CollectionEditTests: XCTestCase {
    private let origin = Coordinate(latitude: 45, longitude: 5)

    private func track(_ name: String) -> Track {
        Track(name: name, segments: [[TrackPoint(coordinate: origin)]])
    }

    func testCombineReplacesTheTracksInEveryCollection() throws {
        let a = track("A"), b = track("B"), c = track("C")
        var library = Library(tracks: [a, b, c], collections: [
            LibraryCollection(name: "Day", items: [.track(c.id), .track(a.id)]),
            LibraryCollection(name: "Other", items: [.track(b.id)]),
        ])
        let combined = Track.combined([a, b], name: "A")

        XCTAssertTrue(library.combineTracks([a.id, b.id], into: combined))

        XCTAssertEqual(library.tracks.map(\.id), [combined.id, c.id])
        XCTAssertEqual(library.collections[0].items, [.track(c.id), .track(combined.id)])
        XCTAssertEqual(library.collections[1].items, [.track(combined.id)])
    }

    func testCombineKeepsTheResultWhereTheFirstTrackWasInTheLibrary() {
        let a = track("A"), b = track("B"), c = track("C")
        var library = Library(tracks: [c, a, b])
        let combined = Track.combined([a, b], name: "A")

        XCTAssertTrue(library.combineTracks([a.id, b.id], into: combined))

        XCTAssertEqual(library.tracks.map(\.id), [c.id, combined.id])
    }

    func testCombineWithAnUnknownTrackChangesNothing() {
        let a = track("A")
        var library = Library(tracks: [a])
        let before = library

        XCTAssertFalse(library.combineTracks([UUID(), a.id], into: Track.combined([a], name: "A")))

        XCTAssertEqual(library, before)
    }

    func testSplitPutBothPiecesWhereTheTrackWas() {
        let whole = track("Whole"), w = Waypoint(name: "Cafe", coordinate: origin)
        let first = track("Whole (1)"), second = track("Whole (2)")
        var library = Library(waypoints: [w], tracks: [whole], collections: [
            LibraryCollection(name: "Trip", items: [.waypoint(w.id), .track(whole.id)]),
        ])

        XCTAssertTrue(library.splitTrack(whole.id, into: (first, second)))

        XCTAssertEqual(library.tracks.map(\.id), [first.id, second.id])
        XCTAssertEqual(library.collections[0].items, [.waypoint(w.id), .track(first.id), .track(second.id)])
    }

    func testConvertingATrackToARouteReplacesItInCollections() {
        let whole = track("Ride"), w = Waypoint(name: "Cafe", coordinate: origin)
        let route = Route(name: "Ride", points: [RoutePoint(coordinate: origin)])
        var library = Library(waypoints: [w], tracks: [whole], collections: [
            LibraryCollection(name: "Trip", items: [.track(whole.id), .waypoint(w.id)]),
        ])

        XCTAssertTrue(library.convertTrack(whole.id, to: route))

        XCTAssertTrue(library.tracks.isEmpty)
        XCTAssertEqual(library.routes.map(\.id), [route.id])
        XCTAssertEqual(library.collections[0].items, [.route(route.id), .waypoint(w.id)])
    }

    func testConvertingARouteToATrackReplacesItInCollections() {
        let route = Route(name: "Loop", points: [RoutePoint(coordinate: origin)])
        let whole = track("Loop")
        var library = Library(routes: [route], collections: [
            LibraryCollection(name: "Trip", items: [.route(route.id)]),
        ])

        XCTAssertTrue(library.convertRoute(route.id, to: whole))

        XCTAssertTrue(library.routes.isEmpty)
        XCTAssertEqual(library.tracks.map(\.id), [whole.id])
        XCTAssertEqual(library.collections[0].items, [.track(whole.id)])
    }

    func testConvertWithAnUnknownItemChangesNothing() {
        var library = Library(collections: [LibraryCollection(name: "Trip", items: [.route(UUID())])])
        let before = library

        XCTAssertFalse(library.convertTrack(UUID(), to: Route(name: "X")))
        XCTAssertFalse(library.convertRoute(UUID(), to: track("X")))
        XCTAssertFalse(library.splitTrack(UUID(), into: (track("1"), track("2"))))

        XCTAssertEqual(library, before)
    }
}
