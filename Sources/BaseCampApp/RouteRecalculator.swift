import BaseCampCore
import BaseCampDEM
import Foundation
import Observation

/// Recalculates, in the background, the legs of routes whose stops changed, with each route's own routing profile
/// and the profile's grade limit, as the planner does. One leg at a time. A recalculated leg becomes part of the step
/// that changed its stops, so undo takes back both.
@MainActor
@Observable
final class RouteRecalculator {
    /// A leg as it was asked for: if its stops or the route's profile change, it is a different request.
    struct Request: Hashable {
        let route: UUID
        let leg: Int
        let start: RouteStop
        let end: RouteStop
        let profileID: UUID

        func hash(into hasher: inout Hasher) {
            hasher.combine(route)
            hasher.combine(leg)
            hasher.combine(start.coordinate)
            hasher.combine(end.coordinate)
            hasher.combine(profileID)
        }
    }

    /// The leg being calculated now.
    private(set) var current: Request?
    /// Why legs could not be recalculated. They are not tried again until their stops change or the user retries.
    private(set) var failures: [Request: String] = [:]

    private var isRunning = false

    /// The failure message for a leg as it is now, if its last try failed.
    func failure(route: Route, leg: Int) -> String? {
        request(route, leg).flatMap { failures[$0] }
    }

    /// True while a leg of this route is being calculated.
    func isWorking(on route: UUID) -> Bool {
        current?.route == route
    }

    /// Forgets the route's failures, so its waiting legs are tried again.
    func retry(_ route: UUID, store: LibraryStore, planner: RoutePlanner, settings: RoutingSettings, demFolder: URL) {
        failures = failures.filter { $0.key.route != route }
        check(store: store, planner: planner, settings: settings, demFolder: demFolder)
    }

    /// Looks for waiting legs and works through them. Called after every change to the library.
    func check(store: LibraryStore, planner: RoutePlanner, settings: RoutingSettings, demFolder: URL) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            while let next = nextRequest(in: store.library) {
                current = next
                let outcome = await calculate(next, profiles: planner.profiles, settings: settings, demFolder: demFolder)
                current = nil
                switch outcome {
                case .success(let leg):
                    // Refused when the stops moved meanwhile; the leg is then still waiting, as a new request.
                    store.applyRecalculatedLeg(next.route, at: next.leg, from: next.start, to: next.end, leg)
                case .failure(let message):
                    failures[next] = message
                }
            }
            // Forget failures for legs that are gone, so the list does not grow.
            let live = Set(store.library.routes.flatMap { route in route.legsWaitingForRouter.compactMap { request(route, $0) } })
            failures = failures.filter { live.contains($0.key) }
            isRunning = false
        }
    }

    private func nextRequest(in library: Library) -> Request? {
        for route in library.routes {
            for leg in route.legsWaitingForRouter {
                if let request = request(route, leg), failures[request] == nil {
                    return request
                }
            }
        }
        return nil
    }

    private func request(_ route: Route, _ leg: Int) -> Request? {
        guard let profileID = route.profileID, route.legs.indices.contains(leg) else { return nil }
        return Request(route: route.id, leg: leg, start: route.stops[leg], end: route.stops[leg + 1], profileID: profileID)
    }

    private enum Outcome {
        case success(RouteLeg)
        case failure(String)
    }

    private func calculate(_ request: Request, profiles: [RoutingProfile], settings: RoutingSettings, demFolder: URL) async -> Outcome {
        guard let profile = profiles.first(where: { $0.id == request.profileID }) else {
            return .failure("The route's routing profile no longer exists. Choose another in the inspector.")
        }
        guard let server = settings.activeServer else {
            return .failure("The routing server address is not valid.")
        }
        let client = BRouterClient(baseURL: server, profile: profile.brouterProfile)
        let points = [request.start.coordinate, request.end.coordinate]
        let source: RouteSource = await Task.detached { () -> RouteSource in
            guard let model = try? ElevationModel(folder: demFolder) else { return client }
            return ElevatedRouteSource(base: client) { model.elevations(for: $0) }
        }.value
        do {
            let plan = try await ConstrainedRouter.plan(via: points, profile: profile, source: source)
            let line = plan.geometry.points.map { RoutePoint(coordinate: $0.coordinate, elevation: $0.elevation) }
            return .success(.calculated(line: line, from: points[0], to: points[1], profileID: profile.id))
        } catch {
            return .failure(RoutePlanner.message(for: error, server: server))
        }
    }
}
