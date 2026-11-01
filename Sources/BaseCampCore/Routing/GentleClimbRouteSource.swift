import Foundation

/// Routes for a profile with a grade limit, asking BRouter itself to keep off steep climbs.
///
/// BRouter's climbing cost (`uphillcost`) is paid for each metre climbed above a grade (`uphillcutoff`). Counted from
/// 3%, as the mtb profile's "hills 1" does, it barely helps: between two points the height to gain is much the same
/// whichever way, so a 30% ramp costs little more than a long gentle road. Counted only from a little below the
/// limit, it is paid on the steep stretches alone, and BRouter takes a gentler way where there is one.
///
/// The route without the cost and one for each strength are asked for. Of those no longer than the profile allows
/// (`RoutingProfile.longestDetour`, against the route without the cost), the one with the least length steeper than
/// the climbing limit (or else the grade limit) is taken, measured on the heights the routes come with, and of
/// those as steep the shortest. A stronger cost is not always gentler on those heights: BRouter weighs slopes on its
/// own coarse heights, and on Route 180's last leg the strongest took 500 m at 21% where the route without the cost
/// went up by a hairpin, at 13% at most.
public struct GentleClimbRouteSource: RouteSource {
    /// A route source sending these settings with each request, besides the profile's own.
    public typealias Source = @Sendable (_ options: [String: Double]) -> RouteSource

    /// The climbing costs tried. On the user's legs round Grenoble (26 legs, 141 km), from 1000:
    /// the length above 12% fell from 17.3 to 7.0 km and the steepest 100 m from 46% to 23%, several legs getting
    /// shorter too; some legs more than doubled, which the detour limit turns down to a weaker cost.
    public static let strengths: [Double] = [1000, 600, 300]

    private let source: Source
    private let profile: RoutingProfile
    private let maxGradePercent: Double

    /// Nil for a profile without a grade limit.
    ///
    /// With a climbing limit (`maxClimbPercent`) too, short ramps over it get through: BRouter weighs a slope on its
    /// elevation buffer, which counting climbing from just below the grade limit changes. The user wants it so: on
    /// Route 180 the climbing limit alone took 5.6 km of paved road (9.4 km), and with this too the track they meant,
    /// "Wix Tranquille option descente" (8.3 km), whose six ramps over 20% are 50 to 90 m long, the steepest 28%.
    /// Long steep climbs are still refused: over the user's 29 legs of 30 October (152 km), the steepest 50 m fell
    /// from 61% to 30%, and the length over 20% from 17.6 to 6.0 km.
    public init?(profile: RoutingProfile, source: @escaping Source) {
        guard let maxGrade = profile.maxGradePercent else { return nil }
        self.source = source
        self.profile = profile
        maxGradePercent = maxGrade
    }

    /// The settings for one strength: climbing counted from 2% below the limit, and not below 3%.
    public static func options(maxGradePercent: Double, strength: Double) -> [String: Double] {
        ["uphillcutoff": max(3, maxGradePercent - 2), "uphillcost": strength]
    }

    public func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
        let plain = try await source([:]).route(via: points, nogos: nogos)
        let longest = profile.longestDetour(directMeters: plain.lengthMeters, ascentMeters: plain.ascentMeters)
        var candidates = [plain]
        for strength in Self.strengths {
            let options = Self.options(maxGradePercent: maxGradePercent, strength: strength)
            if let gentle = try? await source(options).route(via: points, nogos: nogos), gentle.lengthMeters <= longest {
                candidates.append(gentle)
            }
        }
        let limit = profile.maxClimbPercent ?? maxGradePercent
        let ranked = candidates.map { route in
            (route, steep: GradeAnalysis.steepSections(in: route.points, maxGradePercent: limit).reduce(0) { $0 + $1.lengthMeters })
        }
        return ranked.min { ($0.steep, $0.0.lengthMeters) < ($1.steep, $1.0.lengthMeters) }!.0
    }
}
