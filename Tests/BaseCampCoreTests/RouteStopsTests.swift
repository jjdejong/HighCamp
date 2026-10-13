import XCTest
@testable import BaseCampCore

final class RouteStopsTests: XCTestCase {
    private func coordinate(_ latitude: Double, _ longitude: Double) -> Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    /// Three stops, the middle one a shaping point, and a shape point in each leg.
    private func route() -> Route {
        Route(name: "Loop", stops: [
            RouteStop(name: "Start", coordinate: coordinate(45.5, 6.25)),
            RouteStop(name: "Pass", coordinate: coordinate(45.6, 6.30), isShaping: true),
            RouteStop(name: "End", coordinate: coordinate(45.7, 6.35)),
        ], legs: [
            RouteLeg(shape: [RoutePoint(coordinate: coordinate(45.52, 6.26))], method: .calculated),
            RouteLeg(shape: [RoutePoint(coordinate: coordinate(45.66, 6.33))], method: .imported),
        ])
    }

    func testDistancesFromTheStartFollowTheLine() throws {
        let route = route()

        let distances = route.stopDistances()

        guard distances.count == 3 else {
            return XCTFail("one distance per stop, got \(distances.count)")
        }
        XCTAssertEqual(distances[0], 0, accuracy: 1e-9)
        XCTAssertGreaterThan(distances[1], 0)
        XCTAssertGreaterThan(distances[2], distances[1])
        // The last stop is the end of the line, so its distance is the route's length.
        XCTAssertEqual(distances[2], route.lengthMeters, accuracy: 1e-6)
    }

    func testNoStopsHaveNoDistances() {
        XCTAssertEqual(Route(name: "Empty", stops: []).stopDistances(), [])
    }

    func testFirstAndLastStopsCannotBeShapingPoints() {
        var route = route()

        route.setShaping(true, at: 0)
        route.setShaping(true, at: 2)
        XCTAssertEqual(route.stops.map(\.isShaping), [false, true, false])

        route.setShaping(false, at: 1)
        XCTAssertEqual(route.stops.map(\.isShaping), [false, false, false])
        route.setShaping(true, at: 1)
        XCTAssertEqual(route.stops.map(\.isShaping), [false, true, false])
    }

    func testSettingTheKindOfAMissingStopChangesNothing() {
        var route = route()
        let before = route

        route.setShaping(true, at: 9)

        XCTAssertEqual(route, before)
    }

    func testLegStateSaysHowALegWasMade() {
        let profile = UUID(uuidString: "6A1F0C3E-0002-4B2E-9C11-000000000002")!
        XCTAssertEqual(RouteLeg(method: .direct).state, .straight)
        XCTAssertEqual(RouteLeg(method: .calculated, profileID: profile).state, .calculated(profileID: profile))
        XCTAssertEqual(RouteLeg(method: .calculated).state, .calculated(profileID: nil))
        XCTAssertEqual(RouteLeg(method: .imported).state, .imported)
    }

    func testALegWaitingForRecalculationSaysSo() {
        let leg = RouteLeg(method: .calculated, profileID: UUID(), needsRecalculation: true)

        XCTAssertEqual(leg.state, .waiting)
    }
}
