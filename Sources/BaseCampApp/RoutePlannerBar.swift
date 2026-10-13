import BaseCampCore
import SwiftUI

/// Bottom bar while planning. Choose the profile and its limits, click points on the map, then plan.
struct RoutePlannerBar: View {
    @Environment(RoutePlanner.self) private var planner
    @Environment(RoutingSettings.self) private var settings
    @Environment(BRouterServer.self) private var server
    @Environment(LibraryStore.self) private var store
    @Environment(ElevationSettings.self) private var elevation

    var body: some View {
        @Bindable var planner = planner
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Profile", selection: Binding(
                    get: { planner.selectedProfileID },
                    set: { planner.selectProfile($0) }
                )) {
                    ForEach(planner.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .frame(maxWidth: 280)

                Spacer()
                Button("Close", systemImage: "xmark") {
                    planner.isActive = false
                }
                .labelStyle(.iconOnly)
            }

            HStack(spacing: 12) {
                limitControls
            }

            HStack(spacing: 12) {
                Text("\(planner.via.count) point(s)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Undo") { planner.undo() }
                    .disabled(planner.via.isEmpty)
                Button("Clear") { planner.clear() }
                    .disabled(planner.via.isEmpty)
                Button("Plan Route") {
                    Task { await planner.planRoute(settings, demFolder: elevation.folder) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(planner.via.count < 2 || planner.isPlanning)
                if planner.isPlanning {
                    ProgressView().controlSize(.small)
                }
                Button("Add to Library") {
                    planner.addPlannedRoute(to: store)
                }
                .disabled(planner.plan == nil)
                Spacer()
                serverStatus
            }

            Text(planner.status.isEmpty ? "Click the map to add route points." : planner.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task {
            await planner.checkServer(settings)
        }
    }

    /// The grade limit and the climb length that triggers a detour, for the selected profile.
    /// Labels and values keep a fixed width, so the controls fit beside the map.
    @ViewBuilder
    private var limitControls: some View {
        let profile = planner.selectedProfile
        Toggle("Limit grade", isOn: Binding(
            get: { profile.maxGradePercent != nil },
            set: { limited in
                planner.updateSelected { $0.maxGradePercent = limited ? 12 : nil }
            }
        ))
        .fixedSize()
        if let limit = profile.maxGradePercent {
            Text("Max grade")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Slider(value: Binding(
                get: { limit },
                set: { value in planner.updateSelected { $0.maxGradePercent = value.rounded() } }
            ), in: 5...25, step: 1)
            .frame(width: 120)
            Text("\(Int(limit))%")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)

            Text("Min. climb")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Slider(value: Binding(
                get: { profile.minimumClimbMeters },
                set: { value in planner.updateSelected { $0.minimumClimbMeters = (value / 50).rounded() * 50 } }
            ), in: 100...1000, step: 50)
            .frame(width: 120)
            Text("\(Int(profile.minimumClimbMeters)) m")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
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
            .help(server.lastError ?? "Start the local BRouter server from QMapShack's folder")
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("brouter.de did not answer")
        }
    }
}
