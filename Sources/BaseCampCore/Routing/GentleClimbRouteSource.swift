import Foundation

/// Routes for a profile with a grade limit, asking BRouter itself to keep off steep climbs.
///
/// BRouter's climbing cost (`uphillcost`) is paid for each metre climbed above a grade (`uphillcutoff`). Counted from
/// 3%, as the mtb profile's "hills 1" does, it barely helps: between two points the height to gain is much the same
/// whichever way, so a 30% ramp costs little more than a long gentle road. Counted only from a little below the
/// limit, it is paid on the steep stretches alone, and BRouter takes a gentler way where there is one.
///
/// A strong cost can send a leg far round, so the strengths are tried from the strongest down, and the first route
/// no longer than the profile's detour limit allows (against the route without it) is taken; else that route.
public struct GentleClimbRouteSource: RouteSource {
    /// A route source sending these settings with each request, besides the profile's own.
    public typealias Source = @Sendable (_ options: [String: Double]) -> RouteSource

    /// The climbing costs tried, strongest first. On the user's legs round Grenoble (26 legs, 141 km), from 1000:
    /// the length above 12% fell from 17.3 to 7.0 km and the steepest 100 m from 46% to 23%, several legs getting
    /// shorter too; some legs more than doubled, which the detour limit turns down to a weaker cost.
    public static let strengths: [Double] = [1000, 600, 300]

    private let source: Source
    private let maxGradePercent: Double
    private let maxDetourPercent: Double

    public init(maxGradePercent: Double, maxDetourPercent: Double, source: @escaping Source) {
        self.source = source
        self.maxGradePercent = maxGradePercent
        self.maxDetourPercent = maxDetourPercent
    }

    /// The settings for one strength: climbing counted from 2% below the limit, and not below 3%.
    public static func options(maxGradePercent: Double, strength: Double) -> [String: Double] {
        ["uphillcutoff": max(3, maxGradePercent - 2), "uphillcost": strength]
    }

    public func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
        let plain = try await source([:]).route(via: points, nogos: nogos)
        let longest = plain.lengthMeters * (1 + maxDetourPercent / 100)
        for strength in Self.strengths {
            let options = Self.options(maxGradePercent: maxGradePercent, strength: strength)
            guard let gentle = try? await source(options).route(via: points, nogos: nogos) else { continue }
            if gentle.lengthMeters <= longest {
                return gentle
            }
        }
        return plain
    }
}
