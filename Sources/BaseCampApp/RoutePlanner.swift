import BaseCampCore
import Foundation
import Observation

/// The route tool, as BaseCamp's: while it is on, each click on the map adds a stop to a route in the library, the
/// first click starting a new one. The legs are calculated in the background with the chosen profile and its grade
/// limit (see `RouteRecalculator`). Also keeps the routing profiles.
@MainActor
@Observable
final class RoutePlanner {
    private static let profilesKey = "routing.profiles"
    private static let selectedKey = "routing.selectedProfile"
    private static let softClimbingSavedKey = "routing.softClimbingSaved"
    private static let maxClimbKey = "routing.maxClimbAdded"

    /// True while the route tool bar is shown and map clicks add stops.
    var isActive = false {
        didSet { if !isActive { routeID = nil } }
    }
    /// The route the clicks extend. Nil until the first click, and after "New Route".
    private(set) var routeID: UUID?
    var profiles: [RoutingProfile] {
        didSet { saveProfiles() }
    }
    var selectedProfileID: UUID {
        didSet { UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Self.selectedKey) }
    }
    var serverReachable: Bool?

    init() {
        var loaded = RoutingProfile.defaults
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let saved = try? JSONDecoder().decode([RoutingProfile].self, from: data), !saved.isEmpty {
            loaded = saved
            // Once: profiles saved before BRouter's climbing cost was offered take the gentle one the defaults
            // have, as the user asked ("Use the Profile's Values" in Settings removes it). The first version of
            // this step did not save the profiles, so it is done once more under a second key.
            if !UserDefaults.standard.bool(forKey: Self.softClimbingSavedKey) {
                for index in loaded.indices where loaded[index].brouterProfile == "mtb" && loaded[index].brouterOptions["hills"] == nil {
                    loaded[index].brouterOptions.merge(RoutingProfile.softClimbing) { old, _ in old }
                }
            }
            // Once: mountain-bike profiles with a grade limit refuse climbs over 20%, as the user asked.
            if !UserDefaults.standard.bool(forKey: Self.maxClimbKey) {
                for index in loaded.indices where loaded[index].brouterProfile == "mtb" && loaded[index].maxGradePercent != nil {
                    loaded[index].maxClimbPercent = loaded[index].maxClimbPercent ?? RoutingProfile.defaultMaxClimbPercent
                }
            }
            if loaded != saved, let data = try? JSONEncoder().encode(loaded) {
                UserDefaults.standard.set(data, forKey: Self.profilesKey)
            }
        }
        UserDefaults.standard.set(true, forKey: Self.maxClimbKey)
        UserDefaults.standard.set(true, forKey: Self.softClimbingSavedKey)
        let selected = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        profiles = loaded
        selectedProfileID = selected ?? loaded[0].id
    }

    var selectedProfile: RoutingProfile {
        profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    /// Changes the selected profile. Legs already calculated keep their line.
    func updateSelected(_ change: (inout RoutingProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        change(&profiles[index])
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
    }

    /// Adds a copy of the selected profile with a new identifier, and selects it.
    func addProfile() {
        let source = selectedProfile
        let copy = RoutingProfile(
            name: source.name + " copy",
            brouterProfile: source.brouterProfile,
            maxGradePercent: source.maxGradePercent,
            detoursSteepStretches: source.detoursSteepStretches,
            maxDetourPercent: source.maxDetourPercent,
            maxPasses: source.maxPasses,
            minimumClimbMeters: source.minimumClimbMeters,
            maxClimbPercent: source.maxClimbPercent,
            brouterOptions: source.brouterOptions
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

    /// Adds a stop where the map was clicked: to the route being drawn, or to a new route when there is none yet,
    /// it was deleted, or `startNew` is set.
    func click(_ coordinate: Coordinate, store: LibraryStore, startNew: Bool = false) {
        if !startNew, let routeID, store.route(routeID) != nil {
            store.extendRoute(routeID, to: coordinate)
            store.selection = .route(routeID)
        } else {
            routeID = store.startRoute(at: coordinate, profileID: selectedProfileID)
        }
    }

    /// The next click starts another route.
    func startNewRoute() {
        routeID = nil
    }

    func checkServer(_ settings: RoutingSettings) async {
        guard let server = settings.activeServer else {
            serverReachable = false
            return
        }
        serverReachable = await BRouterClient(baseURL: server, profile: selectedProfile.brouterProfile).isReachable()
    }

    static func message(for error: Error, server: URL) -> String {
        switch error as? RouteError {
        case .missingSegments:
            "BRouter has no map data for this area. Download it from the route's inspector, or in Settings › Routing."
        case .noRoute:
            "No route was found with these points and limits. Move a point, or allow more in the routing profile."
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
