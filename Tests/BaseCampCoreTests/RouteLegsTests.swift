import BaseCampCore
import XCTest

final class RouteLegsTests: XCTestCase {
    private func stop(_ latitude: Double) -> RouteStop {
        RouteStop(coordinate: Coordinate(latitude: latitude, longitude: 5))
    }

    private func planned() -> Route {
        Route(name: "Planned", stops: [stop(45), stop(45.01), stop(45.02)], legs: [
            RouteLeg(method: .calculated, profileID: UUID()),
            RouteLeg(method: .calculated, profileID: UUID()),
        ], profileID: UUID())
    }

    func testAMovedStopLeavesBothItsLegsWaiting() {
        var route = planned()
        XCTAssertEqual(route.legsWaitingForRouter, [])
        route.moveStop(at: 1, to: Coordinate(latitude: 45.011, longitude: 5.001))
        XCTAssertEqual(route.legsWaitingForRouter, [0, 1])
    }

    func testARecalculatedLegIsTakenOnlyWhileItsStopsAreUnchanged() {
        var route = planned()
        route.moveStop(at: 1, to: Coordinate(latitude: 45.011, longitude: 5.001))
        let start = route.stops[0], end = route.stops[1]
        let line = [start.coordinate, Coordinate(latitude: 45.005, longitude: 5.002), end.coordinate].map { RoutePoint(coordinate: $0) }
        let leg = RouteLeg.calculated(line: line, from: start.coordinate, to: end.coordinate, profileID: route.profileID)
        XCTAssertEqual(leg.shape.count, 1, "the points on the stops are dropped")

        var moved = route
        moved.moveStop(at: 1, to: Coordinate(latitude: 45.012, longitude: 5))
        XCTAssertFalse(moved.setLeg(at: 0, from: start, to: end, leg), "a stale result is refused")

        XCTAssertTrue(route.setLeg(at: 0, from: start, to: end, leg))
        XCTAssertEqual(route.legsWaitingForRouter, [1])
        XCTAssertEqual(route.legs[0].state, .calculated(profileID: route.profileID))
    }

    func testTheMidpointIsHalfwayAlongTheLeg() throws {
        let route = Route(name: "Straight", stops: [stop(45), stop(45.02)])
        let middle = try XCTUnwrap(route.legMidpoint(0))
        XCTAssertEqual(middle.latitude, 45.01, accuracy: 1e-6)
        XCTAssertNil(route.legMidpoint(1))
    }

    func testAnAmendedValueIsUndoneWithTheStepBeforeIt() {
        var history = UndoHistory(1)
        history.edit("Change") { $0 = 2 }
        XCTAssertTrue(history.amend { $0 = 3 })
        XCTAssertEqual(history.undoName, "Change")
        history.undo()
        XCTAssertEqual(history.value, 1)
        history.redo()
        XCTAssertEqual(history.value, 3, "redo brings back the amended value")
        XCTAssertFalse(history.canRedo)
    }
}
