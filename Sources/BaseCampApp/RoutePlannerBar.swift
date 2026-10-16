import BaseCampCore
import SwiftUI

/// Bottom bar of the route tool. Choose the profile and its limits, then click the map: each click adds a point to the
/// route, which is in the library from the first click. Its legs are calculated in the background.
struct RoutePlannerBar: View {
    @Environment(RoutePlanner.self) private var planner
    @Environment(RoutingSettings.self) private var settings
    @Environment(BRouterServer.self) private var server
    @Environment(LibraryStore.self) private var store
    @Environment(ElevationSettings.self) private var elevation
    @Environment(RouteRecalculator.self) private var recalculator
    @Environment(DisplaySettings.self) private var display

    var body: some View {
        @Bindable var planner = planner
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Profile", selection: Binding(
                    get: { planner.selectedProfileID },
                    set: { id in
                        planner.selectProfile(id)
                        // The route being drawn takes the new profile for the legs still to come.
                        if let route = planner.routeID { store.setRouteProfile(route, profileID: id) }
                    }
                )) {
                    ForEach(planner.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .frame(maxWidth: 280)

                Spacer()
                Button("Done") {
                    planner.isActive = false
                }
                .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 12) {
                limitControls
            }

            HStack(spacing: 12) {
                Button("Undo") { store.undo() }
                    .disabled(!store.canUndo)
                Button("New Route") { planner.startNewRoute() }
                    .disabled(planner.routeID == nil)
                if let route = currentRoute, recalculator.isWorking(on: route.id) {
                    ProgressView().controlSize(.small)
                }
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                serverStatus
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task {
            await planner.checkServer(settings)
        }
    }

    private var currentRoute: Route? {
        planner.routeID.flatMap { store.route($0) }
    }

    private var status: String {
        guard let route = currentRoute else {
            return "Click the map to start a route. Each click adds a point; the legs follow the paths allowed by the profile."
        }
        let length = UnitFormat.distance(route.lengthMeters, display.units)
        let summary = "\(route.name): \(route.stops.count) point(s), \(length)."
        let failure = route.legsWaitingForRouter.lazy.compactMap { recalculator.failure(route: route, leg: $0) }.first
        if let failure {
            return "\(summary) \(failure)"
        }
        if !route.legsWaitingForRouter.isEmpty {
            return "\(summary) Calculating…"
        }
        return "\(summary) Click to add a point; drag a point or the line to change the route; right-click for more."
    }

    /// Which climbs are marked as steep, and whether HighCamp routes round the long ones itself (from how far along
    /// the route), for the selected profile. Labels and values keep a fixed width, so the controls fit beside the map.
    @ViewBuilder
    private var limitControls: some View {
        let profile = planner.selectedProfile
        Toggle("Mark steeper than", isOn: Binding(
            get: { profile.maxGradePercent != nil },
            set: { marked in
                planner.updateSelected { $0.maxGradePercent = marked ? 12 : nil }
            }
        ))
        .toggleStyle(.checkbox)
        .fixedSize()
        if let limit = profile.maxGradePercent {
            Slider(value: Binding(
                get: { limit },
                set: { value in planner.updateSelected { $0.maxGradePercent = value.rounded() } }
            ), in: 5...25, step: 1)
            .frame(width: 120)
            Text("\(Int(limit))%")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)

            Toggle("Detour from", isOn: Binding(
                get: { profile.detoursSteepStretches },
                set: { on in planner.updateSelected { $0.detoursSteepStretches = on } }
            ))
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Route round steep stretches at least this long, measured along the route")
            if profile.detoursSteepStretches {
                Slider(value: Binding(
                    get: { profile.minimumClimbMeters },
                    set: { value in planner.updateSelected { $0.minimumClimbMeters = (value / 50).rounded() * 50 } }
                ), in: 100...1000, step: 50)
                .frame(width: 120)
                .help("How long, along the route, a steep stretch must be before a way round it is sought")
                Text("\(Int(profile.minimumClimbMeters)) m")
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 64, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        if planner.serverReachable == true {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("BRouter is answering")
        } else if settings.engine == .local {
            Button("Start BRouter") {
                server.start(settings)
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    await planner.checkServer(settings)
                }
            }
.help(server.lastError ?? "Start HighCamp's BRouter (install it and its map data in Settings › Routing)")
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("brouter.de did not answer")
        }
    }
}
