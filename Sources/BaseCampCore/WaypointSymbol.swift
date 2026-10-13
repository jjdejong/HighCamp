import Foundation

/// The symbol drawn on the map for a waypoint, from its GPX `<sym>` name.
public enum WaypointSymbol {
    /// The SF Symbol for each common GPX symbol name, keyed in lower case.
    private static let systemNames: [String: String] = [
        "flag": "flag.fill",
        "pin": "mappin",
        "summit": "mountain.2.fill",
        "campground": "tent.fill",
        "food": "fork.knife",
        "restaurant": "fork.knife",
        "cafe": "cup.and.saucer.fill",
        "water source": "drop.fill",
        "restroom": "toilet.fill",
        "parking area": "parkingsign",
        "information": "info.circle.fill",
        "hotel": "bed.double.fill",
        "gas station": "fuelpump.fill",
        "trailhead": "figure.hiking",
        "viewpoint": "binoculars.fill",
        "shopping center": "bag.fill",
        "bike trail": "bicycle",
        "park": "tree.fill",
    ]

    /// The SF Symbol for a waypoint with this GPX symbol name. Nil when there is no name, so the waypoint has no
    /// glyph. A name not in the table gets the plain pin.
    public static func systemName(for symbol: String?) -> String? {
        guard let name = symbol?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        return systemNames[name] ?? "mappin"
    }
}
