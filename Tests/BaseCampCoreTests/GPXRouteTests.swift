import XCTest
@testable import BaseCampCore

final class GPXRouteTests: XCTestCase {
    private func coordinate(_ latitude: Double, _ longitude: Double) -> Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    /// A route as the planner makes one: a start, a shaping point and an end, with the shape of each leg.
    private func plannedRoute() -> Route {
        Route(name: "Way out", stops: [
            RouteStop(name: "Start", coordinate: coordinate(45.5, 6.25)),
            RouteStop(name: "Pass", coordinate: coordinate(45.6, 6.30), isShaping: true),
            RouteStop(name: "End", coordinate: coordinate(45.7, 6.35)),
        ], legs: [
            RouteLeg(shape: [
                RoutePoint(coordinate: coordinate(45.52, 6.26)),
                RoutePoint(coordinate: coordinate(45.55, 6.27)),
                RoutePoint(coordinate: coordinate(45.58, 6.29)),
            ], method: .calculated),
            RouteLeg(shape: [
                RoutePoint(coordinate: coordinate(45.63, 6.32)),
                RoutePoint(coordinate: coordinate(45.67, 6.34)),
            ], method: .calculated),
        ])
    }

    private func written(_ route: Route) -> String {
        String(decoding: GPX.write(Library(routes: [route])), as: UTF8.self)
    }

    private func readBack(_ text: String) throws -> Route {
        try XCTUnwrap(GPX.read(Data(text.utf8)).library.routes.first)
    }

    func testStopsShapingAndShapeRoundTrip() throws {
        let route = plannedRoute()

        let read = try readBack(written(route))

        XCTAssertEqual(read.stops.map(\.name), ["Start", "Pass", "End"])
        XCTAssertEqual(read.stops.map(\.isShaping), [false, true, false])
        for (stop, original) in zip(read.stops, route.stops) {
            XCTAssertEqual(stop.coordinate.latitude, original.coordinate.latitude, accuracy: 1e-7)
            XCTAssertEqual(stop.coordinate.longitude, original.coordinate.longitude, accuracy: 1e-7)
        }
        XCTAssertEqual(read.legs.count, 2)
        for (leg, original) in zip(read.legs, route.legs) {
            XCTAssertEqual(leg.shape.count, original.shape.count)
            for (point, expected) in zip(leg.shape, original.shape) {
                XCTAssertEqual(point.coordinate.latitude, expected.coordinate.latitude, accuracy: 1e-7)
                XCTAssertEqual(point.coordinate.longitude, expected.coordinate.longitude, accuracy: 1e-7)
                // gpxx:rpt has no height, so shape heights do not survive a round trip.
                XCTAssertNil(point.elevation)
            }
            XCTAssertEqual(leg.method, .imported)
        }
    }

    func testWriterMarksViaAndShapingPointsAndDeclaresTheGarminNamespaces() {
        let text = written(plannedRoute())

        XCTAssertTrue(text.contains("xmlns:gpxx=\"http://www.garmin.com/xmlschemas/GpxExtensions/v3\""))
        XCTAssertTrue(text.contains("xmlns:trp=\"http://www.garmin.com/xmlschemas/TripExtensions/v1\""))
        XCTAssertEqual(text.components(separatedBy: "<trp:ShapingPoint/>").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "<trp:ViaPoint/>").count - 1, 2)
        XCTAssertEqual(text.components(separatedBy: "<gpxx:rpt ").count - 1, 5)
    }

    func testFirstAndLastStopsAreAlwaysViaPoints() throws {
        let route = Route(name: "Ends", stops: [
            RouteStop(name: "Start", coordinate: coordinate(45.5, 6.25), isShaping: true),
            RouteStop(name: "End", coordinate: coordinate(45.6, 6.3), isShaping: true),
        ])
        let text = written(route)

        XCTAssertEqual(text.components(separatedBy: "<trp:ShapingPoint/>").count - 1, 0)
        XCTAssertEqual(try readBack(text).stops.map(\.isShaping), [false, false])
    }

    func testShapePointsAreFoundUnderAnyPrefixForTheGarminNamespaces() throws {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="other" xmlns="http://www.topografix.com/GPX/1/1" xmlns:g="http://www.garmin.com/xmlschemas/GpxExtensions/v3" xmlns:t="http://www.garmin.com/xmlschemas/TripExtensions/v1">
          <rte>
            <name>Loop</name>
            <rtept lat="45.5" lon="6.25"><extensions><t:ViaPoint/><g:RoutePointExtension><g:rpt lat="45.52" lon="6.26"/></g:RoutePointExtension></extensions></rtept>
            <rtept lat="45.6" lon="6.3"><extensions><t:ShapingPoint/></extensions></rtept>
            <rtept lat="45.7" lon="6.35"><extensions><t:ViaPoint/></extensions></rtept>
          </rte>
        </gpx>
        """

        let read = try readBack(text)

        XCTAssertEqual(read.stops.map(\.isShaping), [false, true, false])
        XCTAssertEqual(read.legs.map { $0.shape.count }, [1, 0])
        XCTAssertEqual(try XCTUnwrap(read.legs.first?.shape.first).coordinate.latitude, 45.52, accuracy: 1e-9)
    }

    func testARouteWithoutShapePointsIsReadAsPlainPoints() throws {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="other" xmlns="http://www.topografix.com/GPX/1/1" xmlns:t="http://www.garmin.com/xmlschemas/TripExtensions/v1">
          <rte>
            <name>Plain</name>
            <rtept lat="45.5" lon="6.25"><extensions><t:ViaPoint/></extensions></rtept>
            <rtept lat="45.6" lon="6.3"><extensions><t:ShapingPoint/></extensions></rtept>
            <rtept lat="45.7" lon="6.35"><extensions><t:ViaPoint/></extensions></rtept>
          </rte>
        </gpx>
        """

        let read = try readBack(text)

        XCTAssertEqual(read.stops.count, 3)
        XCTAssertEqual(read.points.count, 3)
        XCTAssertTrue(read.legs.allSatisfy { $0.shape.isEmpty })
    }
}
