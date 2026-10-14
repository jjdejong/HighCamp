import XCTest
@testable import BaseCampCore

final class GPXSensorTests: XCTestCase {
    private let header = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
         xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
         xmlns:power="http://www.garmin.com/xmlschemas/PowerExtension/v1">
    """

    /// Made-up readings, for the tests only. The track point extension uses the v1 namespace here.
    private func sensorFile() -> Data {
        Data("""
        \(header)
          <trk><name>Ride</name><trkseg>
            <trkpt lat="45.0" lon="5.0">
              <ele>300</ele>
              <extensions>
                <gpxtpx:TrackPointExtension>
                  <gpxtpx:atemp>18.5</gpxtpx:atemp>
                  <gpxtpx:hr>120</gpxtpx:hr>
                  <gpxtpx:cad>85</gpxtpx:cad>
                </gpxtpx:TrackPointExtension>
                <power:PowerInWatts>210</power:PowerInWatts>
              </extensions>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """.utf8)
    }

    private func firstPoint(_ data: Data) throws -> TrackPoint {
        try XCTUnwrap(GPX.read(data).library.tracks.first?.segments.first?.first)
    }

    func testReadsHeartRateCadenceAndTemperature() throws {
        let point = try firstPoint(sensorFile())
        XCTAssertEqual(point.heartRate, 120)
        XCTAssertEqual(point.cadence, 85)
        XCTAssertEqual(point.temperature, 18.5)
    }

    func testReadsPowerFromThePowerExtension() throws {
        XCTAssertEqual(try firstPoint(sensorFile()).power, 210)
    }

    func testReadsPowerFromAPlainPowerElement() throws {
        let plain = Data("""
        \(header)
          <trk><trkseg><trkpt lat="45.0" lon="5.0"><extensions><power>180</power></extensions></trkpt></trkseg></trk>
        </gpx>
        """.utf8)
        XCTAssertEqual(try firstPoint(plain).power, 180)
    }

    func testReadsTheVersionTwoNamespaceUnderAnyPrefix() throws {
        let v2 = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:ext="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
          <trk><trkseg><trkpt lat="45.0" lon="5.0">
            <extensions><ext:TrackPointExtension><ext:hr>99</ext:hr></ext:TrackPointExtension></extensions>
          </trkpt></trkseg></trk>
        </gpx>
        """.utf8)
        XCTAssertEqual(try firstPoint(v2).heartRate, 99)
    }

    func testAPointWithoutSensorsHasNone() throws {
        let plain = Data("""
        \(header)
          <trk><trkseg><trkpt lat="45.0" lon="5.0"><ele>300</ele></trkpt></trkseg></trk>
        </gpx>
        """.utf8)
        let point = try firstPoint(plain)
        XCTAssertNil(point.heartRate)
        XCTAssertNil(point.cadence)
        XCTAssertNil(point.power)
        XCTAssertNil(point.temperature)
    }

    func testAPlainPointWritesNoExtensions() {
        let library = Library(tracks: [Track(name: "Ride", segments: [[TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5))]])])
        XCTAssertFalse(String(decoding: GPX.write(library), as: UTF8.self).contains("extensions"))
    }

    func testSensorReadingsRoundTrip() throws {
        let original = Library(tracks: [Track(name: "Ride", segments: [[
            TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 300,
                       heartRate: 120, cadence: 85, power: 210, temperature: 18.5),
        ]])])
        let written = GPX.write(original)
        let xml = String(decoding: written, as: UTF8.self)
        XCTAssertTrue(xml.contains("<gpxtpx:hr>120</gpxtpx:hr>"))
        XCTAssertTrue(xml.contains("<power:PowerInWatts>210</power:PowerInWatts>"))
        let read = try firstPoint(written)
        XCTAssertEqual(read.heartRate, 120)
        XCTAssertEqual(read.cadence, 85)
        XCTAssertEqual(read.power, 210)
        XCTAssertEqual(read.temperature, 18.5)
    }
}
