import Foundation

/// A setting at the top of a BRouter profile (`assign name = value` in its global context), which a request can
/// override with `profile:name=value`. HighCamp keeps the values the user changed with each routing profile.
public struct BRouterParameter: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case toggle
        /// A number; without a range, typed in.
        case number(ClosedRange<Double>?, step: Double, unit: String)
        case choice([Choice])
    }

    public struct Choice: Equatable, Hashable, Sendable {
        public let value: Double
        public let label: String

        public init(_ value: Double, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public var id: String { name }
    public let name: String
    public let label: String
    /// What it does: HighCamp's words for its chosen settings, the profile's own for the others.
    public let help: String?
    public let kind: Kind
    /// The value the profile gives it. True is 1, false 0.
    public let defaultValue: Double
    /// One of the settings HighCamp offers by name, with a plain label; the others are those the profile describes.
    public let isMain: Bool
}

public enum BRouterParameters {
    /// The settings of a profile worth offering, HighCamp's chosen ones first (in the catalogue's order), then the
    /// others the profile describes for BRouter's web page (`# %name% | description | type`), in the file's order.
    /// Only settings given a plain value (a number, true or false) count; one worked out from others cannot be set.
    public static func parse(_ profile: String) -> [BRouterParameter] {
        var seen = Set<String>()
        var main: [BRouterParameter] = []
        var others: [BRouterParameter] = []
        for line in profile.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("---context:") && !line.contains("---context:global") { break }
            guard let match = line.wholeMatch(of: assignment) else { continue }
            let name = String(match.1)
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            let literal = String(match.2)
            let value = literal == "true" ? 1 : literal == "false" ? 0 : Double(literal) ?? 0
            let note = match.3.map { annotation(String($0), name: name) } ?? nil
            if let entry = catalogue.first(where: { $0.name == name }) {
                let kind = entry.kind ?? note?.kind ?? (literal == "true" || literal == "false" ? .toggle : .number(nil, step: 1, unit: ""))
                main.append(BRouterParameter(name: name, label: entry.label, help: entry.help ?? note?.description, kind: kind,
                                             defaultValue: value, isMain: true))
            } else if let note, !excluded.contains(name) {
                others.append(BRouterParameter(name: name, label: humanised(name), help: note.description,
                                               kind: note.kind ?? .toggle, defaultValue: value, isMain: false))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: catalogue.enumerated().map { ($1.name, $0) })
        return main.sorted { order[$0.name, default: 0] < order[$1.name, default: 0] } + others
    }

    /// The request's overrides, as BRouter reads them: numbers only (true is 1), names sorted.
    public static func queryItems(_ options: [String: Double]) -> [URLQueryItem] {
        options.keys.sorted().map { name in
            URLQueryItem(name: "profile:\(name)", value: format(options[name]!))
        }
    }

    /// A value as BRouter reads it, and as shown: whole numbers without a decimal point.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(value)
    }

    // MARK: Reading

    /// `assign name [=] value [# comment]`, the value a plain number, true or false.
    nonisolated(unsafe) private static let assignment = #/\s*assign\s+([A-Za-z_][A-Za-z0-9_]*)\s*=?\s*(true|false|-?[0-9]+(?:\.[0-9]+)?)\s*(?:#(.*))?/#

    /// The description and kind in a comment `%name% | description | type`, the type `boolean`, `number`, or a list
    /// `[0=none, 1=auto-choose]`.
    private static func annotation(_ comment: String, name: String) -> (description: String?, kind: BRouterParameter.Kind?)? {
        let parts = comment.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first == "%\(name)%" else { return nil }
        let description = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        guard parts.count > 2 else { return (description, nil) }
        let type = parts[2]
        if type == "boolean" { return (description, .toggle) }
        if type == "number" { return (description, .number(nil, step: 1, unit: "")) }
        if type.hasPrefix("[") {
            let choices = type.matches(of: #/(-?[0-9]+(?:\.[0-9]+)?)\s*=\s*([^,\]]+)/#).compactMap { match in
                Double(match.1).map { BRouterParameter.Choice($0, match.2.trimmingCharacters(in: .whitespaces)) }
            }
            return (description, choices.isEmpty ? nil : .choice(choices))
        }
        return (description, nil)
    }

    private static func humanised(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Catalogue

    private struct Entry {
        let name: String
        let label: String
        var help: String?
        /// Nil: as the profile describes it, or from its value.
        var kind: BRouterParameter.Kind?
    }

    /// The settings HighCamp offers with plain labels, in the order shown. A profile shows those it has.
    private static let catalogue: [Entry] = [
        Entry(name: "hills", label: "Climbs", help: "How BRouter weighs going up and down", kind: .choice([
            .init(0, "BRouter's default"), .init(1, "Avoid climbs over 3%"), .init(2, "Avoid all slopes"),
            .init(3, "Count climbing as time"), .init(4, "Prefer valleys"),
        ])),
        Entry(name: "consider_elevation", label: "Avoid climbing", help: "Prefer a route with less height gained", kind: .toggle),
        Entry(name: "avoid_steep_inclines", label: "Avoid steep inclines", kind: .toggle),
        Entry(name: "uphillcost", label: "Uphill cost", help: "Extra cost for each metre climbed; 0 counts climbing as flat",
              kind: .number(0...200, step: 10, unit: "")),
        Entry(name: "uphillcutoff", label: "Climbs counted from", help: "Grades below this are not counted as climbing",
              kind: .number(0...10, step: 0.5, unit: "%")),
        Entry(name: "downhillcost", label: "Downhill cost", help: "Extra cost for each metre descended",
              kind: .number(0...200, step: 10, unit: "")),
        Entry(name: "downhillcutoff", label: "Descents counted from", help: "Grades below this are not counted as descending",
              kind: .number(0...10, step: 0.5, unit: "%")),
        Entry(name: "allow_steps", label: "Allow steps", kind: .toggle),
        Entry(name: "path_preference", label: "Prefer paths", help: "How strongly roads and paved ways cost more than paths; 0 turns it off",
              kind: .number(0...50, step: 5, unit: "")),
        Entry(name: "MTB_factor", label: "Mountain-bike trails", help: "Above 0 favours tracks and trails over roads, below 0 the reverse",
              kind: .number(-1...1, step: 0.1, unit: "")),
        Entry(name: "smallpaved_factor", label: "Small paved roads", help: "Below 0 favours small paved roads, above 0 avoids them",
              kind: .number(-1...1, step: 0.1, unit: "")),
        Entry(name: "prefer_unpaved_paths", label: "Prefer unpaved paths", kind: .toggle),
        Entry(name: "consider_smoothness", label: "Mind the surface", help: "Count rough surfaces and difficult trails as costlier", kind: .toggle),
        Entry(name: "SAC_scale_limit", label: "Hardest hiking path", help: "Paths above this SAC grade are not used"),
        Entry(name: "SAC_scale_preferred", label: "Preferred hiking path", help: "Easier paths cost a little more, harder ones much more"),
        Entry(name: "iswet", label: "Wet weather", help: "Avoid ways likely to be muddy or slippery", kind: .toggle),
        Entry(name: "assume_wet_conditions", label: "Wet weather", help: "Avoid ways likely to be muddy or slippery", kind: .toggle),
        Entry(name: "avoid_unsafe", label: "Avoid main roads", help: "Main roads without a cycle lane or track cost more", kind: .toggle),
        Entry(name: "consider_traffic", label: "Avoid traffic", help: "Roads that usually carry traffic cost more"),
        Entry(name: "consider_traffic_estimate", label: "Avoid traffic", help: "Roads that usually carry traffic cost more", kind: .toggle),
        Entry(name: "allow_motorways", label: "Allow motorways", kind: .toggle),
        Entry(name: "StrictNOBicycleaccess", label: "Forbid foot-only ways", help: "Otherwise they are allowed at a cost", kind: .toggle),
        Entry(name: "cycleroutes_pref", label: "Prefer cycle routes", help: "How much signed cycle routes are favoured; 0 ignores them",
              kind: .number(0...1, step: 0.1, unit: "")),
        Entry(name: "prefer_cycle_routes", label: "Prefer cycle routes", kind: .toggle),
        Entry(name: "stick_to_cycleroutes", label: "Only follow cycle routes", kind: .toggle),
        Entry(name: "ignore_cycleroutes", label: "Ignore cycle routes", kind: .toggle),
        Entry(name: "hiking_routes_preference", label: "Prefer hiking routes", help: "How much other ways cost more than signed hiking routes",
              kind: .number(0...2, step: 0.1, unit: "")),
        Entry(name: "consider_forest", label: "Prefer forests and parks", kind: .toggle),
        Entry(name: "prefer_forests", label: "Prefer forests and parks", kind: .toggle),
        Entry(name: "consider_river", label: "Prefer rivers and lakes", kind: .toggle),
        Entry(name: "prefer_rivers", label: "Prefer rivers and lakes", kind: .toggle),
        Entry(name: "consider_noise", label: "Prefer quiet ways", kind: .toggle),
        Entry(name: "avoid_noise", label: "Prefer quiet ways", kind: .toggle),
        Entry(name: "consider_town", label: "Avoid towns", kind: .toggle),
        Entry(name: "avoid_towns", label: "Avoid towns", kind: .toggle),
        Entry(name: "allow_ferries", label: "Allow ferries", kind: .toggle),
    ]

    /// Settings a profile describes that change nothing HighCamp uses: turn instructions, travel time, data output,
    /// and joining legs (HighCamp routes each leg on its own).
    private static let excluded: Set<String> = [
        "turnInstructionMode", "turnInstructionCatchingRange", "turnInstructionRoundabouts", "considerTurnRestrictions",
        "totalMass", "maxSpeed", "S_C_x", "C_r", "bikerPower", "processUnusedTags", "add_beeline",
        "correctMisplacedViaPoints", "correctMisplacedViaPointsDistance",
    ]
}
