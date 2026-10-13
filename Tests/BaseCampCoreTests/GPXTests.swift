import XCTest
@testable import BaseCampCore

final class GPXTests: XCTestCase {
    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
      <metadata><name>Sample file</name></metadata>
      <wpt lat="48.8584" lon="2.2945">
        <ele>35.0</ele>
        <time>2024-05-01T12:00:00Z</time>
        <name>Tower</name>
        <cmt>Meet here</cmt>
        <sym>Flag</sym>
        <extensions><vendor>ignored</vendor></extensions>
      </wpt>
      <rte>
        <name>Morning loop</name>
        <rtept lat="48.85" lon="2.35"><name>Start</name></rtept>
        <rtept lat="48.86" lon="2.36"></rtept>
      </rte>
      <trk>
        <name>Ride</name>
        <trkseg>
          <trkpt lat="48.85" lon="2.35"><ele>30</ele><time>2024-05-01T08:00:00.500Z</time></trkpt>
          <trkpt lat="48.851" lon="2.351"/>
        </trkseg>
      </trk>
    </gpx>
    """

    func testReadsWaypointRouteAndTrack() throws {
        let library = try GPX.read(Data(sample.utf8))

        XCTAssertEqual(library.waypoints.count, 1)
        let waypoint = try XCTUnwrap(library.waypoints.first)
        XCTAssertEqual(waypoint.name, "Tower")
        XCTAssertEqual(waypoint.coordinate.latitude, 48.8584, accuracy: 1e-9)
        XCTAssertEqual(waypoint.coordinate.longitude, 2.2945, accuracy: 1e-9)
        XCTAssertEqual(waypoint.elevation, 35.0)
        XCTAssertEqual(waypoint.comment, "Meet here")
        XCTAssertEqual(waypoint.symbol, "Flag")
        XCTAssertNotNil(waypoint.time)

        XCTAssertEqual(library.routes.count, 1)
        let route = try XCTUnwrap(library.routes.first)
        XCTAssertEqual(route.name, "Morning loop")
        XCTAssertEqual(route.points.count, 2)
        XCTAssertEqual(route.points[0].name, "Start")
        XCTAssertNil(route.points[1].name)

        XCTAssertEqual(library.tracks.count, 1)
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(track.name, "Ride")
        XCTAssertEqual(track.segments.count, 1)
        XCTAssertEqual(track.segments[0].count, 2)
        XCTAssertEqual(track.segments[0][0].elevation, 30)
        XCTAssertNotNil(track.segments[0][0].time, "fractional-second timestamps should parse")
        XCTAssertNil(track.segments[0][1].elevation)
    }

    func testRoundTripPreservesContent() throws {
        let original = Library(
            waypoints: [
                Waypoint(
                    name: "Camp",
                    coordinate: Coordinate(latitude: 45.5, longitude: 6.25),
                    elevation: 1200,
                    time: Date(timeIntervalSince1970: 1_700_000_000),
                    comment: "Water here",
                    symbol: "Campground"
                ),
            ],
            routes: [
                Route(name: "Way out", points: [
                    RoutePoint(name: "A", coordinate: Coordinate(latitude: 45.5, longitude: 6.25)),
                    RoutePoint(coordinate: Coordinate(latitude: 45.6, longitude: 6.3)),
                ]),
            ],
            tracks: [
                Track(name: "Hike", segments: [
                    [
                        TrackPoint(coordinate: Coordinate(latitude: 45.5, longitude: 6.25), elevation: 1200),
                        TrackPoint(coordinate: Coordinate(latitude: 45.51, longitude: 6.26)),
                    ],
                    [TrackPoint(coordinate: Coordinate(latitude: 45.52, longitude: 6.27))],
                ]),
            ]
        )

        let read = try GPX.read(GPX.write(original))

        XCTAssertEqual(read.waypoints.map(\.name), ["Camp"])
        XCTAssertEqual(read.waypoints[0].comment, "Water here")
        XCTAssertEqual(read.waypoints[0].time, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(read.routes.map(\.name), ["Way out"])
        XCTAssertEqual(read.routes[0].points.count, 2)
        XCTAssertEqual(read.tracks.map(\.name), ["Hike"])
        XCTAssertEqual(read.tracks[0].segments.map(\.count), [2, 1])
        XCTAssertEqual(read.tracks[0].segments[0][0].elevation, 1200)
    }

    func testEscapesSpecialCharacters() throws {
        let original = Library(waypoints: [
            Waypoint(name: "Fish & chips <\"best\">", coordinate: Coordinate(latitude: 1, longitude: 2), comment: "A & B"),
        ])

        let read = try GPX.read(GPX.write(original))

        XCTAssertEqual(read.waypoints.first?.name, "Fish & chips <\"best\">")
        XCTAssertEqual(read.waypoints.first?.comment, "A & B")
    }

    func testRejectsOutOfRangeCoordinate() {
        let xml = #"<gpx xmlns="http://www.topografix.com/GPX/1/1"><wpt lat="91" lon="0"><name>Bad</name></wpt></gpx>"#

        XCTAssertThrowsError(try GPX.read(Data(xml.utf8))) { error in
            XCTAssertEqual(error as? GPXError, .invalidCoordinate(element: "wpt"))
        }
    }

    func testRejectsMissingCoordinate() {
        let xml = #"<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg><trkpt lat="10"/></trkseg></trk></gpx>"#

        XCTAssertThrowsError(try GPX.read(Data(xml.utf8))) { error in
            XCTAssertEqual(error as? GPXError, .missingCoordinate(element: "trkpt"))
        }
    }

    func testRejectsMalformedXML() {
        let xml = "<gpx><wpt lat=\"1\" lon=\"2\"></gpx>"

        XCTAssertThrowsError(try GPX.read(Data(xml.utf8))) { error in
            guard case .malformedXML = error as? GPXError else {
                return XCTFail("expected malformedXML, got \(error)")
            }
        }
    }
}
