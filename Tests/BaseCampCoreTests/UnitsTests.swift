import XCTest
@testable import BaseCampCore

final class UnitsTests: XCTestCase {
    func testUTMOfTheCentralMeridianIsTheFalseEasting() throws {
        let utm = try XCTUnwrap(UTM(Coordinate(latitude: 0, longitude: 3)))
        XCTAssertEqual(utm.zone, 31)
        XCTAssertEqual(utm.easting, 500_000)
        XCTAssertEqual(utm.northing, 0)
    }

    func testUTMNorthernAndBandForLondon() throws {
        // London, 30U. Reference values: 699316 E, 5710164 N.
        let utm = try XCTUnwrap(UTM(Coordinate(latitude: 51.5074, longitude: -0.1278)))
        XCTAssertEqual(utm.zone, 30)
        XCTAssertEqual(utm.band, "U")
        XCTAssertEqual(Double(utm.easting), 699_316, accuracy: 60)
        XCTAssertEqual(Double(utm.northing), 5_710_164, accuracy: 60)
    }

    func testUTMSouthernHemisphereAddsTheFalseNorthing() throws {
        let utm = try XCTUnwrap(UTM(Coordinate(latitude: -1, longitude: 3)))
        XCTAssertEqual(utm.zone, 31)
        XCTAssertLessThan(utm.band, "N")
        XCTAssertEqual(Double(utm.northing), 9_889_470, accuracy: 300)
    }

    func testUTMIsNilOutsideTheGrid() {
        XCTAssertNil(UTM(Coordinate(latitude: 85, longitude: 0)))
    }

    func testDegreesMinutesSecondsCarryAtSixty() {
        // 45.9999999° is 46° 00′ 00.00″, not 45° 60′.
        let text = UnitFormat.coordinate(Coordinate(latitude: 45.9999999, longitude: 5), .degreesMinutesSeconds)
        XCTAssertTrue(text.hasPrefix("46° 00′ 00.00″ N"), text)
    }

    func testDegreesMinutesFormatAndHemispheres() {
        let text = UnitFormat.coordinate(Coordinate(latitude: -45.5, longitude: -5.25), .degreesMinutes)
        XCTAssertEqual(text, "S 45° 30.0000′  W 5° 15.0000′")
    }

    func testDistanceInEachSystem() {
        XCTAssertEqual(UnitFormat.distance(1500, .metric), "1.50 km")
        XCTAssertEqual(UnitFormat.distance(1609.344, .statute), "1.00 mi")
        XCTAssertEqual(UnitFormat.distance(1852, .nautical), "1.00 nm")
        XCTAssertEqual(UnitFormat.distance(50, .statute), "164 ft")
    }

    func testSpeedAndElevationInEachSystem() {
        XCTAssertEqual(UnitFormat.speed(10, .metric), "36.0 km/h")
        XCTAssertEqual(UnitFormat.speed(10, .statute), "22.4 mph")
        XCTAssertEqual(UnitFormat.speed(10, .nautical), "19.4 kn")
        XCTAssertEqual(UnitFormat.elevation(100, .metric), "100 m")
        XCTAssertEqual(UnitFormat.elevation(100, .statute), "328 ft")
    }

    func testDistanceValuesConvertBackToMetres() {
        for system in [UnitSystem.metric, .statute, .nautical] {
            XCTAssertEqual(UnitFormat.distanceMeters(fromValue: UnitFormat.distanceValue(2_500, system), system), 2_500, accuracy: 1e-6)
        }
        XCTAssertEqual(UnitFormat.distanceMeters(fromValue: 2, .metric), 2_000, accuracy: 1e-9)
        XCTAssertEqual(UnitFormat.distanceMeters(fromValue: 1, .statute), 1_609.344, accuracy: 1e-9)
        XCTAssertEqual(UnitFormat.distanceMeters(fromValue: 1, .nautical), 1_852, accuracy: 1e-9)
    }
}
