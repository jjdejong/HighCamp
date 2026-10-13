import BaseCampCore
import XCTest

final class RouteTests: XCTestCase {
    private func point(_ index: Int, name: String? = nil) -> RoutePoint {
        RoutePoint(name: name, coordinate: Coordinate(latitude: 45 + Double(index) * 0.001, longitude: 5), elevation: Double(index))
    }

    private func checkLegs(_ route: Route, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(route.legs.count, max(0, route.stops.count - 1), file: file, line: line)
    }

    func testAShortListOfPointsIsAllStops() {
        let route = Route(name: "Clicked", points: (0..<5).map { point($0) })
        XCTAssertEqual(route.stops.count, 5)
        XCTAssertTrue(route.legs.allSatisfy { $0.method == .direct && $0.shape.isEmpty })
        XCTAssertEqual(route.points, (0..<5).map { point($0) })
    }

    func testALongListKeepsItsEndsAndNamedPointsAsStops() {
        let points = (0..<500).map { point($0, name: $0 == 250 ? "Col" : nil) }
        let route = Route(name: "Imported", points: points)
        XCTAssertEqual(route.stops.map(\.name), [nil, "Col", nil])
        XCTAssertEqual(route.legs.map(\.method), [.imported, .imported])
        XCTAssertEqual(route.legs.map(\.shape.count), [249, 248])
        XCTAssertEqual(route.points, points, "the line is unchanged")
    }

    func testAPlannedLineIsCutAtTheStops() {
        let line = (0..<11).map { point($0) }
        // The middle stop is a little off the line, as clicked; it is moved onto it.
        let middle = Coordinate(latitude: 45.005, longitude: 5.0001)
        let profile = UUID()
        let route = Route.planned(
            name: "Planned",
            stops: [RouteStop(coordinate: line[0].coordinate), RouteStop(coordinate: middle), RouteStop(coordinate: line[10].coordinate)],
            line: line, profileID: profile
        )
        XCTAssertEqual(route.stops[1].coordinate, line[5].coordinate)
        XCTAssertEqual(route.stops[1].elevation, 5)
        XCTAssertEqual(route.legs.map(\.shape.count), [4, 4])
        XCTAssertTrue(route.legs.allSatisfy { $0.method == .calculated && $0.profileID == profile })
        XCTAssertEqual(route.points.map(\.coordinate), line.map(\.coordinate))
    }

    func testMovingAStopStraightensItsLegsForTheRouter() {
        let profile = UUID()
        var route = Route.planned(
            name: "Planned", stops: [0, 5, 10].map { RouteStop(coordinate: point($0).coordinate) },
            line: (0..<11).map { point($0) }, profileID: profile
        )
        route.moveStop(at: 1, to: Coordinate(latitude: 45.005, longitude: 5.01))
        XCTAssertNil(route.stops[1].elevation)
        XCTAssertTrue(route.legs.allSatisfy { $0.shape.isEmpty && $0.needsRecalculation })

        // Without a profile, changed legs simply stay straight.
        var plain = Route(name: "Clicked", points: (0..<3).map { point($0) })
        plain.moveStop(at: 0, to: Coordinate(latitude: 44, longitude: 5))
        XCTAssertFalse(plain.legs[0].needsRecalculation)
    }

    func testRemovingAndInsertingStopsKeepsOneLegBetweenEachTwo() {
        var route = Route.planned(
            name: "Planned", stops: [0, 5, 10].map { RouteStop(coordinate: point($0).coordinate) },
            line: (0..<11).map { point($0) }, profileID: UUID()
        )
        route.removeStop(at: 1)
        checkLegs(route)
        XCTAssertTrue(route.legs[0].needsRecalculation)
        route.insertStop(RouteStop(coordinate: point(3).coordinate), at: 1)
        checkLegs(route)
        route.insertStop(RouteStop(coordinate: point(20).coordinate), at: route.stops.count)
        checkLegs(route)
        route.insertStop(RouteStop(coordinate: point(-5).coordinate), at: 0)
        checkLegs(route)
        XCTAssertEqual(route.stops.count, 5)
        route.removeStop(at: 0)
        route.removeStop(at: route.stops.count - 1)
        checkLegs(route)
        while !route.stops.isEmpty {
            route.removeStop(at: 0)
            checkLegs(route)
        }
    }

    func testARecalculatedLegIsOnlyTakenWhileItsStopsAreUnchanged() {
        var route = Route(name: "Clicked", points: (0..<3).map { point($0) })
        let start = route.stops[0], end = route.stops[1]
        let leg = RouteLeg(shape: [point(9)], method: .calculated)
        var moved = route
        moved.moveStop(at: 1, to: Coordinate(latitude: 46, longitude: 5))
        XCTAssertFalse(moved.setLeg(at: 0, from: start, to: end, leg))
        XCTAssertTrue(route.setLeg(at: 0, from: start, to: end, leg))
        XCTAssertEqual(route.legs[0], leg)
    }

    func testReversingRunsStopsAndShapesBackwards() {
        let points = (0..<300).map { point($0) }
        let route = Route(name: "Long", points: points)
        XCTAssertEqual(route.reversed().points, points.reversed())
        XCTAssertEqual(route.reversed().reversed(), route)
    }

    func testReplacingPointsKeepsTheStructure() throws {
        let route = Route(name: "Long", points: (0..<300).map { point($0) })
        var updated = route.points
        updated[150].elevation = 999
        updated[0].elevation = 111
        let result = try XCTUnwrap(route.replacingPoints(updated))
        XCTAssertEqual(result.points, updated)
        XCTAssertEqual(result.stops.count, route.stops.count)
        XCTAssertNil(route.replacingPoints(Array(updated.dropLast())))
    }

    func testCodableRoundTripKeepsStopsLegsAndProfile() throws {
        var route = Route.planned(
            name: "Planned", stops: [0, 5, 10].map { RouteStop(coordinate: point($0).coordinate) },
            line: (0..<11).map { point($0) }, profileID: UUID(), color: ItemColor(red: 1, green: 0, blue: 0)
        )
        route.updateStop(at: 1) { $0.isShaping = true; $0.name = "Shape" }
        let decoded = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded, route)
    }
}
