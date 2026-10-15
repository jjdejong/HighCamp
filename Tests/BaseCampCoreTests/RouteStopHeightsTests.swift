import XCTest
@testable import BaseCampCore

/// Stops placed, inserted or moved by hand have no height; the router's legs on either side do. A stop takes its
/// height from them, so exports, the inspector and the device see a height at every stop.
final class RouteStopHeightsTests: XCTestCase {
    private func coordinate(_ latitude: Double) -> Coordinate {
        Coordinate(latitude: latitude, longitude: 5)
    }

    private func point(_ latitude: Double, _ elevation: Double?) -> RoutePoint {
        RoutePoint(coordinate: coordinate(latitude), elevation: elevation)
    }

    /// Three stops without heights, two calculated legs with heights.
    private func route() -> Route {
        Route(name: "Hand-made", stops: [
            RouteStop(coordinate: coordinate(45.000)),
            RouteStop(coordinate: coordinate(45.004)),
            RouteStop(coordinate: coordinate(45.008)),
        ], legs: [
            RouteLeg(shape: [point(45.001, 500), point(45.003, 540)], method: .calculated),
            RouteLeg(shape: [point(45.005, 560), point(45.007, 600)], method: .calculated),
        ], profileID: UUID())
    }

    private func heights(_ route: Route) -> [Double?] {
        route.stops.map(\.elevation)
    }

    func testStopsTakeTheHeightsOfTheLegsBesideThem() throws {
        let stops = heights(route())

        XCTAssertEqual(try XCTUnwrap(stops[0]), 500, accuracy: 0.01, "the start takes the first height after it")
        XCTAssertEqual(try XCTUnwrap(stops[1]), 550, accuracy: 0.01, "between 540 and 560, halfway")
        XCTAssertEqual(try XCTUnwrap(stops[2]), 600, accuracy: 0.01, "the end takes the last height before it")
    }

    func testAStopsOwnHeightIsKept() {
        let route = Route(name: "Kept", stops: [
            RouteStop(coordinate: coordinate(45.000), elevation: 480),
            RouteStop(coordinate: coordinate(45.004)),
        ], legs: [
            RouteLeg(shape: [point(45.001, 500), point(45.003, 540)], method: .calculated),
        ])

        XCTAssertEqual(route.stops[0].elevation, 480)
    }

    func testStraightLegsGiveNoHeight() {
        let route = Route(name: "Straight", stops: [
            RouteStop(coordinate: coordinate(45.000), elevation: 480),
            RouteStop(coordinate: coordinate(45.004)),
        ])

        XCTAssertNil(route.stops[1].elevation, "no guess across a straight line")
    }

    func testShapePointsWithoutHeightAreSkipped() throws {
        let route = Route(name: "Gaps", stops: [
            RouteStop(coordinate: coordinate(45.000)),
            RouteStop(coordinate: coordinate(45.004)),
        ], legs: [
            RouteLeg(shape: [point(45.001, nil), point(45.002, 520), point(45.003, nil)], method: .imported),
        ])

        XCTAssertEqual(try XCTUnwrap(route.stops[0].elevation), 520, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(route.stops[1].elevation), 520, accuracy: 0.01)
    }

    func testAMovedStopGetsAHeightWhenItsLegsComeBack() throws {
        var route = route()
        route.moveStop(at: 1, to: coordinate(45.0045))
        XCTAssertNil(route.stops[1].elevation, "a moved stop's old height no longer applies")
        let start = route.stops[0], moved = route.stops[1], end = route.stops[2]

        let first = RouteLeg(shape: [point(45.001, 500), point(45.004, 550)], method: .calculated)
        XCTAssertTrue(route.setLeg(at: 0, from: start, to: moved, first))
        XCTAssertEqual(try XCTUnwrap(route.stops[1].elevation), 550, accuracy: 0.01)

        // The answer for the other leg was asked for before the stop had a height. It is still current.
        let second = RouteLeg(shape: [point(45.005, 570), point(45.007, 600)], method: .calculated)
        XCTAssertTrue(route.setLeg(at: 1, from: moved, to: end, second), "a height filled in does not make the answer stale")
        XCTAssertEqual(try XCTUnwrap(route.stops[1].elevation), 550, accuracy: 0.01, "a height once given is kept")
    }

    func testAnAnswerForAStopThatMovedIsStillRefused() {
        var route = route()
        let start = route.stops[0], end = route.stops[1]
        route.moveStop(at: 1, to: coordinate(45.0045))

        XCTAssertFalse(route.setLeg(at: 0, from: start, to: end, RouteLeg(method: .calculated)))
    }

    func testOlderLibrariesGetStopHeightsWhenRead() throws {
        // As saved before stops took heights: the stops' heights removed from the file.
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(route())) as? [String: Any])
        let stops = try XCTUnwrap(file["stops"] as? [[String: Any]])
        file["stops"] = stops.map { $0.filter { $0.key != "elevation" } }
        let data = try JSONSerialization.data(withJSONObject: file)

        let read = try JSONDecoder().decode(Route.self, from: data)

        XCTAssertTrue(read.stops.allSatisfy { $0.elevation != nil })
    }
}
