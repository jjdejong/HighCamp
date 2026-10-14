import XCTest
@testable import BaseCampCore

final class RouteRecalculateTests: XCTestCase {
    private func coordinate(_ latitude: Double, _ longitude: Double) -> Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    /// Three stops, with a shape point in each leg. The legs were made by the router and by an import.
    private func route(profileID: UUID?) -> Route {
        Route(name: "Loop", stops: [
            RouteStop(name: "Start", coordinate: coordinate(45.5, 6.25)),
            RouteStop(name: "Pass", coordinate: coordinate(45.6, 6.30), isShaping: true),
            RouteStop(name: "End", coordinate: coordinate(45.7, 6.35)),
        ], legs: [
            RouteLeg(shape: [RoutePoint(coordinate: coordinate(45.52, 6.26))], method: .calculated, profileID: profileID),
            RouteLeg(shape: [RoutePoint(coordinate: coordinate(45.66, 6.33))], method: .imported),
        ], profileID: profileID)
    }

    func testRecalculateMarksEveryLegAndKeepsItsShape() {
        var route = route(profileID: UUID())
        let shapes = route.legs.map(\.shape)

        XCTAssertTrue(route.markAllLegsForRecalculation())

        XCTAssertEqual(route.legsWaitingForRouter, [0, 1])
        XCTAssertEqual(route.legs.map(\.shape), shapes, "the old line stays until the router answers")
    }

    func testRecalculateWithoutAProfileChangesNothing() {
        var route = route(profileID: nil)
        let before = route

        XCTAssertFalse(route.markAllLegsForRecalculation())

        XCTAssertEqual(route, before)
    }

    func testRecalculateOfARouteWithoutLegsChangesNothing() {
        var route = Route(name: "Point", stops: [RouteStop(coordinate: coordinate(45.5, 6.25))], profileID: UUID())
        let before = route

        XCTAssertFalse(route.markAllLegsForRecalculation())

        XCTAssertEqual(route, before)
    }
}
