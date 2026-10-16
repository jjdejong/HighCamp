import BaseCampCore
import XCTest

/// What HighCamp's own BRouter needs: which map data tiles cover a route, and a profile that also reports
/// tunnels and bridges.
final class BRouterSetupTests: XCTestCase {
    func testTilesAreFiveDegreeSquaresNamedByTheirSouthWestCorner() {
        XCTAssertEqual(BRouterSegments.name(for: Coordinate(latitude: 45.17, longitude: 5.67)), "E5_N45")
        XCTAssertEqual(BRouterSegments.name(for: Coordinate(latitude: 44.99, longitude: 4.99)), "E0_N40")
        XCTAssertEqual(BRouterSegments.name(for: Coordinate(latitude: 43.3, longitude: -1.2)), "W5_N40")
        XCTAssertEqual(BRouterSegments.name(for: Coordinate(latitude: -3, longitude: 10)), "E10_S5")
        XCTAssertEqual(BRouterSegments.name(for: Coordinate(latitude: 50, longitude: 0)), "E0_N50")
    }

    func testTheTilesForARouteCoverItsLineBetweenStops() {
        // Grenoble to Geneva crosses from E5_N45 into... still E5_N45; Lyon to Turin crosses 5° E.
        let lyon = Coordinate(latitude: 45.76, longitude: 4.84), turin = Coordinate(latitude: 45.07, longitude: 7.69)
        XCTAssertEqual(BRouterSegments.names(covering: [lyon, turin]), ["E0_N45", "E5_N45"])
        let paris = Coordinate(latitude: 48.85, longitude: 2.35), lyonAgain = lyon
        XCTAssertEqual(BRouterSegments.names(covering: [paris, lyonAgain]), ["E0_N45"])
        XCTAssertEqual(BRouterSegments.names(covering: []), [])
    }

    func testTheProfileCopyReadsTunnelsAndBridgesInTheWayContext() throws {
        let profile = """
        ---context:global
        assign validForBikes = true
        ---context:way
        assign costfactor = 1
        ---context:node
        assign initialcost = 0
        """
        let copy = BRouterProfileText.reportingStructures(profile)
        let way = try XCTUnwrap(copy.range(of: "---context:way")), node = try XCTUnwrap(copy.range(of: "---context:node"))
        let tunnel = try XCTUnwrap(copy.range(of: "tunnel=yes")), bridge = try XCTUnwrap(copy.range(of: "bridge=yes"))
        XCTAssertTrue(way.upperBound < tunnel.lowerBound && tunnel.upperBound < node.lowerBound)
        XCTAssertTrue(way.upperBound < bridge.lowerBound && bridge.upperBound < node.lowerBound)
        XCTAssertTrue(copy.contains("assign costfactor = 1"))
        // A profile without a node context gets the lines at its end.
        XCTAssertTrue(BRouterProfileText.reportingStructures("---context:way\nassign x = 1\n").hasSuffix("bridge=yes\n"))
    }
}
