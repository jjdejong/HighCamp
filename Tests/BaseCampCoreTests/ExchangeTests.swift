import XCTest
@testable import BaseCampCore

final class ExchangeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleLibrary() -> Library {
        let points = (0..<4).map { index in
            TrackPoint(
                coordinate: Coordinate(latitude: 45 + Double(index) * 0.001, longitude: 5.5 + Double(index) * 0.001),
                elevation: 200 + Double(index),
                time: start.addingTimeInterval(Double(index) * 10)
            )
        }
        return Library(
            waypoints: [Waypoint(name: "Cafe, \"Le Bon\"", coordinate: Coordinate(latitude: 45.1, longitude: 5.7), elevation: 300, comment: "Open & late")],
            routes: [Route(name: "Loop", points: [
                RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 100),
                RoutePoint(coordinate: Coordinate(latitude: 45.01, longitude: 5.01)),
            ])],
            tracks: [Track(name: "Ride", segments: [points])]
        )
    }

    func testKMLRoundTripKeepsWaypointsAndLines() throws {
        let library = sampleLibrary()
        let data = KML.write(library)
        let back = try KML.read(data)
        XCTAssertEqual(back.waypoints.count, 1)
        XCTAssertEqual(back.waypoints[0].name, "Cafe, \"Le Bon\"")
        XCTAssertEqual(back.waypoints[0].comment, "Open & late")
        XCTAssertEqual(back.waypoints[0].coordinate.latitude, 45.1, accuracy: 1e-9)
        XCTAssertEqual(back.waypoints[0].elevation ?? -1, 300, accuracy: 1e-9)
        // Routes come back as tracks, one per placemark.
        XCTAssertEqual(back.tracks.count, 2)
        let ride = try XCTUnwrap(back.tracks.first { $0.name == "Ride" })
        XCTAssertEqual(ride.pointCount, 4)
        XCTAssertEqual(ride.segments[0][2].elevation ?? -1, 202, accuracy: 1e-9)
    }

    func testTCXCourseRoundTrip() throws {
        let route = sampleLibrary().routes[0]
        let data = TCX.course(name: route.name, points: route.coursePoints, start: start)
        let back = try TCX.read(data)
        XCTAssertEqual(back.tracks.count, 1)
        let track = back.tracks[0]
        XCTAssertEqual(track.name, "Loop")
        XCTAssertEqual(track.pointCount, 2)
        XCTAssertEqual(track.segments[0][0].coordinate.longitude, 5, accuracy: 1e-6)
        XCTAssertEqual(track.segments[0][0].elevation ?? -1, 100, accuracy: 1e-6)
    }

    func testTCXActivityReadsEveryLapTrack() throws {
        let xml = """
        <?xml version="1.0"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
        <Activities><Activity Sport="Biking"><Id>2026-10-13T08:00:00Z</Id>
        <Lap><Track>
          <Trackpoint><Time>2026-10-13T08:00:00Z</Time><Position><LatitudeDegrees>45</LatitudeDegrees><LongitudeDegrees>5</LongitudeDegrees></Position><AltitudeMeters>150</AltitudeMeters></Trackpoint>
          <Trackpoint><Time>2026-10-13T08:00:10Z</Time><Position><LatitudeDegrees>45.0001</LatitudeDegrees><LongitudeDegrees>5</LongitudeDegrees></Position></Trackpoint>
        </Track></Lap>
        <Lap><Track><Trackpoint><Time>2026-10-13T08:05:00Z</Time><Position><LatitudeDegrees>45.01</LatitudeDegrees><LongitudeDegrees>5.01</LongitudeDegrees></Position></Trackpoint></Track></Lap>
        </Activity></Activities></TrainingCenterDatabase>
        """
        let library = try TCX.read(Data(xml.utf8))
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].segments.count, 2)
        XCTAssertEqual(library.tracks[0].segments[0][0].elevation ?? -1, 150, accuracy: 1e-9)
        XCTAssertNotNil(library.tracks[0].segments[0][0].time)
        XCTAssertNil(library.tracks[0].segments[0][1].elevation)
    }

    func testCSVQuotesFieldsWithCommasAndQuotes() {
        let text = String(decoding: CSV.waypoints(sampleLibrary().waypoints), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Name,Latitude,Longitude,Elevation (m),Time,Symbol,Comment")
        XCTAssertTrue(lines[1].hasPrefix("\"Cafe, \"\"Le Bon\"\"\",45.100000,5.700000,300.0,,,Open & late"), lines[1])
    }

    func testKMLRejectsGarbage() {
        XCTAssertThrowsError(try KML.read(Data("not xml <".utf8)))
    }
}
