import Foundation

/// The result of planning within a profile's limits.
public struct ConstrainedRoutePlan: Equatable, Sendable {
    public let geometry: RouteGeometry
    /// Climbs above the limit that are long enough to trigger a detour and still remain.
    /// Empty when no such climb is left.
    public let remainingSteepSections: [SteepSection]
    /// Avoidance passes that were run.
    public let passes: Int
    /// Length of the plain route, before any avoidance.
    public let directLengthMeters: Double
}

public enum ConstrainedRouter {
    /// Routes through `via`, then, when the profile asks for it, routes around climbs steeper than its threshold.
    ///
    /// Each pass puts a circle over one steep section at a time and asks the router again, and keeps the try with the
    /// least steep road that does not exceed the detour limit. The best route found is returned, with any sections
    /// that could not be avoided.
    public static func plan(
        via points: [Coordinate],
        profile: RoutingProfile,
        source: RouteSource,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> ConstrainedRoutePlan {
        let direct = try await source.route(via: points, nogos: [])
        guard let maxGrade = profile.maxGradePercent, profile.detoursSteepStretches else {
            return ConstrainedRoutePlan(
                geometry: direct,
                remainingSteepSections: [],
                passes: 0,
                directLengthMeters: direct.lengthMeters
            )
        }

        let longestAllowed = profile.longestDetour(directMeters: direct.lengthMeters, ascentMeters: direct.ascentMeters)
        var best = direct
        var bestSteep = triggering(
            GradeAnalysis.steepSections(in: direct.points, maxGradePercent: maxGrade),
            profile: profile
        )
        var nogos: [NoGo] = []
        var passes = 0
        var tried: [Coordinate] = []

        // Each pass tries going round each steep stretch on its own, first with a small area over its middle, then
        // with one covering it all, and keeps the try that leaves the least steep length. Going round all of them
        // at once, or with a large area only, also shut off a way round near the stretch: on Route 180, the road
        // whose bend a 13% path cuts, 30 m from the path.
        while !bestSteep.isEmpty && passes < profile.maxPasses {
            passes += 1
            progress("Pass \(passes): avoiding \(bestSteep.count) climb(s) above \(Int(maxGrade))%")

            var bestTry: (route: RouteGeometry, steep: [SteepSection], area: NoGo)?
            for section in bestSteep where !tried.contains(where: { Geodesy.distance(from: $0, to: section.center) < 30 }) {
                tried.append(section.center)
                for radius in Set([smallRadius, radius(for: section)]).sorted() {
                    let area = NoGo(center: section.center, radiusMeters: radius)
                    // Never put an area over a via point, or the router cannot start or finish there.
                    guard points.allSatisfy({ Geodesy.distance(from: $0, to: area.center) > area.radiusMeters + 30 }) else { continue }
                    guard let candidate = try? await source.route(via: points, nogos: nogos + [area]),
                          candidate.lengthMeters <= longestAllowed else { continue }
                    let steep = triggering(
                        GradeAnalysis.steepSections(in: candidate.points, maxGradePercent: maxGrade),
                        profile: profile
                    )
                    guard totalLength(steep) < totalLength(bestTry?.steep ?? bestSteep)
                        || (totalLength(steep) == totalLength(bestTry?.steep ?? bestSteep)
                            && bestTry.map { candidate.lengthMeters < $0.route.lengthMeters } ?? false) else { continue }
                    bestTry = (candidate, steep, area)
                }
            }
            guard let bestTry else { break }
            nogos.append(bestTry.area)
            best = bestTry.route
            bestSteep = bestTry.steep
        }

        return ConstrainedRoutePlan(
            geometry: best,
            remainingSteepSections: bestSteep,
            passes: passes,
            directLengthMeters: direct.lengthMeters
        )
    }

    /// Only climbs at least as long as the profile's trigger distance are worth a detour.
    static func triggering(_ sections: [SteepSection], profile: RoutingProfile) -> [SteepSection] {
        sections.filter { $0.lengthMeters >= profile.minimumClimbMeters }
    }

    /// The area tried first over a steep stretch's middle: small enough to leave a road passing close by open.
    static let smallRadius = 30.0

    /// Covers the whole steep section, plus a margin so the router does not skirt its edge.
    static func radius(for section: SteepSection) -> Double {
        max(40, section.lengthMeters / 2 + 30)
    }

    private static func totalLength(_ sections: [SteepSection]) -> Double {
        sections.reduce(0) { $0 + $1.lengthMeters }
    }
}
