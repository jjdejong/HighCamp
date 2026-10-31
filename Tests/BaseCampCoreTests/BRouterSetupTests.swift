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

    func testMountainBikeRoutesCountAsCycleRoutes() {
        // As in BRouter's mtb profile, where the assignment spans lines and the next one is indented.
        let mtb = """
        ---context:way
        assign any_cycleroute
          switch not use_proposed_cycleroutes
            or route_bicycle_icn=yes route_bicycle_lcn=yes
            or route_bicycle_icn=yes|proposed route_bicycle_lcn=yes|proposed

          assign nodeaccessgranted or any_cycleroute any_cn
        ---context:node
        """
        let copy = BRouterProfileText.countingMountainBikeRoutes(mtb)
        let lines = copy.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "assign highcamp_bike_route")
        let added = lines.firstIndex { $0.hasPrefix("assign any_cycleroute") }!
        XCTAssertEqual(lines[added], "assign any_cycleroute or highcamp_bike_route highcamp_mtb_route")
        XCTAssertTrue(lines[added - 1].hasPrefix("assign highcamp_mtb_route or route_mtb_=yes or route_mtb_lcn=yes"))
        XCTAssertTrue(lines[added - 1].hasSuffix("route_mtb_mtb=yes route_bicycle_mtb=yes"))
        XCTAssertGreaterThan(added, lines.firstIndex { $0.contains("route_bicycle_lcn=yes|proposed") }!, "after the whole old assignment")
        XCTAssertLessThan(added, lines.firstIndex { $0.contains("assign nodeaccessgranted") }!, "before its first use")

        // As in the trekking profile, with "=".
        let trekking = "assign any_cycleroute =\n  if a then true\n  else false\n\nassign nodeaccessgranted =\n"
        XCTAssertTrue(BRouterProfileText.countingMountainBikeRoutes(trekking).hasPrefix("assign highcamp_bike_route =\n  if a then true"))

        let hiking = "---context:way\nassign x = 1\n"
        XCTAssertEqual(BRouterProfileText.countingMountainBikeRoutes(hiking), hiking)
    }
}
