import Foundation

/// A routing setup: which BRouter profile to use, and the limits to plan within.
public struct RoutingProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// BRouter profile name, such as "mtb" or "trekking".
    public var brouterProfile: String
    /// Steepest allowed climb, in percent. Nil means no limit.
    public var maxGradePercent: Double?
    /// Longest allowed detour, as a percentage of the direct route.
    public var maxDetourPercent: Double
    /// How many avoidance passes to try before keeping the best route found.
    public var maxPasses: Int
    /// A climb only triggers a detour when it is at least this long, in metres, above the grade limit.
    /// Shorter steep stretches are accepted as they are.
    public var minimumClimbMeters: Double

    public static let defaultMinimumClimbMeters = 300.0

    public init(
        id: UUID = UUID(),
        name: String,
        brouterProfile: String,
        maxGradePercent: Double? = nil,
        maxDetourPercent: Double = 50,
        maxPasses: Int = 4,
        minimumClimbMeters: Double = RoutingProfile.defaultMinimumClimbMeters
    ) {
        self.id = id
        self.name = name
        self.brouterProfile = brouterProfile
        self.maxGradePercent = maxGradePercent
        self.maxDetourPercent = maxDetourPercent
        self.maxPasses = maxPasses
        self.minimumClimbMeters = minimumClimbMeters
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, brouterProfile, maxGradePercent, maxDetourPercent, maxPasses, minimumClimbMeters
    }

    /// Profiles saved before a setting existed still load, with that setting's default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        brouterProfile = try values.decode(String.self, forKey: .brouterProfile)
        maxGradePercent = try values.decodeIfPresent(Double.self, forKey: .maxGradePercent)
        maxDetourPercent = try values.decodeIfPresent(Double.self, forKey: .maxDetourPercent) ?? 50
        maxPasses = try values.decodeIfPresent(Int.self, forKey: .maxPasses) ?? 4
        minimumClimbMeters = try values.decodeIfPresent(Double.self, forKey: .minimumClimbMeters)
            ?? RoutingProfile.defaultMinimumClimbMeters
    }

    /// Profiles offered before the user creates any.
    public static let defaults: [RoutingProfile] = [
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0001-4B2E-9C11-000000000001")!,
            name: "Mountain bike, max 12%",
            brouterProfile: "mtb",
            maxGradePercent: 12
        ),
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0002-4B2E-9C11-000000000002")!,
            name: "Mountain bike, max 15%",
            brouterProfile: "mtb",
            maxGradePercent: 15
        ),
        RoutingProfile(
            id: UUID(uuidString: "6A1F0C3E-0003-4B2E-9C11-000000000003")!,
            name: "Mountain bike, no grade limit",
            brouterProfile: "mtb"
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
