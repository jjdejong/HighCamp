@testable import BaseCampCore
import XCTest

final class GentleClimbRouteSourceTests: XCTestCase {
    /// A route along a meridian, a point every 10 m, flat but for `steep` metres climbing at 30% halfway.
    private static func geometry(length: Double, steep: Double = 0, ascent: Double = 0) -> RouteGeometry {
        let start = (length - steep) / 2
        let points = stride(from: 0.0, through: length, by: 10).map { distance in
            CoursePoint(coordinate: Coordinate(latitude: 45 + distance / 111_320, longitude: 5),
                        elevation: 500 + min(max(distance - start, 0), steep) * 0.3)
        }
        return RouteGeometry(points: points, lengthMeters: length, ascentMeters: ascent)
    }

    /// A router whose route depends on the climbing cost asked for, and which records the requests.
    private final class Router: @unchecked Sendable {
        var routes: [Double: RouteGeometry]
        var failing: Set<Double> = []
        private(set) var asked: [[String: Double]] = []

        init(_ routes: [Double: RouteGeometry]) {
            self.routes = routes
        }

        func source(_ options: [String: Double]) -> RouteSource {
            asked.append(options)
            let strength = options["uphillcost"] ?? 0
            return Fixed(route: failing.contains(strength) ? nil : routes[strength])
        }
    }

    private struct Fixed: RouteSource {
        let route: RouteGeometry?

        func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
            guard let route else { throw RouteError.noRoute("none") }
            return route
        }
    }

    private let points = [Coordinate(latitude: 45.17, longitude: 5.55), Coordinate(latitude: 45.2, longitude: 5.59)]

    private func route(_ router: Router, maxClimb: Double? = 20) async throws -> RouteGeometry {
        let profile = RoutingProfile(name: "MTB", brouterProfile: "mtb", maxGradePercent: 12, maxDetourPercent: 50, maxClimbPercent: maxClimb)
        return try await XCTUnwrap(GentleClimbRouteSource(profile: profile) { router.source($0) })
            .route(via: points, nogos: [])
    }

    func testOnlyAProfileWithAGradeLimitHasOne() {
        let fixed: GentleClimbRouteSource.Source = { _ in Fixed(route: nil) }
        XCTAssertNil(GentleClimbRouteSource(profile: RoutingProfile(name: "Flat", brouterProfile: "trekking"), source: fixed))
        let refusing = RoutingProfile(name: "MTB", brouterProfile: "mtb", maxGradePercent: 12, maxClimbPercent: 20)
        XCTAssertNotNil(GentleClimbRouteSource(profile: refusing, source: fixed))
    }

    func testClimbingIsCountedFromJustBelowTheLimit() {
        XCTAssertEqual(GentleClimbRouteSource.options(maxGradePercent: 12, strength: 600), ["uphillcutoff": 10, "uphillcost": 600])
        XCTAssertEqual(GentleClimbRouteSource.options(maxGradePercent: 4, strength: 300)["uphillcutoff"], 3)
    }

    func testTheRouteWithTheLeastSteepLengthIsTaken() async throws {
        let router = Router([0: Self.geometry(length: 5000, steep: 600), 1000: Self.geometry(length: 7000, steep: 300),
                             600: Self.geometry(length: 7400), 300: Self.geometry(length: 6000, steep: 300)])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 7400)
        XCTAssertEqual(router.asked.map { $0["uphillcost"] }, [nil, 1000, 600, 300])
    }

    func testAStrongerCostThatIsSteeperIsNotTaken() async throws {
        // Route 180's last leg: the strongest cost took 500 m at 21%, the route without it a hairpin.
        let router = Router([0: Self.geometry(length: 4220), 1000: Self.geometry(length: 2761, steep: 500),
                             600: Self.geometry(length: 2761, steep: 500), 300: Self.geometry(length: 2761, steep: 500)])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 4220)
    }

    func testOfRoutesAsSteepTheShortestIsTaken() async throws {
        // Route 180's third leg: the paved road (9.4 km) and the Wix track (8.3 km), neither steeper than the limit.
        let router = Router([0: Self.geometry(length: 9356), 1000: Self.geometry(length: 8311),
                             600: Self.geometry(length: 8311), 300: Self.geometry(length: 9000)])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 8311)
    }

    func testARouteLongerThanTheDetourLimitIsNotTaken() async throws {
        let router = Router([0: Self.geometry(length: 5000, steep: 400), 1000: Self.geometry(length: 9000),
                             600: Self.geometry(length: 8000), 300: Self.geometry(length: 7600)])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 5000)
    }

    func testSwitchbacksMayTakeTheLengthTheClimbNeedsAtTheLimit() async throws {
        // Route 180's third leg straight up: 4361 m climbing 449 m; by the switchbacks 8311 m. 50% alone allows 6542 m.
        let router = Router([0: Self.geometry(length: 4361, steep: 900, ascent: 449), 1000: Self.geometry(length: 8311),
                             600: Self.geometry(length: 8311), 300: Self.geometry(length: 6567, steep: 500)])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 8311)
        let profile = RoutingProfile(name: "MTB", brouterProfile: "mtb", maxGradePercent: 12, maxDetourPercent: 50)
        XCTAssertEqual(profile.longestDetour(directMeters: 4361, ascentMeters: 449), 4361 * 1.5 + 449 / 0.12, accuracy: 0.01)
    }

    func testAFailedRequestIsLeftOut() async throws {
        let router = Router([0: Self.geometry(length: 5000, steep: 400), 1000: Self.geometry(length: 5500),
                             600: Self.geometry(length: 5600), 300: Self.geometry(length: 5700)])
        router.failing = [1000]
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 5600)
    }

    func testWithoutAClimbingLimitTheGradeLimitIsUsed() async throws {
        // Climbs at 30% are over 12% too; a route with less of them wins.
        let router = Router([0: Self.geometry(length: 5000, steep: 400), 1000: Self.geometry(length: 6000, steep: 200),
                             600: Self.geometry(length: 6000, steep: 300), 300: Self.geometry(length: 5500, steep: 400)])
        let route = try await route(router, maxClimb: nil)
        XCTAssertEqual(route.lengthMeters, 6000)
        XCTAssertEqual(route.points.last?.elevation, 560)
    }
}
