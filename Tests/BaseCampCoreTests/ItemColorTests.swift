import XCTest
@testable import BaseCampCore

final class ItemColorTests: XCTestCase {
    private let green = ItemColor(red: 0.1, green: 0.6, blue: 0.2)
    private let origin = Coordinate(latitude: 45, longitude: 5)

    func testColoursRoundTripWithTheLibrary() throws {
        let library = Library(
            routes: [Route(name: "Loop", points: [RoutePoint(coordinate: origin)], color: green)],
            tracks: [Track(name: "Ride", segments: [[TrackPoint(coordinate: origin)]], color: green)]
        )

        let back = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))

        XCTAssertEqual(back, library)
        XCTAssertEqual(back.routes.first?.color, green)
        XCTAssertEqual(back.tracks.first?.color, green)
    }

    func testLibraryFilesWithoutColoursStillLoad() throws {
        let json = """
        {"waypoints":[],
         "routes":[{"id":"6F1C2B1E-3A4D-4E5F-9A0B-1C2D3E4F5A6B","name":"Loop","points":[]}],
         "tracks":[{"id":"7F1C2B1E-3A4D-4E5F-9A0B-1C2D3E4F5A6B","name":"Ride","segments":[]}]}
        """

        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))

        XCTAssertNil(library.routes.first?.color)
        XCTAssertNil(library.tracks.first?.color)
    }

    func testCombiningKeepsTheFirstTracksColour() {
        let first = Track(name: "A", segments: [[TrackPoint(coordinate: origin)]], color: green)
        let second = Track(name: "B", segments: [[TrackPoint(coordinate: origin)]])

        XCTAssertEqual(Track.combined([first, second], name: "A").color, green)
    }

    func testSplitPiecesKeepTheColour() throws {
        let track = Track(name: "Ride", segments: [[
            TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5)),
            TrackPoint(coordinate: Coordinate(latitude: 45.01, longitude: 5)),
            TrackPoint(coordinate: Coordinate(latitude: 45.02, longitude: 5)),
        ]], color: green)

        let (first, second) = try XCTUnwrap(track.split(nearest: Coordinate(latitude: 45.01, longitude: 5)))

        XCTAssertEqual(first.color, green)
        XCTAssertEqual(second.color, green)
    }

    func testConvertingKeepsTheColour() {
        let track = Track(name: "Ride", segments: [[TrackPoint(coordinate: origin)]], color: green)
        let route = Route(name: "Loop", points: [RoutePoint(coordinate: origin)], color: green)

        XCTAssertEqual(track.asRoute().color, green)
        XCTAssertEqual(route.asTrack().color, green)
    }

    func testReversingAndSimplifyingKeepTheColour() {
        let route = Route(name: "Loop", points: [RoutePoint(coordinate: origin), RoutePoint(coordinate: origin)], color: green)
        let track = Track(name: "Ride", segments: [[TrackPoint(coordinate: origin)]], color: green)

        XCTAssertEqual(route.reversed().color, green)
        XCTAssertEqual(route.simplified(tolerance: 1).color, green)
        XCTAssertEqual(track.reversed().color, green)
        XCTAssertEqual(track.simplified(tolerance: 1).color, green)
    }
}
