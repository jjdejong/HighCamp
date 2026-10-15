import Foundation

/// A point of interest from a Garmin map: a summit, a pass, a shop, a bench.
public struct MapPOI: Equatable, Sendable {
    /// The Garmin type, type byte then subtype byte. Version 2 types are 0x10000 + (type << 8) + subtype.
    public let type: Int
    public let coordinate: Coordinate
    public let name: String?
    /// Higher wins a crowded spot. See `priority(named:labelled:)`.
    public let priority: Int

    public init(type: Int, coordinate: Coordinate, name: String?, priority: Int) {
        self.type = type
        self.coordinate = coordinate
        self.name = name
        self.priority = priority
    }

    /// A point whose style writes its name and that has one comes first (a pass, a summit, a café), then other named
    /// points (a shop, a bus stop), then the unnamed ones (a bench, a bollard).
    public static func priority(named: Bool, labelled: Bool) -> Int {
        (named && labelled ? 2 : 0) + (named ? 1 : 0)
    }

    /// The points to show at a zoom: in each square of `cellSize` points of the Web Mercator world at that zoom
    /// (256 points per tile), only the one with the highest priority; ties go to the smaller type, then to the
    /// point further north and west. A point's square depends only on where it is, so every tile, and the labels,
    /// choose the same points.
    public static func shown(_ points: [MapPOI], zoom: Int, cellSize: Double = 24) -> [MapPOI] {
        let worldSize = 256 * pow(2, Double(zoom))
        var best: [Cell: MapPOI] = [:]
        for point in points {
            let latitude = max(-85.0511, min(85.0511, point.coordinate.latitude)) * .pi / 180
            let x = (point.coordinate.longitude + 180) / 360 * worldSize
            let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * worldSize
            let cell = Cell(x: Int((x / cellSize).rounded(.down)), y: Int((y / cellSize).rounded(.down)))
            if let current = best[cell], !point.wins(over: current) {
                continue
            }
            best[cell] = point
        }
        return Array(best.values)
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private func wins(over other: MapPOI) -> Bool {
        if priority != other.priority { return priority > other.priority }
        if type != other.type { return type < other.type }
        if coordinate.latitude != other.coordinate.latitude { return coordinate.latitude > other.coordinate.latitude }
        return coordinate.longitude < other.coordinate.longitude
    }
}
