import BaseCampCore
import BaseCampDEM
import Foundation
import Observation

/// Plans routes from the points the user clicks on the map, within the chosen profile's limits.
@MainActor
@Observable
final class RoutePlanner {
    private static let profilesKey = "routing.profiles"
    private static let selectedKey = "routing.selectedProfile"

    /// True while the planner bar is shown and map clicks add points.
    var isActive = false
    var via: [Coordinate] = []
    var profiles: [RoutingProfile] {
        didSet { saveProfiles() }
    }
    var selectedProfileID: UUID {
        didSet { UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Self.selectedKey) }
    }
    var plan: ConstrainedRoutePlan?
    var status = ""
    var isPlanning = false
    var serverReachable: Bool?

    init() {
        var loaded = RoutingProfile.defaults
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let saved = try? JSONDecoder().decode([RoutingProfile].self, from: data), !saved.isEmpty {
            loaded = saved
        }
        let selected = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        profiles = loaded
        selectedProfileID = selected ?? loaded[0].id
    }

    var selectedProfile: RoutingProfile {
        profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    /// Changes the selected profile. Any route already planned no longer applies.
    func updateSelected(_ change: (inout RoutingProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        change(&profiles[index])
        plan = nil
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        plan = nil
    }

    /// Adds a copy of the selected profile with a new identifier, and selects it.
    func addProfile() {
        let source = selectedProfile
        let copy = RoutingProfile(
            name: source.name + " copy",
            brouterProfile: source.brouterProfile,
            maxGradePercent: source.maxGradePercent,
            maxDetourPercent: source.maxDetourPercent,
            maxPasses: source.maxPasses,
            minimumClimbMeters: source.minimumClimbMeters
        )
        profiles.append(copy)
        selectProfile(copy.id)
    }

    /// Removes the selected profile. The last profile cannot be removed.
    func deleteSelectedProfile() {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == selectedProfileID }
        selectProfile(profiles[0].id)
    }

    func add(_ coordinate: Coordinate) {
        via.append(coordinate)
        plan = nil
        status = ""
    }

    func undo() {
        guard !via.isEmpty else { return }
        via.removeLast()
        plan = nil
        status = ""
    }

    func clear() {
        via = []
        plan = nil
        status = ""
    }

    func checkServer(_ settings: RoutingSettings) async {
        guard let server = settings.activeServer else {
            serverReachable = false
            return
        }
        serverReachable = await BRouterClient(baseURL: server, profile: selectedProfile.brouterProfile).isReachable()
    }

    /// Plans within the selected profile. Steep sections are judged on the elevation models in `demFolder`
    /// when they cover every clicked point, otherwise on the heights BRouter returns.
    func planRoute(_ settings: RoutingSettings, demFolder: URL) async {
        guard via.count >= 2 else {
            status = "Click at least two points on the map."
            return
        }
        guard let server = settings.activeServer else {
            status = "The routing server address is not valid."
            return
        }

        isPlanning = true
        plan = nil
        status = "Planning…"
        let profile = selectedProfile
        let client = BRouterClient(baseURL: server, profile: profile.brouterProfile)
        let points = via
        let model = try? ElevationModel(folder: demFolder)
        let usesModel = model.map { model in points.allSatisfy { model.elevation(at: $0) != nil } } ?? false
        let source: RouteSource = model.map { model in
            ElevatedRouteSource(base: client) { model.elevations(for: $0) }
        } ?? client
        do {
            let result = try await ConstrainedRouter.plan(via: points, profile: profile, source: source) { [weak self] message in
                Task { @MainActor in
                    self?.status = message
                }
            }
            plan = result
            serverReachable = true
            status = Self.summary(result, profile: profile) + (usesModel ? " Heights from the elevation model." : "")
        } catch {
            status = Self.message(for: error, server: server)
            if !(error is RouteError) {
                serverReachable = false
            }
        }
        isPlanning = false
    }

    /// Adds the planned route to the library: the clicked points as its stops, and the planned line, with
    /// heights, cut into calculated legs between them. The route keeps the profile, to recalculate changed legs.
    func addPlannedRoute(to store: LibraryStore) {
        guard let plan else { return }
        let profile = selectedProfile
        let route = Route.planned(
            name: Self.routeName(for: profile),
            stops: via.map { RouteStop(coordinate: $0) },
            line: plan.geometry.points.map { RoutePoint(coordinate: $0.coordinate, elevation: $0.elevation) },
            profileID: profile.id
        )
        store.addRoute(route)
    }

    /// Names a planned route after the settings it was planned with.
    static func routeName(for profile: RoutingProfile) -> String {
        guard let limit = profile.maxGradePercent else {
            return "Route, \(profile.brouterProfile)"
        }
        return "Route, \(profile.brouterProfile), max \(Int(limit))%"
    }

    static func summary(_ plan: ConstrainedRoutePlan, profile: RoutingProfile) -> String {
        let direct = String(format: "%.1f km", plan.directLengthMeters / 1000)
        let final = String(format: "%.1f km", plan.geometry.lengthMeters / 1000)
        let ascent = "\(Int(plan.geometry.ascentMeters.rounded())) m ascent"
        let length = plan.passes == 0 ? final : "\(final), direct \(direct)"
        guard let limit = profile.maxGradePercent else {
            return "\(length), \(ascent). No grade limit set."
        }

        let trigger = Int(profile.minimumClimbMeters)
        let steep = plan.remainingSteepSections
        if steep.isEmpty {
            return plan.passes == 0
                ? "\(length), \(ascent). No climb of \(trigger) m or more above \(Int(limit))%."
                : "\(length), \(ascent). Detoured around climbs of \(trigger) m or more above \(Int(limit))%."
        }
        let steepLength = Int(steep.reduce(0) { $0 + $1.lengthMeters }.rounded())
        return "\(length), \(ascent). \(steep.count) climb(s) of \(trigger) m or more still above \(Int(limit))%, \(steepLength) m in total."
    }

    static func message(for error: Error, server: URL) -> String {
        switch error as? RouteError {
        case .missingSegments:
            "BRouter has no map data for this area. Add the segments covering the route to its folder."
        case .noRoute:
            "No route was found with these points and limits. Move a point, or raise the grade limit."
        case .server(let code, let text):
            "BRouter answered with an error (\(code)). \(text)"
        case .malformedResponse:
            "BRouter's answer could not be read."
        case nil:
            "Could not reach BRouter at \(server.absoluteString). Start it, or check the address in Settings."
        }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
    }
}
