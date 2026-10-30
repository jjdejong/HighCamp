@testable import BaseCampCore
import XCTest

final class GentleClimbRouteSourceTests: XCTestCase {
    /// A router whose route length depends on the climbing cost asked for, and which records the requests.
    private final class Router: @unchecked Sendable {
        var lengths: [Double: Double]
        var failing: Set<Double> = []
        private(set) var asked: [[String: Double]] = []

        init(lengths: [Double: Double]) {
            self.lengths = lengths
        }

        func source(_ options: [String: Double]) -> RouteSource {
            asked.append(options)
            return Fixed(length: lengths[options["uphillcost"] ?? 0], fails: failing.contains(options["uphillcost"] ?? 0))
        }
    }

    private struct Fixed: RouteSource {
        let length: Double?
        let fails: Bool

        func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
            guard let length, !fails else { throw RouteError.noRoute("none") }
            return RouteGeometry(points: [], lengthMeters: length, ascentMeters: 0)
        }
    }

    private let points = [Coordinate(latitude: 45.17, longitude: 5.55), Coordinate(latitude: 45.2, longitude: 5.59)]

    private func route(_ router: Router, maxGrade: Double = 12, maxDetour: Double = 50) async throws -> RouteGeometry {
        try await GentleClimbRouteSource(maxGradePercent: maxGrade, maxDetourPercent: maxDetour) { router.source($0) }
            .route(via: points, nogos: [])
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
