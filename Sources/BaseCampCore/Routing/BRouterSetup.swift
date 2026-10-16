import Foundation

/// BRouter's map data comes in tiles of 5° by 5°, named by their south-west corner: "E5_N45" covers 5–10° E,
/// 45–50° N. Each is a file in `segments4`, such as "E5_N45.rd5".
public enum BRouterSegments {
    public static func name(for coordinate: Coordinate) -> String {
        let west = Int((coordinate.longitude / 5).rounded(.down)) * 5
        let south = Int((coordinate.latitude / 5).rounded(.down)) * 5
        return (west < 0 ? "W\(-west)" : "E\(west)") + "_" + (south < 0 ? "S\(-south)" : "N\(south)")
    }

    /// The tiles a route through these places needs: those of the places and of the straight lines between them,
    /// sorted. The router's line strays little from the straight one at this scale.
    public static func names(covering places: [Coordinate]) -> [String] {
        var names = Set(places.map(name(for:)))
        for (from, to) in zip(places, places.dropFirst()) {
            let steps = Int((max(abs(to.latitude - from.latitude), abs(to.longitude - from.longitude)) / 0.05).rounded(.up))
            for step in stride(from: 1, to: max(steps, 1), by: 1) {
                let t = Double(step) / Double(steps)
                names.insert(name(for: Coordinate(
                    latitude: from.latitude + (to.latitude - from.latitude) * t,
                    longitude: from.longitude + (to.longitude - from.longitude) * t
                )))
            }
        }
        return names.sorted()
    }
}

/// Changes to a BRouter profile's text.
public enum BRouterProfileText {
    /// The profile with two lines in its way context that read the tunnel and bridge tags. They change no cost, so
    /// the route is the same; but BRouter reports only the tags a profile reads, and with these it says where the
    /// line is in a tunnel or on a bridge, where the terrain's heights are not the road's.
    public static func reportingStructures(_ profile: String) -> String {
        let lines = "\n# Added by HighCamp: read the tunnel and bridge tags, so BRouter reports them. No cost changes.\n"
            + "assign highcamp_tunnel = tunnel=yes\nassign highcamp_bridge = bridge=yes\n"
        if let node = profile.range(of: "---context:node") {
            return profile[..<node.lowerBound] + lines + "\n" + profile[node.lowerBound...]
        }
        return profile + (profile.hasSuffix("\n") ? "" : "\n") + lines
    }
}
