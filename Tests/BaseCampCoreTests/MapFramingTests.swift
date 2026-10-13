import XCTest
@testable import BaseCampCore

final class MapFramingTests: XCTestCase {
    private func metres(_ a: Coordinate, _ b: Coordinate) -> Double {
        Geodesy.distance(from: a, to: b)
    }

    func testNoCoordinatesGivesNoArea() {
        XCTAssertNil(MapFraming.area(enclosing: []))
    }

    func testSinglePointGetsTheMinimumSpanCentredOnIt() throws {
        let point = Coordinate(latitude: 45, longitude: 5)
        let area = try XCTUnwrap(MapFraming.area(enclosing: [point]))
        XCTAssertEqual(metres(Coordinate(latitude: area.southWest.latitude, longitude: 5),
                              Coordinate(latitude: area.northEast.latitude, longitude: 5)),
                       MapFraming.minimumSpanMetres, accuracy: MapFraming.minimumSpanMetres * 0.01)
        XCTAssertEqual(metres(Coordinate(latitude: 45, longitude: area.southWest.longitude),
                              Coordinate(latitude: 45, longitude: area.northEast.longitude)),
                       MapFraming.minimumSpanMetres, accuracy: MapFraming.minimumSpanMetres * 0.01)
        XCTAssertEqual((area.southWest.latitude + area.northEast.latitude) / 2, 45, accuracy: 1e-9)
        XCTAssertEqual((area.southWest.longitude + area.northEast.longitude) / 2, 5, accuracy: 1e-9)
    }

    func testAreaLargerThanTheMinimumIsExactlyTheExtent() throws {
        let area = try XCTUnwrap(MapFraming.area(enclosing: [
            Coordinate(latitude: 45, longitude: 5),
            Coordinate(latitude: 45.5, longitude: 5.5),
        ]))
        XCTAssertEqual(area.southWest.latitude, 45, accuracy: 1e-9)
        XCTAssertEqual(area.southWest.longitude, 5, accuracy: 1e-9)
        XCTAssertEqual(area.northEast.latitude, 45.5, accuracy: 1e-9)
        XCTAssertEqual(area.northEast.longitude, 5.5, accuracy: 1e-9)
    }

    func testPointsTenMetresApartAreGrownToTheMinimum() throws {
        let area = try XCTUnwrap(MapFraming.area(enclosing: [
            Coordinate(latitude: 60, longitude: 10),
            Coordinate(latitude: 60.00009, longitude: 10.00015),
        ]))
        XCTAssertEqual(metres(Coordinate(latitude: area.southWest.latitude, longitude: 10),
                              Coordinate(latitude: area.northEast.latitude, longitude: 10)),
                       MapFraming.minimumSpanMetres, accuracy: MapFraming.minimumSpanMetres * 0.01)
        XCTAssertEqual(metres(Coordinate(latitude: 60, longitude: area.southWest.longitude),
                              Coordinate(latitude: 60, longitude: area.northEast.longitude)),
                       MapFraming.minimumSpanMetres, accuracy: MapFraming.minimumSpanMetres * 0.01)
    }

    func testTallExtentKeepsItsHeightAndGetsTheMinimumWidth() throws {
        let area = try XCTUnwrap(MapFraming.area(enclosing: [
            Coordinate(latitude: 45, longitude: 5),
            Coordinate(latitude: 46, longitude: 5),
        ]))
        XCTAssertEqual(area.northEast.latitude - area.southWest.latitude, 1, accuracy: 1e-9)
        XCTAssertEqual(metres(Coordinate(latitude: 45.5, longitude: area.southWest.longitude),
                              Coordinate(latitude: 45.5, longitude: area.northEast.longitude)),
                       MapFraming.minimumSpanMetres, accuracy: MapFraming.minimumSpanMetres * 0.01)
    }

    func testCustomMinimumSpanIsUsed() throws {
        let area = try XCTUnwrap(MapFraming.area(enclosing: [Coordinate(latitude: 45, longitude: 5)], minimumSpanMetres: 5_000))
        XCTAssertEqual(metres(Coordinate(latitude: area.southWest.latitude, longitude: 5),
                              Coordinate(latitude: area.northEast.latitude, longitude: 5)),
                       5_000, accuracy: 50)
    }

    func testNearThePoleStaysWithinMercatorAndTheGlobe() throws {
        let area = try XCTUnwrap(MapFraming.area(enclosing: [Coordinate(latitude: 89.9, longitude: 10)]))
        XCTAssertLessThanOrEqual(area.northEast.latitude, 85.05)
        XCTAssertLessThanOrEqual(area.southWest.latitude, area.northEast.latitude)
        XCTAssertLessThanOrEqual(area.northEast.longitude - area.southWest.longitude, 360)
        XCTAssertTrue(area.northEast.longitude.isFinite && area.southWest.longitude.isFinite)
    }
}
