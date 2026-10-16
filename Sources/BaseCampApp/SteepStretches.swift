import BaseCampCore
import Foundation

/// The stretches of the selected route or track steeper than its profile's threshold, for the map and the profile to
/// mark, so the user can go round them (or that HighCamp's detours could not avoid, when the profile asks for them). A route's limit is its routing
/// profile's; a track's is the profile chosen for planning. Read on the heights the profile shows: the track DEM's
/// when it has one and the profile shows it.
@MainActor
enum SteepStretches {
    struct Result: Equatable {
        /// The threshold, in percent.
        let limit: Double
        let sections: [SteepSection]
        /// Each stretch's average grade, from its start to its end, in percent.
        let averages: [Double]
        /// The colour they are drawn in, standing out from the line's own.
        let colour: ItemColor
    }

    private struct Key: Equatable {
        let item: LibraryItem
        let library: Int
        let dem: Int
        let fromDEM: Bool
        let demPoints: Int
        let limit: Double
    }

    private static var cache: (key: Key, result: Result)?

    /// Grades are measured over this much of the line, longer than the router's 40 m: a few metres of a fine DEM
    /// read along a line that cuts a hairpin's corner would otherwise show steep spikes. Stretches closer together
    /// than this are one.
    static let windowMeters = 100.0
    /// Shorter stretches are left out.
    static let shortestMeters = 50.0

    /// The default line colours, as the map draws them (system blue and orange).
    private static let routeColour = ItemColor(red: 0.0, green: 0.48, blue: 1.0)
    private static let trackColour = ItemColor(red: 1.0, green: 0.58, blue: 0.0)

    static func of(_ item: LibraryItem?, store: LibraryStore, planner: RoutePlanner, trackDEMs: TrackDEMStore, fromDEM: Bool) -> Result? {
        guard let item else { return nil }
        let own: () -> [ElevationProfilePoint]
        let line: ItemColor
        let profileID: UUID?
        switch item {
        case .route(let id):
            guard let route = store.route(id) else { return nil }
            own = { route.elevationProfile }
            line = route.color ?? routeColour
            profileID = route.profileID
        case .track(let id):
            guard let track = store.track(id) else { return nil }
            own = { track.profile(of: .elevation) }
            line = track.color ?? trackColour
            profileID = nil
        case .waypoint:
            return nil
        }
        let profile = profileID.flatMap { id in planner.profiles.first { $0.id == id } } ?? planner.selectedProfile
        guard let limit = profile.maxGradePercent else { return nil }
        let dem = fromDEM ? trackDEMs.cachedProfile(for: item, store: store).flatMap { $0.count > 1 ? $0 : nil } : nil
        let key = Key(item: item, library: store.revision, dem: trackDEMs.revision, fromDEM: fromDEM, demPoints: dem?.count ?? 0, limit: limit)
        if let cache, cache.key == key {
            return cache.result
        }
        let heights = dem ?? own()
        let sections = GradeAnalysis.steepSections(inProfile: heights, maxGradePercent: limit, windowMeters: windowMeters)
            .filter { $0.lengthMeters >= shortestMeters }
        let averages = sections.map { section in
            heights.averageGrade(over: section.startMeters...section.endMeters) ?? section.maxGradePercent
        }
        let result = Result(limit: limit, sections: sections, averages: averages, colour: SteepHighlight.colour(against: line))
        cache = (key, result)
        return result
    }
}
