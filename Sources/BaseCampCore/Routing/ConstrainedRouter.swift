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
    /// Each pass puts a circle over every steep section and asks the router again. A candidate is kept
    /// only when it has less steep road and does not exceed the detour limit. The best route found is
    /// returned, with any sections that could not be avoided.
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

        let longestAllowed = direct.lengthMeters * (1 + profile.maxDetourPercent / 100)
        var best = direct
        var bestSteep = triggering(
            GradeAnalysis.steepSections(in: direct.points, maxGradePercent: maxGrade),
            profile: profile
        )
        var nogos: [NoGo] = []
        var passes = 0

        while !bestSteep.isEmpty && passes < profile.maxPasses {
            passes += 1
            progress("Pass \(passes): avoiding \(bestSteep.count) climb(s) above \(Int(maxGrade))%")

            // Never put an area over a via point, or the router cannot start or finish there.
            let fresh = bestSteep.map { NoGo(center: $0.center, radiusMeters: radius(for: $0)) }
                .filter { area in points.allSatisfy { Geodesy.distance(from: $0, to: area.center) > area.radiusMeters + 30 } }
            guard !fresh.isEmpty else { break }
            nogos += fresh

            let candidate: RouteGeometry
            do {
                candidate = try await source.route(via: points, nogos: nogos)
            } catch RouteError.noRoute {
                break
            }
            guard candidate.lengthMeters <= longestAllowed else { break }

            let steep = triggering(
                GradeAnalysis.steepSections(in: candidate.points, maxGradePercent: maxGrade),
                profile: profile
            )
            guard totalLength(steep) < totalLength(bestSteep) else { break }
            best = candidate
            bestSteep = steep
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

    /// Covers the whole steep section, plus a margin so the router does not skirt its edge.
    static func radius(for section: SteepSection) -> Double {
        max(40, section.lengthMeters / 2 + 30)
    }

    private static func totalLength(_ sections: [SteepSection]) -> Double {
        sections.reduce(0) { $0 + $1.lengthMeters }
    }
}
