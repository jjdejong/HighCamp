@testable import BaseCampCore
import XCTest

final class GentleClimbRouteSourceTests: XCTestCase {
    /// A router whose route length depends on the climbing cost asked for, and which records the requests.
    private final class Router: @unchecked Sendable {
        var lengths: [Double: Double]
        var failing: Set<Double> = []
        /// The height the route without the climbing cost gains.
        var ascent = 0.0
        private(set) var asked: [[String: Double]] = []

        init(lengths: [Double: Double]) {
            self.lengths = lengths
        }

        func source(_ options: [String: Double]) -> RouteSource {
            asked.append(options)
            let strength = options["uphillcost"] ?? 0
            return Fixed(length: lengths[strength], ascent: strength == 0 ? ascent : 0, fails: failing.contains(strength))
        }
    }

    private struct Fixed: RouteSource {
        let length: Double?
        let ascent: Double
        let fails: Bool

        func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
            guard let length, !fails else { throw RouteError.noRoute("none") }
            return RouteGeometry(points: [], lengthMeters: length, ascentMeters: ascent)
        }
    }

    private let points = [Coordinate(latitude: 45.17, longitude: 5.55), Coordinate(latitude: 45.2, longitude: 5.59)]

    private func route(_ router: Router, maxGrade: Double = 12, maxDetour: Double = 50) async throws -> RouteGeometry {
        let profile = RoutingProfile(name: "MTB", brouterProfile: "mtb", maxGradePercent: maxGrade, maxDetourPercent: maxDetour)
        return try await XCTUnwrap(GentleClimbRouteSource(profile: profile) { router.source($0) })
            .route(via: points, nogos: [])
    }

    func testAProfileWithoutAGradeLimitOrWithAClimbingLimitHasNone() {
        let fixed: GentleClimbRouteSource.Source = { _ in Fixed(length: 1, ascent: 0, fails: false) }
        XCTAssertNil(GentleClimbRouteSource(profile: RoutingProfile(name: "Flat", brouterProfile: "trekking"), source: fixed))
        let refusing = RoutingProfile(name: "MTB", brouterProfile: "mtb", maxGradePercent: 12, maxClimbPercent: 20)
        XCTAssertNil(GentleClimbRouteSource(profile: refusing, source: fixed))
    }

    func testSwitchbacksMayTakeTheLengthTheClimbNeedsAtTheLimit() async throws {
        // Route 180's second leg: 4361 m straight up 449 m, 8311 m by the switchbacks; 50% alone allows 6542 m.
        let router = Router(lengths: [0: 4361, 1000: 8311, 600: 8311, 300: 6567])
        router.ascent = 449
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 8311)
        let profile = RoutingProfile(name: "MTB", brouterProfile: "mtb", maxGradePercent: 12, maxDetourPercent: 50)
        XCTAssertEqual(profile.longestDetour(directMeters: 4361, ascentMeters: 449), 4361 * 1.5 + 449 / 0.12, accuracy: 0.01)
    }

    func testClimbingIsCountedFromJustBelowTheLimit() {
        XCTAssertEqual(GentleClimbRouteSource.options(maxGradePercent: 12, strength: 600), ["uphillcutoff": 10, "uphillcost": 600])
        XCTAssertEqual(GentleClimbRouteSource.options(maxGradePercent: 4, strength: 300)["uphillcutoff"], 3)
    }

    func testTheStrongestCostWithinTheDetourLimitIsTaken() async throws {
        let router = Router(lengths: [0: 5000, 1000: 13000, 600: 7400, 300: 6000])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 7400)
        XCTAssertEqual(router.asked.map { $0["uphillcost"] }, [nil, 1000, 600])
    }

    func testAShorterGentleRouteIsTakenAtOnce() async throws {
        let router = Router(lengths: [0: 6220, 1000: 5160, 600: 5160, 300: 5160])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 5160)
        XCTAssertEqual(router.asked.count, 2)
    }

    func testThePlainRouteIsKeptWhenEveryGentleOneIsTooLong() async throws {
        let router = Router(lengths: [0: 5000, 1000: 9000, 600: 8000, 300: 7600])
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 5000)
    }

    func testAFailedGentleRequestFallsToTheNextStrength() async throws {
        let router = Router(lengths: [0: 5000, 1000: 5500, 600: 5600, 300: 5700])
        router.failing = [1000]
        let route = try await route(router)
        XCTAssertEqual(route.lengthMeters, 5600)
    }
}
