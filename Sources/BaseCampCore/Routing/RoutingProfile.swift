import Foundation

/// A routing setup: which BRouter profile to use, and the limits to plan within.
public struct RoutingProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// BRouter profile name, such as "mtb" or "trekking".
    public var brouterProfile: String
    /// Climbs steeper than this, in percent, are marked on the map and the profile as steep stretches. Nil: none
    /// are marked.
    public var maxGradePercent: Double?
    /// HighCamp also routes round steep stretches itself, within `maxDetourPercent`, in up to `maxPasses` passes.
    /// Off by default: the stretches are shown, and the user goes round them by moving the route.
    public var detoursSteepStretches: Bool
    /// Longest allowed detour, as a percentage of the direct route.
    public var maxDetourPercent: Double
    /// How many avoidance passes to try before keeping the best route found.
    public var maxPasses: Int
    /// A climb only triggers a detour when it is at least this long, in metres, above the grade limit.
    /// Shorter steep stretches are accepted as they are.
    public var minimumClimbMeters: Double
    /// The BRouter profile's settings changed for this profile (see `BRouterParameters`), sent with each request.
    /// Settings left at the profile's own value are not kept. True is 1, false 0.
    public var brouterOptions: [String: Double]

    public static let defaultMinimumClimbMeters = 300.0

    public init(
        id: UUID = UUID(),
        name: String,
        brouterProfile: String,
        maxGradePercent: Double? = nil,
        detoursSteepStretches: Bool = false,
        maxDetourPercent: Double = 50,
        maxPasses: Int = 4,
        minimumClimbMeters: Double = RoutingProfile.defaultMinimumClimbMeters,
        brouterOptions: [String: Double] = [:]
    ) {
        self.id = id
        self.name = name
        self.brouterProfile = brouterProfile
        self.maxGradePercent = maxGradePercent
        self.detoursSteepStretches = detoursSteepStretches
        self.maxDetourPercent = maxDetourPercent
        self.maxPasses = maxPasses
        self.minimumClimbMeters = minimumClimbMeters
        self.brouterOptions = brouterOptions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, brouterProfile, maxGradePercent, detoursSteepStretches, maxDetourPercent, maxPasses, minimumClimbMeters, brouterOptions
    }

    /// Profiles saved before a setting existed still load, with that setting's default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        brouterProfile = try values.decode(String.self, forKey: .brouterProfile)
        maxGradePercent = try values.decodeIfPresent(Double.self, forKey: .maxGradePercent)
        detoursSteepStretches = try values.decodeIfPresent(Bool.self, forKey: .detoursSteepStretches) ?? false
        maxDetourPercent = try values.decodeIfPresent(Double.self, forKey: .maxDetourPercent) ?? 50
        maxPasses = try values.decodeIfPresent(Int.self, forKey: .maxPasses) ?? 4
        minimumClimbMeters = try values.decodeIfPresent(Double.self, forKey: .minimumClimbMeters)
            ?? RoutingProfile.defaultMinimumClimbMeters
        brouterOptions = try values.decodeIfPresent([String: Double].self, forKey: .brouterOptions) ?? [:]
    }

    /// BRouter's mtb profile counts no climbing by default (`hills` 0). With 1 each metre climbed beyond 3% costs a
    /// little, so it takes a gentler way when one is near, without refusing a steep one.
    public static let softClimbing: [String: Double] = ["hills": 1]

    /// Profiles offered before the user creates any.
    public static let defaults: [RoutingProfile] = [
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0001-4B2E-9C11-000000000001")!,
            name: "Mountain bike, max 12%",
            brouterProfile: "mtb",
            maxGradePercent: 12,
            brouterOptions: RoutingProfile.softClimbing
        ),
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0002-4B2E-9C11-000000000002")!,
            name: "Mountain bike, max 15%",
            brouterProfile: "mtb",
            maxGradePercent: 15,
            brouterOptions: RoutingProfile.softClimbing
        ),
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0003-4B2E-9C11-000000000003")!,
            name: "Mountain bike, no grade limit",
            brouterProfile: "mtb",
            brouterOptions: RoutingProfile.softClimbing
        ),
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0004-4B2E-9C11-000000000004")!,
            name: "Trekking",
            brouterProfile: "trekking"
        ),
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0005-4B2E-9C11-000000000005")!,
            name: "Fast bike",
            brouterProfile: "fastbike"
        ),
    ]
}
