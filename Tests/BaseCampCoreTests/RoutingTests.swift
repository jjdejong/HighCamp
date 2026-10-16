import XCTest
@testable import BaseCampCore

/// Points every ten metres along a north-running line, with heights from `height(distance)`.
private func northLine(lengthMeters: Double, height: (Double) -> Double?) -> [CoursePoint] {
    let start = 45.0
    let stepDegrees = 10.0 / 111_320
    let count = Int(lengthMeters / 10) + 1
    return (0..<count).map { index in
        let distance = Double(index) * 10
        return CoursePoint(
            coordinate: Coordinate(latitude: start + Double(index) * stepDegrees, longitude: 5.0),
            elevation: height(distance)
        )
    }
}

/// Flat until 400 m, then a 15% climb for 400 m: long enough to trigger a detour.
private func longClimbHeight(_ distance: Double) -> Double {
    300 + 0.15 * min(max(distance - 400, 0), 400)
}

/// Flat until 400 m, then a 15% climb to 600 m, then flat again.
private func steepClimbHeight(_ distance: Double) -> Double {
    300 + 0.15 * min(max(distance - 400, 0), 200)
}

final class GradeAnalysisTests: XCTestCase {
    func testFlatRouteHasNoSteepSections() {
        let points = northLine(lengthMeters: 1000) { _ in 300 }

        XCTAssertEqual(GradeAnalysis.steepSections(in: points, maxGradePercent: 5), [])
    }

    func testClimbSteeperThanLimitIsFoundNearItsPosition() throws {
        let points = northLine(lengthMeters: 1000, height: steepClimbHeight)

        let sections = GradeAnalysis.steepSections(in: points, maxGradePercent: 12)

        XCTAssertEqual(sections.count, 1)
        // The climb runs from 400 m to 600 m. Grades are centred on each point, so the ends land
        // within half a window (20 m) of the true ends.
        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(section.startMeters, 400, accuracy: 25)
        XCTAssertEqual(section.endMeters, 600, accuracy: 25)
        XCTAssertEqual(section.maxGradePercent, 15, accuracy: 0.5)
    }

    func testClimbWithinLimitIsNotFlagged() {
        let points = northLine(lengthMeters: 1000, height: steepClimbHeight)

        XCTAssertEqual(GradeAnalysis.steepSections(in: points, maxGradePercent: 16), [])
    }

    func testDescentsAreIgnored() {
        let points = northLine(lengthMeters: 1000) { 500 - 0.2 * $0 }

        XCTAssertEqual(GradeAnalysis.steepSections(in: points, maxGradePercent: 5), [])
    }

    func testTwoClimbsCloseTogetherAreOneSection() {
        let points = northLine(lengthMeters: 1000) { distance in
            let first = 0.2 * min(max(distance - 300, 0), 50)
            let second = 0.2 * min(max(distance - 360, 0), 50)
            return 300 + first + second - 0.2 * min(max(distance - 350, 0), 10) * 0
        }

        XCTAssertEqual(GradeAnalysis.steepSections(in: points, maxGradePercent: 12).count, 1)
    }

    func testHeightErrorsAreNotTreatedAsClimbs() {
        // A single 20 m height spike over 10 m of route reads as a 200% grade.
        let points = northLine(lengthMeters: 500) { distance in
            300 + (distance == 250 ? 20 : 0)
        }

        XCTAssertEqual(GradeAnalysis.steepSections(in: points, maxGradePercent: 12), [])
    }

    func testRouteWithoutHeightsGivesNoSections() {
        let points = northLine(lengthMeters: 500) { _ in nil }

        XCTAssertEqual(GradeAnalysis.steepSections(in: points, maxGradePercent: 5), [])
    }
}

