import BaseCampCore
import XCTest

/// Legs the user keeps straight, where the router has no way (a path missing from its data), and the gaps the
/// router leaves between a stop and the nearest way it knows.
final class RouteStraightLegsTests: XCTestCase {
    private func stop(_ latitude: Double) -> RouteStop {
        RouteStop(coordinate: Coordinate(latitude: latitude, longitude: 5))
    }

    private func planned() -> Route {
        let profile = UUID()
        return Route(name: "Planned", stops: [stop(45), stop(45.01), stop(45.02), stop(45.03)], legs: [
            RouteLeg(method: .calculated, profileID: profile),
            RouteLeg(method: .calculated, profileID: profile),
            RouteLeg(method: .calculated, profileID: profile),
        ], profileID: profile)
    }

    func testAKeptStraightLegIsNeverSentToTheRouter() {
        var route = planned()
        route.setLegStraight(at: 1, true)
        XCTAssertEqual(route.legs[1].state, .keptStraight)
        XCTAssertEqual(route.legs[1].shape, [])
        XCTAssertEqual(route.legsWaitingForRouter, [])

        // Moving a stop at its end leaves it straight; the leg on the other side waits for the router.
        route.moveStop(at: 2, to: Coordinate(latitude: 45.021, longitude: 5.001))
        XCTAssertEqual(route.legsWaitingForRouter, [2])
        XCTAssertEqual(route.legs[1].state, .keptStraight)

        // Recalculating the whole route leaves it alone too.
        route.markAllLegsForRecalculation()
        XCTAssertEqual(route.legsWaitingForRouter, [0, 2])
    }

    func testRoutingALegAgainSendsItToTheRouter() {
        var route = planned()
        route.setLegStraight(at: 0, true)
        route.setLegStraight(at: 0, false)
        XCTAssertEqual(route.legsWaitingForRouter, [0])
        XCTAssertEqual(route.legs[0].state, .waiting)
    }

    func testAStopInsertedIntoAKeptStraightLegLeavesBothHalvesStraight() {
        var route = planned()
        route.setLegStraight(at: 1, true)
        route.insertStop(stop(45.015), at: 2)
        XCTAssertEqual(route.legs.map(\.keepsStraight), [false, true, true, false])
        XCTAssertEqual(route.legsWaitingForRouter, [])
    }

    func testRemovingAStopKeepsTheJoinedLegStraightOnlyWhenBothWere() {
        var both = planned()
        both.setLegStraight(at: 0, true)
        both.setLegStraight(at: 1, true)
        both.removeStop(at: 1)
        XCTAssertEqual(both.legs.map(\.keepsStraight), [true, false])
        XCTAssertEqual(both.legsWaitingForRouter, [])

        var one = planned()
        one.setLegStraight(at: 0, true)
        one.removeStop(at: 1)
        XCTAssertEqual(one.legs.map(\.keepsStraight), [false, false])
        XCTAssertEqual(one.legsWaitingForRouter, [0])
    }

    func testReversingKeepsTheStraightLegsAndSwapsTheGaps() {
        var route = planned()
        route.setLegStraight(at: 0, true)
        let start = route.stops[1], end = route.stops[2]
        let line = [Coordinate(latitude: 45.01, longitude: 5.001), Coordinate(latitude: 45.02, longitude: 5)].map { RoutePoint(coordinate: $0) }
        route.setLeg(at: 1, from: start, to: end, .calculated(line: line, from: start.coordinate, to: end.coordinate, profileID: route.profileID))
        let reversed = route.reversed()
        XCTAssertEqual(reversed.legs.map(\.keepsStraight), [false, false, true])
        XCTAssertEqual(try XCTUnwrap(reversed.legs[1].endGap), try XCTUnwrap(route.legs[1].startGap))
        XCTAssertEqual(reversed.legs[1].startGap, 0)
    }

    func testTheRoutersGapToEachStopIsKept() throws {
        let start = Coordinate(latitude: 45.0, longitude: 5.0)
        let end = Coordinate(latitude: 45.01, longitude: 5.0)
        // The router starts 0.001° of longitude east of the start (about 79 m) and ends on the end stop.
        let line = [Coordinate(latitude: 45.0, longitude: 5.001), Coordinate(latitude: 45.005, longitude: 5.001), end]
            .map { RoutePoint(coordinate: $0) }
        let leg = RouteLeg.calculated(line: line, from: start, to: end, profileID: nil)
        XCTAssertEqual(try XCTUnwrap(leg.startGap), 79, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(leg.endGap), 0, accuracy: 0.01)
    }

    func testAStopFarFromTheRoutersLineIsFound() {
        var route = planned()
        let profile = route.profileID
        // Leg 0 ends 80 m short of stop 1, leg 1 starts on it.
        let away = Coordinate(latitude: 45.01, longitude: 5.001)
        let leg0 = RouteLeg.calculated(line: [RoutePoint(coordinate: route.stops[0].coordinate), RoutePoint(coordinate: away)], from: route.stops[0].coordinate,
                                       to: route.stops[1].coordinate, profileID: profile)
        let leg1 = RouteLeg.calculated(line: [RoutePoint(coordinate: route.stops[1].coordinate), RoutePoint(coordinate: route.stops[2].coordinate)], from: route.stops[1].coordinate,
                                       to: route.stops[2].coordinate, profileID: profile)
        route.setLeg(at: 0, from: route.stops[0], to: route.stops[1], leg0)
        route.setLeg(at: 1, from: route.stops[1], to: route.stops[2], leg1)
        XCTAssertEqual(route.routerGap(atStop: 1) ?? 0, 79, accuracy: 1)
        XCTAssertEqual(route.routerGap(atStop: 2) ?? -1, 0, accuracy: 0.01)
        XCTAssertNil(route.routerGap(atStop: 3), "leg 2 was never calculated with gaps")

        // A kept-straight leg has no gap, and a stop between two of them has none either.
        route.setLegStraight(at: 0, true)
        XCTAssertEqual(route.routerGap(atStop: 1) ?? -1, 0, accuracy: 0.01)
        route.setLegStraight(at: 1, true)
        XCTAssertNil(route.routerGap(atStop: 1))
    }

    func testAPlannedRouteKeepsHowFarEachStopWasMovedOntoTheLine() throws {
        let stops = [stop(45), stop(45.01)]
        // The router's line starts 0.001° east of the first stop.
        let line = [Coordinate(latitude: 45.0, longitude: 5.001), Coordinate(latitude: 45.005, longitude: 5.0), Coordinate(latitude: 45.01, longitude: 5)]
            .map { RoutePoint(coordinate: $0) }
        let route = Route.planned(name: "P", stops: stops, line: line, profileID: UUID())
        XCTAssertEqual(try XCTUnwrap(route.routerGap(atStop: 0)), 79, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(route.routerGap(atStop: 1)), 0, accuracy: 0.01)
    }

    func testOldLegsReadWithoutTheNewFields() throws {
        let json = #"{"shape":[],"method":"calculated","needsRecalculation":false}"#
        let leg = try JSONDecoder().decode(RouteLeg.self, from: Data(json.utf8))
        XCTAssertFalse(leg.keepsStraight)
        XCTAssertNil(leg.startGap)
        let again = try JSONDecoder().decode(RouteLeg.self, from: JSONEncoder().encode(RouteLeg(method: .direct, keepsStraight: true)))
        XCTAssertTrue(again.keepsStraight)
    }
}
