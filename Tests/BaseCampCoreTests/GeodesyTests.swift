import XCTest
@testable import BaseCampCore

final class GeodesyTests: XCTestCase {
    func testParisToLondonIsAboutThreeHundredFortyKilometres() {
        let paris = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let london = Coordinate(latitude: 51.5074, longitude: -0.1278)

        let meters = Geodesy.distance(from: paris, to: london)

        XCTAssertEqual(meters / 1000, 343.5, accuracy: 1)
    }

    func testOneDegreeOfLongitudeOnTheEquator() {
        let a = Coordinate(latitude: 0, longitude: 0)
        let b = Coordinate(latitude: 0, longitude: 1)

        // 2 * pi * 6371 km / 360 is about 111.19 km.
        XCTAssertEqual(Geodesy.distance(from: a, to: b) / 1000, 111.19, accuracy: 0.01)
    }

    func testRouteLengthSumsConsecutivePoints() {
        let route = Route(name: "Equator", points: [
            RoutePoint(coordinate: Coordinate(latitude: 0, longitude: 0)),
            RoutePoint(coordinate: Coordinate(latitude: 0, longitude: 1)),
            RoutePoint(coordinate: Coordinate(latitude: 0, longitude: 2)),
        ])

        XCTAssertEqual(route.lengthMeters / 1000, 222.39, accuracy: 0.02)
    }

    func testTrackLengthIgnoresGapsBetweenSegments() {
        let track = Track(name: "Two runs", segments: [
            [
                TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 0)),
                TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 1)),
            ],
            [
                TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 10)),
                TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 11)),
            ],
        ])

        XCTAssertEqual(track.lengthMeters / 1000, 222.39, accuracy: 0.02)
        XCTAssertEqual(track.pointCount, 4)
    }

    func testTimeSpanCoversFirstAndLastTimestamps() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let track = Track(name: "Timed", segments: [[
            TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 0), time: start.addingTimeInterval(60)),
            TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 1), time: start),
            TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 2)),
        ]])

        XCTAssertEqual(track.timeSpan, start...start.addingTimeInterval(60))
    }

    func testLibraryCoordinatesIncludeEveryItem() {
        let library = Library(
            waypoints: [Waypoint(name: "A", coordinate: Coordinate(latitude: 1, longitude: 1))],
            routes: [Route(name: "R", points: [RoutePoint(coordinate: Coordinate(latitude: 2, longitude: 2))])],
            tracks: [Track(name: "T", segments: [[TrackPoint(coordinate: Coordinate(latitude: 3, longitude: 3))]])]
        )

        XCTAssertEqual(library.coordinates.count, 3)
    }
}
