import Foundation

/// Routes with another source, then gives the route the heights from `heights`, such as a terrain model.
/// Steep sections are judged on these heights, so a router's own heights do not decide them.
///
/// The terrain heights are used only when they cover every point of the route. Mixing two height sources
/// would put false grades where they meet, so a partly covered route keeps the router's heights.
public struct ElevatedRouteSource: RouteSource {
    /// The height of each coordinate, or nil where there is none. One result for each coordinate.
    public typealias Heights = @Sendable ([Coordinate]) -> [Double?]

    private let base: RouteSource
    private let heights: Heights

    public init(base: RouteSource, heights: @escaping Heights) {
        self.base = base
        self.heights = heights
    }

    public func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
        var route = try await base.route(via: points, nogos: nogos)
        let values = heights(route.points.map(\.coordinate))
        guard values.count == route.points.count, values.allSatisfy({ $0 != nil }) else {
            return route
        }
        for index in route.points.indices {
            route.points[index].elevation = values[index]
        }
        // The ascent follows the new heights, counted the same way as the ride statistics.
        let found = values.compactMap { $0 }
        route.ascentMeters = ActivityStatistics.climb(found, threshold: ActivityStatistics.elevationNoise)?.ascent ?? 0
        return route
    }
}
