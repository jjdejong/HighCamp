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

        /// Only where the stops are counts: a stop that took a height from the other leg asks for the same line.
        static func == (lhs: Request, rhs: Request) -> Bool {
            lhs.route == rhs.route && lhs.leg == rhs.leg && lhs.start.isSamePlace(as: rhs.start)
                && lhs.end.isSamePlace(as: rhs.end) && lhs.profileID == rhs.profileID
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
    func retry(_ route: UUID, store: LibraryStore, planner: RoutePlanner, settings: RoutingSettings) {
        failures = failures.filter { $0.key.route != route }
        check(store: store, planner: planner, settings: settings)
    }

    /// Looks for waiting legs and works through them. Called after every change to the library.
    func check(store: LibraryStore, planner: RoutePlanner, settings: RoutingSettings) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            while let next = nextRequest(in: store.library) {
                current = next
                let outcome = await calculate(next, profiles: planner.profiles, settings: settings, heights: store.heightSources)
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

    private func calculate(_ request: Request, profiles: [RoutingProfile], settings: RoutingSettings, heights: HeightSources?) async -> Outcome {
        guard let profile = profiles.first(where: { $0.id == request.profileID }) else {
            return .failure("The route's routing profile no longer exists. Choose another in the inspector.")
        }
        guard let server = settings.activeServer else {
            return .failure("The routing server address is not valid.")
        }
        let points = [request.start.coordinate, request.end.coordinate]
        // A copy of the profile that also reports tunnels and bridges, where terrain heights are not the road's.
        let folder = settings.engine == .local ? settings.brouterFolder : nil
        let name = await StructureProfiles.shared.name(for: profile.brouterProfile, server: server, folder: folder)
        do {
            return .success(try await calculate(points, with: name, profile: profile, server: server, heights: heights))
        } catch RouteError.server where name != profile.brouterProfile {
            // The uploaded copy may be gone (its folder emptied): upload it again next time, and use the profile now.
            StructureProfiles.shared.forget(server: server)
            do {
                return .success(try await calculate(points, with: profile.brouterProfile, profile: profile, server: server, heights: heights))
            } catch {
                return .failure(RoutePlanner.message(for: error, server: server))
            }
        } catch {
            return .failure(RoutePlanner.message(for: error, server: server))
        }
    }

    private func calculate(_ points: [Coordinate], with name: String, profile: RoutingProfile, server: URL, heights: HeightSources?) async throws -> RouteLeg {
        var client: RouteSource = BRouterClient(baseURL: server, profile: name, options: profile.brouterOptions)
        // With a grade limit, BRouter is asked to keep off steeper climbs; settings the user chose for the profile win.
        if let maxGrade = profile.maxGradePercent {
            client = GentleClimbRouteSource(maxGradePercent: maxGrade, maxDetourPercent: profile.maxDetourPercent) { options in
                BRouterClient(baseURL: server, profile: name, options: profile.brouterOptions.merging(options) { own, _ in own })
            }
        }
        // Steep stretches are judged on terrain heights, from one source for the whole leg (never mixed).
        let source: RouteSource = heights.map { heights in
            ElevatedRouteSource(base: client) { await heights.heights(for: $0, mixing: false) }
        } ?? client
        let plan = try await ConstrainedRouter.plan(via: points, profile: profile, source: source)
        let line = plan.geometry.points.map { RoutePoint(coordinate: $0.coordinate, elevation: $0.elevation) }
        return .calculated(line: line, from: points[0], to: points[1], profileID: profile.id, structures: plan.geometry.structures)
    }
}
