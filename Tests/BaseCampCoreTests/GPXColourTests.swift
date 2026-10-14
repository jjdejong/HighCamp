import XCTest
@testable import BaseCampCore

final class GPXColourTests: XCTestCase {
    private let header = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3">
    """

    private func track(colour: String) -> Data {
        Data("""
        \(header)
          <trk>
            <name>Ride</name>
            <extensions><gpxx:TrackExtension><gpxx:DisplayColor>\(colour)</gpxx:DisplayColor></gpxx:TrackExtension></extensions>
            <trkseg><trkpt lat="45.0" lon="5.0"><ele>300</ele></trkpt><trkpt lat="45.001" lon="5.0"/></trkseg>
          </trk>
        </gpx>
        """.utf8)
    }

    private func route(colour: String) -> Data {
        Data("""
        \(header)
          <rte>
            <name>Loop</name>
            <extensions><gpxx:RouteExtension><gpxx:DisplayColor>\(colour)</gpxx:DisplayColor></gpxx:RouteExtension></extensions>
            <rtept lat="45.0" lon="5.0"><name>A</name></rtept>
            <rtept lat="45.01" lon="5.0"><name>B</name></rtept>
          </rte>
        </gpx>
        """.utf8)
    }

    func testReadsTheTrackColourName() throws {
        let library = try GPX.read(track(colour: "DarkBlue")).library
        XCTAssertEqual(library.tracks.first?.color, ItemColor(red: 0, green: 0, blue: Double(0x80) / 255))
    }

    func testReadsTheRouteColourName() throws {
        let library = try GPX.read(route(colour: "Red")).library
        XCTAssertEqual(library.routes.first?.color, ItemColor(red: 1, green: 0, blue: 0))
    }

    func testTransparentAndUnknownNamesGiveNoColour() throws {
        XCTAssertNil(try GPX.read(track(colour: "Transparent")).library.tracks.first?.color)
        XCTAssertNil(try GPX.read(track(colour: "Purple")).library.tracks.first?.color)
    }

    func testAnItemWithoutAColourWritesNoDisplayColor() {
        let library = Library(
            routes: [Route(name: "Loop")],
            tracks: [Track(name: "Ride", segments: [[TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5))]])]
        )
        let xml = String(decoding: GPX.write(library), as: UTF8.self)
        XCTAssertFalse(xml.contains("DisplayColor"))
    }

    func testPaletteNamesRoundTrip() throws {
        let library = Library(
            routes: [Route(name: "Loop", color: ItemColor(red: 0, green: 0, blue: Double(0x80) / 255))],
            tracks: [Track(
                name: "Ride",
                segments: [[TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5))]],
                color: ItemColor(red: 1, green: 0, blue: 0)
            )]
        )
        let written = GPX.write(library)
        let xml = String(decoding: written, as: UTF8.self)
        XCTAssertTrue(xml.contains("<gpxx:DisplayColor>DarkBlue</gpxx:DisplayColor>"))
        XCTAssertTrue(xml.contains("<gpxx:DisplayColor>Red</gpxx:DisplayColor>"))
        let read = try GPX.read(written).library
        XCTAssertEqual(read.routes.first?.color, library.routes.first?.color)
        XCTAssertEqual(read.tracks.first?.color, library.tracks.first?.color)
    }

    func testWritesTheNearestName() {
        XCTAssertEqual(GarminColour.name(nearest: ItemColor(red: 0.9, green: 0.1, blue: 0.1)), "Red")
        XCTAssertEqual(GarminColour.name(nearest: ItemColor(red: 0.05, green: 0.05, blue: 0.5)), "DarkBlue")
        XCTAssertEqual(GarminColour.name(nearest: ItemColor(red: 0.95, green: 0.95, blue: 0.95)), "White")
    }
}
