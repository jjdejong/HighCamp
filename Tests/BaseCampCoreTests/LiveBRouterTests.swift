import XCTest
@testable import BaseCampCore

/// Plans a route on a running BRouter server. Skipped unless BROUTER_VIA is set, for example:
///   BROUTER_VIA="5.6100,45.1500|5.6600,45.1900" BROUTER_PROFILE=mtb BROUTER_MAX_GRADE=12 swift test --filter LiveBRouterTests
final class LiveBRouterTests: XCTestCase {
    func testPlanOnLiveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let via = env["BROUTER_VIA"] else {
            throw XCTSkip("set BROUTER_VIA to run against a live BRouter server")
        }
        let points = via.split(separator: "|").map { pair -> Coordinate in
            let parts = pair.split(separator: ",").compactMap { Double($0) }
            return Coordinate(latitude: parts[1], longitude: parts[0])
        }
        let profile = RoutingProfile(
            name: "live",
            brouterProfile: env["BROUTER_PROFILE"] ?? "mtb",
            maxGradePercent: Double(env["BROUTER_MAX_GRADE"] ?? "12"),
            maxDetourPercent: Double(env["BROUTER_MAX_DETOUR"] ?? "50") ?? 50
        )
        let client = BRouterClient(baseURL: URL(string: "http://127.0.0.1:17777")!, profile: profile.brouterProfile)

        let plan = try await ConstrainedRouter.plan(via: points, profile: profile, source: client) { print("PROGRESS \($0)") }

        print("DIRECT \(Int(plan.directLengthMeters)) m")
        print("FINAL \(Int(plan.geometry.lengthMeters)) m, ascent \(Int(plan.geometry.ascentMeters)) m, points \(plan.geometry.points.count)")
        print("PASSES \(plan.passes)")
        let maxGrade = profile.maxGradePercent ?? 0
        let steepDirect = GradeAnalysis.steepSections(in: try await client.route(via: points, nogos: []).points, maxGradePercent: maxGrade)
        print("STEEP_DIRECT \(steepDirect.count) sections, \(Int(steepDirect.reduce(0) { $0 + $1.lengthMeters })) m")
        print("STEEP_REMAINING \(plan.remainingSteepSections.count) sections, \(Int(plan.remainingSteepSections.reduce(0) { $0 + $1.lengthMeters })) m")
        for section in plan.remainingSteepSections {
            print("  at \(Int(section.startMeters))-\(Int(section.endMeters)) m, max \(String(format: "%.1f", section.maxGradePercent))%")
        }
    }
}
