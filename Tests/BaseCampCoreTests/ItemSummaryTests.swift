import XCTest
@testable import BaseCampCore

final class ItemSummaryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testEachKindHasItsOwnFigures() {
        let waypoint = Waypoint(name: "Cafe", coordinate: Coordinate(latitude: 45, longitude: 5), time: start)
        let route = Route(name: "Loop", points: [
            RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 100),
            RoutePoint(coordinate: Coordinate(latitude: 45.01, longitude: 5), elevation: 150),
            RoutePoint(coordinate: Coordinate(latitude: 45.02, longitude: 5), elevation: 120),
        ])
        let track = Track(name: "Ride", segments: [[
            TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 100, time: start),
            TrackPoint(coordinate: Coordinate(latitude: 45.01, longitude: 5), elevation: 150, time: start.addingTimeInterval(600)),
            TrackPoint(coordinate: Coordinate(latitude: 45.02, longitude: 5), elevation: 120, time: start.addingTimeInterval(1200)),
        ]])

        let summaries = Library(waypoints: [waypoint], routes: [route], tracks: [track]).itemSummaries

        XCTAssertEqual(summaries.map(\.kind), [.waypoint, .route, .track])
        XCTAssertEqual(summaries.map(\.name), ["Cafe", "Loop", "Ride"])

        XCTAssertNil(summaries[0].lengthMeters)
        XCTAssertEqual(summaries[0].date, start)
        XCTAssertNil(summaries[0].ascentMeters)

        XCTAssertEqual(summaries[1].lengthMeters ?? -1, route.lengthMeters, accuracy: 1e-9)
        XCTAssertNil(summaries[1].date)
        XCTAssertEqual(summaries[1].ascentMeters ?? -1, 50, accuracy: 1)

        XCTAssertEqual(summaries[2].lengthMeters ?? -1, track.lengthMeters, accuracy: 1e-9)
        XCTAssertEqual(summaries[2].date, start)
        XCTAssertEqual(summaries[2].ascentMeters ?? -1, 50, accuracy: 1)
    }

    func testTrackWithoutHeightsHasNoAscent() {
        let track = Track(name: "Flat", segments: [[
            TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5)),
            TrackPoint(coordinate: Coordinate(latitude: 45.01, longitude: 5)),
        ]])

        XCTAssertNil(Library(tracks: [track]).itemSummaries[0].ascentMeters)
    }

    func testMissingLengthsSortFirst() {
        let short = Route(name: "Short", points: [
            RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5)),
            RoutePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5)),
        ])
        let waypoint = Waypoint(name: "Cafe", coordinate: Coordinate(latitude: 45, longitude: 5))

        let sorted = Library(waypoints: [waypoint], routes: [short]).itemSummaries
            .sorted(using: KeyPathComparator(\ItemSummary.lengthMeters))

        XCTAssertEqual(sorted.map(\.name), ["Cafe", "Short"])
    }
}
