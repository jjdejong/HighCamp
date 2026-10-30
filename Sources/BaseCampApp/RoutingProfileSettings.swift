import BaseCampCore
import SwiftUI

/// Settings › Routing profiles: choose a profile and edit it — its name, its BRouter profile and that profile's own
/// settings, and HighCamp's grade limit. The route tool's bar uses the same profiles.
struct RoutingProfileSettings: View {
    @Environment(RoutePlanner.self) private var planner
    @Environment(RoutingSettings.self) private var routing

    @State private var renaming = false
    @State private var newName = ""
    /// The settings read from each BRouter profile, by its name.
    @State private var parameters: [String: [BRouterParameter]] = [:]

    var body: some View {
        let profile = planner.selectedProfile
        Section("Routing profiles") {
            Picker("Profile", selection: Binding(
                get: { planner.selectedProfileID },
                set: { planner.selectProfile($0) }
            )) {
                ForEach(planner.profiles) { item in
                    Text(item.name).tag(item.id)
                }
            }
            HStack {
                Button("Add Profile") {
                    planner.addProfile()
                }
                .help("Adds a copy of this profile")
                Button("Rename…") {
                    newName = profile.name
                    renaming = true
                }
                Button("Delete Profile") {
                    planner.deleteSelectedProfile()
                }
                .disabled(planner.profiles.count <= 1)
            }
            Picker("BRouter profile", selection: Binding(
                get: { profile.brouterProfile },
                set: { name in planner.updateSelected { $0.brouterProfile = name } }
            )) {
                ForEach(brouterProfileNames(including: profile.brouterProfile), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }
        .alert("Rename Profile", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    planner.updateSelected { $0.name = name }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        gradeLimit(profile)
        brouterSettings(profile)
    }

    // MARK: Steep stretches

    /// Stretches steeper than the threshold are marked on the map and the profile, for the user to go round by
    /// moving the route. HighCamp can also route round the long ones itself.
    @ViewBuilder
    private func gradeLimit(_ profile: RoutingProfile) -> some View {
        Section("Steep stretches") {
            Toggle("Never climb steeper than", isOn: Binding(
                get: { planner.selectedProfile.maxClimbPercent != nil },
                set: { on in planner.updateSelected { $0.maxClimbPercent = on ? RoutingProfile.defaultMaxClimbPercent : nil } }
            ))
            .toggleStyle(.checkbox)
            .help("Climbs steeper than this are refused, whatever the detour; where there is no other way, the route still goes up")
            if let limit = profile.maxClimbPercent {
                valueSlider("Refused from", value: "\(Int(limit))%", Binding(
                    get: { limit },
                    set: { value in planner.updateSelected { $0.maxClimbPercent = value.rounded() } }
                ), in: 8...40, step: 1)
            }
            Toggle("Mark steep stretches", isOn: Binding(
                get: { planner.selectedProfile.maxGradePercent != nil },
                set: { marked in planner.updateSelected { $0.maxGradePercent = marked ? 12 : nil } }
            ))
            .toggleStyle(.checkbox)
            if let limit = profile.maxGradePercent {
                valueSlider("Steeper than", value: "\(Int(limit))%", Binding(
                    get: { limit },
                    set: { value in planner.updateSelected { $0.maxGradePercent = value.rounded() } }
                ), in: 5...25, step: 1)
                valueSlider("Max detour", value: "\(Int(profile.maxDetourPercent))% longer", Binding(
                    get: { profile.maxDetourPercent },
                    set: { value in planner.updateSelected { $0.maxDetourPercent = (value / 5).rounded() * 5 } }
                ), in: 10...150, step: 5)
                .help("How much longer a way round steep climbs may be than the way straight through, besides the length the climb takes at the limit")
                Toggle("Detour round them automatically", isOn: Binding(
                    get: { planner.selectedProfile.detoursSteepStretches },
                    set: { on in planner.updateSelected { $0.detoursSteepStretches = on } }
                ))
                .toggleStyle(.checkbox)
                if profile.detoursSteepStretches {
                    valueSlider("Detour from", value: "\(Int(profile.minimumClimbMeters)) m", Binding(
                        get: { profile.minimumClimbMeters },
                        set: { value in planner.updateSelected { $0.minimumClimbMeters = (value / 50).rounded() * 50 } }
                    ), in: 100...1000, step: 50)
                    .help("How long, along the route, a steep stretch must be before a way round it is sought")
                    Stepper(value: Binding(
                        get: { profile.maxPasses },
                        set: { value in planner.updateSelected { $0.maxPasses = value } }
                    ), in: 1...10) {
                        LabeledContent("Avoidance passes", value: "\(profile.maxPasses)")
                    }
                }
            }
            Text(profile.maxGradePercent == nil
                 ? (profile.maxClimbPercent != nil ? "Climbs over the refused grade are refused whatever the detour. " : "")
                    + "BRouter's own climbing cost (Climbs, below) prefers gentler ways without refusing steep ones."
                 : profile.maxClimbPercent != nil
                 ? "Climbs over the refused grade are refused whatever the detour. Steep stretches below it are marked on the map and the profile" + (profile.detoursSteepStretches ? ", and HighCamp looks for a way round each one at least the detour distance long, at most the max detour longer plus the length its climb takes at the limit." : "; drag the route to go round them.")
                 : profile.detoursSteepStretches
                 ? "BRouter is asked to keep off climbs steeper than the limit, and HighCamp also looks for a way round each steep stretch at least the detour distance long, measured along the route (not a height). A way round may be the max detour longer, plus the length its climb takes at the limit, as switchbacks need. Those it cannot avoid stay marked."
                 : "BRouter is asked to keep off climbs steeper than the limit. A way round may be the max detour longer, plus the length its climb takes at the limit, as switchbacks need. Steep stretches left are marked on the map and the profile; drag the route to go round them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: BRouter's settings

    /// The settings at the top of the BRouter profile, as this profile changes them.
    @ViewBuilder
    private func brouterSettings(_ profile: RoutingProfile) -> some View {
        let name = profile.brouterProfile
        Section("BRouter settings (\(name))") {
            if let all = parameters[name] {
                let main = all.filter(\.isMain)
                let others = all.filter { !$0.isMain }
                if all.isEmpty {
                    Text("This profile has no settings to change.")
                        .foregroundStyle(.secondary)
                }
                ForEach(main) { parameter in
                    control(for: parameter, profile: profile)
                }
                if !others.isEmpty {
                    DisclosureGroup("More settings from the profile") {
                        ForEach(others) { parameter in
                            control(for: parameter, profile: profile)
                        }
                    }
                }
                let changed = profile.brouterOptions.keys.filter { key in all.contains { $0.name == key } }
                HStack {
                    Text(changed.isEmpty ? "As in the BRouter profile." : "\(changed.count) changed from the BRouter profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use the Profile's Values") {
                        planner.updateSelected { $0.brouterOptions = [:] }
                    }
                    .disabled(profile.brouterOptions.isEmpty)
                }
                Text("Changes apply to routes calculated from now on. Recalculate a route (Route menu) to use them on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reading the profile…")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: name) {
            await load(name)
        }
    }

    @ViewBuilder
    private func control(for parameter: BRouterParameter, profile: RoutingProfile) -> some View {
        let value = profile.brouterOptions[parameter.name] ?? parameter.defaultValue
        let binding = Binding<Double>(
            get: { planner.selectedProfile.brouterOptions[parameter.name] ?? parameter.defaultValue },
            set: { new in
                planner.updateSelected { profile in
                    profile.brouterOptions[parameter.name] = new == parameter.defaultValue ? nil : new
                }
            }
        )
        let changed = profile.brouterOptions[parameter.name] != nil
        Group {
            switch parameter.kind {
            case .toggle:
                Toggle(parameter.label, isOn: Binding(get: { binding.wrappedValue != 0 }, set: { binding.wrappedValue = $0 ? 1 : 0 }))
                    .toggleStyle(.checkbox)
            case .choice(let choices):
                Picker(parameter.label, selection: binding) {
                    ForEach(choices, id: \.self) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                    if !choices.contains(where: { $0.value == value }) {
                        Text(BRouterParameters.format(value)).tag(value)
                    }
                }
            case .number(let range?, let step, let unit):
                // Whole steps, without the sums' stray decimals (0.30000000000000004).
                valueSlider(parameter.label, value: BRouterParameters.format(value) + unit, Binding(
                    get: { binding.wrappedValue },
                    set: { binding.wrappedValue = (($0 / step).rounded() * step * 1000).rounded() / 1000 }
                ), in: range, step: step)
            case .number(nil, _, let unit):
                LabeledContent(parameter.label) {
                    HStack(spacing: 4) {
                        TextField(parameter.label, value: binding, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        if !unit.isEmpty { Text(unit) }
                    }
                }
            }
        }
        .help(helpText(parameter, changed: changed))
        .fontWeight(changed ? .semibold : .regular)
    }

    private func helpText(_ parameter: BRouterParameter, changed: Bool) -> String {
        var text = parameter.help.map { "\($0). " } ?? ""
        text += "BRouter's \(parameter.name), \(BRouterParameters.format(parameter.defaultValue)) in the profile."
        if changed { text += " Changed for this profile." }
        return text
    }

    /// Reads the BRouter profile from HighCamp's BRouter folder, or from the server when it is not there.
    private func load(_ name: String) async {
        guard parameters[name] == nil else { return }
        let folder = routing.brouterFolder
        if let text = try? String(contentsOf: folder.appendingPathComponent("profiles2/\(name).brf"), encoding: .utf8) {
            parameters[name] = BRouterParameters.parse(text)
            return
        }
        if let server = routing.activeServer,
           let (data, response) = try? await URLSession.shared.data(from: server.appendingPathComponent("brouter/profiles2/\(name).brf")),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            parameters[name] = BRouterParameters.parse(String(decoding: data, as: UTF8.self))
        } else {
            parameters[name] = []
        }
    }

    // MARK: Helpers

    /// A slider with its value beside it, on one line with its label.
    private func valueSlider(_ label: String, value: String, _ binding: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: binding, in: range, step: step)
                    .labelsHidden()
                Text(value)
                    .monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
        }
    }

    /// The BRouter profiles installed in the BRouter folder, plus the one in use even if it is not installed.
    private func brouterProfileNames(including current: String) -> [String] {
        let folder = routing.brouterFolder.appendingPathComponent("profiles2")
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var names = Set(installed.filter { $0.hasSuffix(".brf") }.map { String($0.dropLast(4)) })
        names.insert(current)
        return names.sorted()
    }
}