final class BRouterClientTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:17777")!

    func testRequestCarriesProfilePointsAndNoGoAreas() throws {
        let url = BRouterClient.requestURL(
            baseURL: base,
            profile: "mtb",
            via: [Coordinate(latitude: 45.0433, longitude: 3.8856), Coordinate(latitude: 45.05, longitude: 3.9)],
            nogos: [NoGo(center: Coordinate(latitude: 45.1, longitude: 3.9), radiusMeters: 60.4)]
        )

        XCTAssertEqual(url.path, "/brouter")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("lonlats"), "3.885600,45.043300|3.900000,45.050000")
        XCTAssertEqual(value("profile"), "mtb")
        XCTAssertEqual(value("format"), "geojson")
        XCTAssertEqual(value("nogos"), "3.900000,45.100000,60")
    }

    func testRequestWithoutNoGoAreasOmitsThem() throws {
        let url = BRouterClient.requestURL(baseURL: base, profile: "trekking", via: [], nogos: [])

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertNil(items.first { $0.name == "nogos" })
    }

    func testParsesGeoJSONWithHeights() throws {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
         "properties":{"track-length":"1500","filtered ascend":"42","total-time":"300"},
         "geometry":{"type":"LineString","coordinates":[[3.0,45.0,300.5],[3.001,45.0,301.0],[3.002,45.001,305]]}}]}
        """

        let route = try BRouterClient.parse(Data(json.utf8))

        XCTAssertEqual(route.points.count, 3)
        XCTAssertEqual(route.points[0].elevation, 300.5)
        XCTAssertEqual(route.points[0].coordinate.latitude, 45.0)
        XCTAssertEqual(route.points[0].coordinate.longitude, 3.0)
        XCTAssertEqual(route.lengthMeters, 1500)
        XCTAssertEqual(route.ascentMeters, 42)
        XCTAssertEqual(route.durationSeconds, 300)
    }

    func testTwoStopsOnTheSameRouterPointGiveALineOfOnePlace() throws {
        // BRouter's answer when both stops are nearest to the same point of a way: one point, length 0.
        let json = #"""
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"track-length":"0","filtered ascend":"0","total-time":"0"},
        "geometry":{"type":"LineString","coordinates":[[5.669503,45.165251,552.5]]}}]}
        """#
        let route = try BRouterClient.parse(Data(json.utf8))
        XCTAssertEqual(route.points.count, 2)
        XCTAssertEqual(route.points[0], route.points[1])
        XCTAssertEqual(route.lengthMeters, 0)
        let empty = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[]}}]}"#
        XCTAssertThrowsError(try BRouterClient.parse(Data(empty.utf8)))
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try BRouterClient.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? RouteError, .malformedResponse)
        }
    }

    func testMissingMapDataIsReportedAsSuch() async {
        let client = BRouterClient(baseURL: base, profile: "mtb") { _ in
            (400, Data("datafile E0_N0.rd5 not found".utf8))
        }

        do {
            _ = try await client.route(via: [], nogos: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RouteError, .missingSegments("datafile E0_N0.rd5 not found"))
        }
    }

    func testNoRouteIsReportedAsSuch() async {
        let client = BRouterClient(baseURL: base, profile: "mtb") { _ in
            (400, Data("no track found".utf8))
        }

        do {
            _ = try await client.route(via: [], nogos: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RouteError, .noRoute("no track found"))
        }
    }

    func testAnyHTTPReplyMeansReachable() async {
        let client = BRouterClient(baseURL: base, profile: "mtb") { _ in (404, Data()) }

        let reachable = await client.isReachable()

        XCTAssertTrue(reachable)
    }

    func testRefusedConnectionMeansUnreachable() async {
        struct Refused: Error {}
        let client = BRouterClient(baseURL: base, profile: "mtb") { _ in throw Refused() }

        let reachable = await client.isReachable()

        XCTAssertFalse(reachable)
    }

    func testServerErrorsAreReported() async {
        let client = BRouterClient(baseURL: base, profile: "mtb") { _ in
            (500, Data("internal".utf8))
        }

        do {
            _ = try await client.route(via: [], nogos: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RouteError, .server(500, "internal"))
        }
    }
}

/// A router with a steep direct road and a flat detour. The detour is used whenever there are no-go areas.
private struct FakeRouter: RouteSource {
    let direct: RouteGeometry
    let detour: RouteGeometry
    var refuseWhenAvoiding = false

    func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
        if nogos.isEmpty {
            return direct
        }
        if refuseWhenAvoiding {
            throw RouteError.noRoute("no track found")
        }
        return detour
    }
}

private func geometry(_ points: [CoursePoint]) -> RouteGeometry {
    let length = GradeAnalysis.cumulativeDistances(points).last ?? 0
    return RouteGeometry(points: points, lengthMeters: length, ascentMeters: 0)
}

final class ConstrainedRouterTests: XCTestCase {
    private let via = [Coordinate(latitude: 45.0, longitude: 5.0), Coordinate(latitude: 45.0, longitude: 5.02)]

    private func steepDirect() -> RouteGeometry {
        geometry(northLine(lengthMeters: 1000, height: longClimbHeight))
    }

    private func flatDetour() -> RouteGeometry {
        geometry(northLine(lengthMeters: 1300) { _ in 300 })
    }

    func testAvoidsSteepClimbWhenDetourIsAcceptable() async throws {
        let router = FakeRouter(direct: steepDirect(), detour: flatDetour())
        let profile = RoutingProfile(name: "test", brouterProfile: "mtb", maxGradePercent: 12, maxDetourPercent: 50)

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: router)

        XCTAssertEqual(plan.passes, 1)
        XCTAssertEqual(plan.remainingSteepSections, [])
        XCTAssertEqual(plan.geometry, flatDetour())
        XCTAssertEqual(plan.directLengthMeters, 1000, accuracy: 15)
    }

    func testKeepsSteepRouteWhenDetourIsTooLong() async throws {
        let router = FakeRouter(direct: steepDirect(), detour: flatDetour())
        let profile = RoutingProfile(name: "test", brouterProfile: "mtb", maxGradePercent: 12, maxDetourPercent: 20)

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: router)

        XCTAssertEqual(plan.geometry, steepDirect())
        XCTAssertEqual(plan.remainingSteepSections.count, 1)
    }

    func testKeepsSteepRouteWhenRouterCannotAvoidIt() async throws {
        let router = FakeRouter(direct: steepDirect(), detour: flatDetour(), refuseWhenAvoiding: true)
        let profile = RoutingProfile(name: "test", brouterProfile: "mtb", maxGradePercent: 12)

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: router)

        XCTAssertEqual(plan.geometry, steepDirect())
        XCTAssertEqual(plan.remainingSteepSections.count, 1)
    }

    func testWithoutAGradeLimitTheDirectRouteIsReturned() async throws {
        let router = FakeRouter(direct: steepDirect(), detour: flatDetour())
        let profile = RoutingProfile(name: "test", brouterProfile: "trekking")

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: router)

        XCTAssertEqual(plan.passes, 0)
        XCTAssertEqual(plan.geometry, steepDirect())
        XCTAssertEqual(plan.remainingSteepSections, [])
    }

    func testShortClimbDoesNotTriggerDetour() async throws {
        // A 200 m climb is below the default 300 m trigger, so the direct route is kept.
        let direct = geometry(northLine(lengthMeters: 1000, height: steepClimbHeight))
        let router = FakeRouter(direct: direct, detour: flatDetour())
        let profile = RoutingProfile(name: "test", brouterProfile: "mtb", maxGradePercent: 12)

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: router)

        XCTAssertEqual(plan.passes, 0)
        XCTAssertEqual(plan.geometry, direct)
        XCTAssertEqual(plan.remainingSteepSections, [])
    }

    func testTriggerDistanceCanBeLowered() async throws {
        let direct = geometry(northLine(lengthMeters: 1000, height: steepClimbHeight))
        let router = FakeRouter(direct: direct, detour: flatDetour())
        let profile = RoutingProfile(name: "test", brouterProfile: "mtb", maxGradePercent: 12, minimumClimbMeters: 100)

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: router)

        XCTAssertEqual(plan.passes, 1)
        XCTAssertEqual(plan.geometry, flatDetour())
    }

    func testLooserLimitAcceptsTheSameClimb() async throws {
        let router = FakeRouter(direct: steepDirect(), detour: flatDetour())
        let profile = RoutingProfile(name: "test", brouterProfile: "mtb", maxGradePercent: 16)

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: router)

        XCTAssertEqual(plan.passes, 0)
        XCTAssertEqual(plan.geometry, steepDirect())
    }
}

/// Route source whose direct line runs at longitude 5.0 and whose detour runs at 5.01, so a terrain
/// model can put the climb on the direct line only.
private struct OffsetRouter: RouteSource {
    func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
        let longitude = nogos.isEmpty ? 5.0 : 5.01
        let points = (0...130).map { index in
            CoursePoint(
                coordinate: Coordinate(latitude: 45.0 + Double(index) * 10 / 111_320, longitude: longitude),
                elevation: 300
            )
        }
        return RouteGeometry(points: points, lengthMeters: 1300, ascentMeters: 0)
    }
}

/// The terrain height at a coordinate of `northLine`: the same climb, found from its latitude.
private func terrainHeight(_ coordinate: Coordinate) -> Double {
    longClimbHeight((coordinate.latitude - 45.0) * 111_320)
}

final class ElevatedRouteSourceTests: XCTestCase {
    private let via = [Coordinate(latitude: 45.0, longitude: 5.0), Coordinate(latitude: 45.0, longitude: 5.02)]

    func testTerrainHeightsReplaceTheRouterHeightsAndTheAscent() async throws {
        // The router reports a flat road. The terrain has the climb from 400 m to 800 m, 60 m in all.
        let flat = FakeRouter(direct: geometry(northLine(lengthMeters: 1000) { _ in 300 }), detour: geometry(northLine(lengthMeters: 1300) { _ in 300 }))
        let source = ElevatedRouteSource(base: flat) { (coordinates: [Coordinate]) -> [Double?] in
            coordinates.map { (coordinate: Coordinate) -> Double? in terrainHeight(coordinate) }
        }

        let route = try await source.route(via: via, nogos: [])

        XCTAssertEqual(route.points.first?.elevation ?? 0, 300, accuracy: 0.5)
        XCTAssertEqual(route.points.last?.elevation ?? 0, 360, accuracy: 0.5)
        XCTAssertEqual(route.ascentMeters, 60, accuracy: 1.5)
        XCTAssertEqual(route.lengthMeters, 1000, accuracy: 15)
    }

    func testRouterHeightsStayWhenTheTerrainDoesNotCoverTheWholeRoute() async throws {
        let direct = geometry(northLine(lengthMeters: 1000) { _ in 300 })
        let flat = FakeRouter(direct: direct, detour: geometry(northLine(lengthMeters: 1300) { _ in 300 }))
        // No terrain height for the last point, so the route keeps the router's heights everywhere.
        let source = ElevatedRouteSource(base: flat) { (coordinates: [Coordinate]) -> [Double?] in
            coordinates.enumerated().map { (index: Int, coordinate: Coordinate) -> Double? in
                index == coordinates.count - 1 ? nil : terrainHeight(coordinate)
            }
        }

        let route = try await source.route(via: via, nogos: [])

        XCTAssertEqual(route, direct)
    }

    func testPlannerDetoursAroundAClimbOnlyTheTerrainShows() async throws {
        // The router's own heights are flat everywhere. Only the terrain shows the climb, on the direct line.
        let source = ElevatedRouteSource(base: OffsetRouter()) { (coordinates: [Coordinate]) -> [Double?] in
            coordinates.map { (coordinate: Coordinate) -> Double? in
                coordinate.longitude < 5.005 ? terrainHeight(coordinate) : 300
            }
        }
        let profile = RoutingProfile(name: "test", brouterProfile: "mtb", maxGradePercent: 12, maxDetourPercent: 50)

        let plan = try await ConstrainedRouter.plan(via: via, profile: profile, source: source)

        XCTAssertEqual(plan.directLengthMeters, 1300, accuracy: 15)
        XCTAssertEqual(plan.passes, 1)
        XCTAssertEqual(plan.remainingSteepSections, [])
    }
}

final class RoutingProfileCodingTests: XCTestCase {
    func testProfileSavedBeforeTheTriggerExistedLoadsWithTheDefault() throws {
        let json = """
        {"id":"6A1F0C3E-0001-4B2E-9C11-000000000001","name":"Old","brouterProfile":"mtb",
         "maxGradePercent":12,"maxDetourPercent":50,"maxPasses":4}
        """

        let profile = try JSONDecoder().decode(RoutingProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.maxGradePercent, 12)
        XCTAssertEqual(profile.minimumClimbMeters, 300)
    }

    func testTheTriggerSurvivesASaveAndLoad() throws {
        let profile = RoutingProfile(name: "Custom", brouterProfile: "mtb", maxGradePercent: 15, minimumClimbMeters: 450)

        let data = try JSONEncoder().encode(profile)
        let loaded = try JSONDecoder().decode(RoutingProfile.self, from: data)

        XCTAssertEqual(loaded, profile)
        XCTAssertEqual(loaded.minimumClimbMeters, 450)
    }
}
