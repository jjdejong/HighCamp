import Foundation

/// One elevation model file (DEM tile) in a folder of tiles: where it is, the area it covers and how fine it is.
/// Kept in an index, so a folder of thousands of tiles is read once and only changed files again.
public struct DEMTileInfo: Codable, Equatable, Sendable {
    /// The file's path.
    public let path: String
    public let size: Int64
    public let modified: Date?
    /// The area covered, in degrees.
    public let north: Double
    public let south: Double
    public let east: Double
    public let west: Double
    /// The pixel size in metres, roughly: what decides which tile wins where two overlap.
    public let resolution: Double
    /// The tile's projection, as GDAL describes it. Tiles are combined only with others of the same projection.
    public let projection: String
    /// The tile's corners in degrees, clockwise from north-west: a tile in a projection such as Lambert-93 is
    /// turned against the meridians, so its box is larger than it. Nil in an index written before they were kept.
    public let corners: [Coordinate]?

    public init(path: String, size: Int64, modified: Date?, north: Double, south: Double, east: Double, west: Double,
                resolution: Double, projection: String, corners: [Coordinate]? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
        self.north = north
        self.south = south
        self.east = east
        self.west = west
        self.resolution = resolution
        self.projection = projection
        self.corners = corners
    }

    /// The area the tile covers, for drawing it: its corners, or its box when they are not known.
    public var area: DEMTileArea {
        let outline = corners ?? [
            Coordinate(latitude: north, longitude: west), Coordinate(latitude: north, longitude: east),
            Coordinate(latitude: south, longitude: east), Coordinate(latitude: south, longitude: west),
        ]
        return DEMTileArea(outline: outline, resolution: resolution)
    }
}

/// Where one tile of a track DEM lies, and how fine it is.
public struct DEMTileArea: Codable, Equatable, Sendable {
    public let outline: [Coordinate]
    /// The pixel size in metres.
    public let resolution: Double

    public init(outline: [Coordinate], resolution: Double) {
        self.outline = outline
        self.resolution = resolution
    }
}

/// Choosing the tiles a track needs, and sampling heights along it.
public enum TrackDEM {
    /// The tiles that come within `corridor` metres of the lines, finest first. The lines are walked in steps no
    /// longer than the corridor, and a tile is kept when the box of `corridor` metres around a step's place
    /// touches it.
    public static func tiles(along lines: [[Coordinate]], corridor: Double, from tiles: [DEMTileInfo]) -> [DEMTileInfo] {
        var chosen = Set<Int>()
        for line in lines {
            for place in places(along: line, every: max(corridor, 1)) {
                let latitudeMargin = corridor / 111_320
                let longitudeMargin = corridor / (111_320 * max(cos(place.latitude * .pi / 180), 0.01))
                for (index, tile) in tiles.enumerated() where !chosen.contains(index) {
                    if place.latitude - latitudeMargin <= tile.north, place.latitude + latitudeMargin >= tile.south,
                       place.longitude - longitudeMargin <= tile.east, place.longitude + longitudeMargin >= tile.west {
                        chosen.insert(index)
                    }
                }
            }
        }
        return chosen.sorted().map { tiles[$0] }.sorted { ($0.resolution, $0.path) < ($1.resolution, $1.path) }
    }

    /// The tiles grouped by resolution, finest first: tiles whose pixel sizes differ by less than a tenth are one
    /// kind (IGN's 5 m tiles do not all come out at exactly 5 m). Each group gives its finest resolution.
    public static func tiers(_ areas: [DEMTileArea]) -> [(resolution: Double, count: Int)] {
        var tiers: [(resolution: Double, count: Int)] = []
        for area in areas.sorted(by: { $0.resolution < $1.resolution }) {
            if let last = tiers.last, area.resolution <= last.resolution * 1.1 {
                tiers[tiers.count - 1].count += 1
            } else {
                tiers.append((area.resolution, 1))
            }
        }
        return tiers
    }

    /// The line's points, with places added between them so no two are more than `step` metres apart.
    public static func places(along line: [Coordinate], every step: Double) -> [Coordinate] {
        guard var previous = line.first else { return [] }
        var result = [previous]
        for next in line.dropFirst() {
            let distance = Geodesy.distance(from: previous, to: next)
            let pieces = Int((distance / step).rounded(.up))
            if pieces > 1 {
                for piece in 1..<pieces {
                    let t = Double(piece) / Double(pieces)
                    result.append(Coordinate(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    ))
                }
            }
            result.append(next)
            previous = next
        }
        return result
    }

    /// Distances along a line every `step` metres, and its end, for a profile sampled from a DEM rather than read
    /// from the line's own points. At most `limit` samples: the step grows for long lines.
    public static func sampleDistances(length: Double, step: Double, limit: Int = 40_000) -> [Double] {
        guard length > 0, step > 0 else { return length > 0 ? [0, length] : [0] }
        let spacing = max(step, length / Double(max(limit - 1, 1)))
        var distances = Array(stride(from: 0, to: length, by: spacing))
        distances.append(length)
        return distances
    }
}
