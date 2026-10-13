import BaseCampCore
import BaseCampIMG
import Foundation

/// How a group of Garmin lines is drawn, from the map's style.
struct LineStyle: Hashable, Sendable {
    var rgb: MapRGB
    /// In points. For a patterned line, the pattern's height.
    var width: Double
    /// Drawn under the line, `borderWidth` wide in all. Nil when the line has none.
    var border: MapRGB?
    var borderWidth: Double = 0
    /// A bitmap repeated along the line (dashes, double lines). Nil for a plain line.
    var pattern: GarminTypStyle.Bitmap?
    /// The colour of the pattern's unset pixels, or nil when they are transparent.
    var background: MapRGB?
}

/// How a group of Garmin areas is filled, from the map's style.
struct AreaStyle: Hashable, Sendable {
    var fill: MapRGB
    /// A 32 by 32 bitmap repeated across the area, in `fill` on `background` (or on nothing). Nil for a plain fill.
    var pattern: GarminTypStyle.Bitmap?
    var background: MapRGB?
}

/// Paths drawn with one style.
struct LineGroup: Sendable {
    let style: LineStyle
    var paths: [[Coordinate]]
}

/// Rings filled with one style.
struct AreaGroup: Sendable {
    let style: AreaStyle
    var rings: [[Coordinate]]
}

/// The Garmin features read for one area, in drawing order, and where the maps have data.
struct MapFeatureSet: Sendable {
    var lines: [LineGroup] = []
    var areas: [AreaGroup] = []
    /// The bounds of each map tile with data in the area. Outside them the maps have nothing to show.
    var coverage: [GeoBounds] = []
}

/// Opens the IMG maps in a folder once, and keeps them, their style, their tables and recently decoded cells in
/// memory. A map is opened again only when its file changes. Reads the features for one area at a time.
actor MapFeatureCache {
    static let shared = MapFeatureCache()

    /// Limits for one area, so a crowded one stays quick to draw.
    static let maximumLinePaths = 60_000
    static let maximumAreaRings = 30_000
    /// Decoded cells kept for neighbouring areas, which share them.
    static let maximumCachedCells = 4000


    private struct OpenMap {
        let size: Int64
        let modified: Date?
        let image: GarminIMG
        /// The map's own style (TYP), or nil when the map has none.
        let style: GarminTypStyle?
        /// The drawing position of each polygon type, bottom first. Types missing here are not drawn.
        let areaRanks: [Int: Int]
        var levels: [String: [GarminMapLevel]] = [:]
        var subdivisions: [String: [GarminSubdivision]] = [:]
    }

    private struct CellKey: Hashable {
        let file: String
        let subfile: String
        let index: Int
    }

    /// One group per feature type and style. Grouping by type keeps each type's place in the drawing order.
    private struct LineKey: Hashable {
        let type: Int
        let style: LineStyle
    }

    private struct AreaKey: Hashable {
        let type: Int
        let style: AreaStyle
    }

    private var maps: [String: OpenMap] = [:]
    private var cells: [CellKey: [GarminGeometry]] = [:]
    private var cellOrder: [CellKey] = []
    private var listing: (folder: URL, read: Date, files: [MapFile])?

    /// The features of one map to draw in `area` at a scale of `metersPerPoint`. `detailOffset` moves the level
    /// used: above 0 for more detail than the scale calls for, below 0 for less. With `finestLevel`, the map's finest
    /// level is used whatever the scale, as for overlays whose coarse levels are too rough to show.
    func features(in area: GeoBounds, metersPerPoint: Double, map url: URL, finestLevel: Bool, detailOffset: Int) -> MapFeatureSet {
        let wantedBits = finestLevel ? 32 : MapFeatureReader.detailBits(metersPerPoint: metersPerPoint) + detailOffset
        var lineGroups: [LineKey: LineGroup] = [:]
        var areaGroups: [AreaKey: (rank: Int, group: AreaGroup)] = [:]
        var coverage: [GeoBounds] = []
        var linePaths = 0
        var areaRings = 0

        for file in files(in: url.deletingLastPathComponent()) where file.url.lastPathComponent == url.lastPathComponent {
            guard !Task.isCancelled, let open = openMap(file) else { continue }
            for subfile in open.image.subfiles {
                guard !Task.isCancelled else { return MapFeatureSet() }
                guard let bounds = subfile.bounds, subfile.parts.contains("RGN"),
                      MapFeatureReader.intersects(bounds, area) else { continue }
                // A map tile shows nothing when zoomed out past its coarsest level, so its cells are not even read,
                // and its area is left to whatever is under the map.
                guard let levels = levels(for: subfile.name, in: file.url.path, image: open.image),
                      let level = MapFeatureReader.level(levels, forBits: wantedBits),
                      let subdivisions = subdivisions(for: subfile.name, in: file.url.path, image: open.image) else { continue }
                coverage.append(bounds)

                for (index, cell) in subdivisions.enumerated()
                where cell.level == level.level && MapFeatureReader.intersects(cell.bounds, area) {
                    let key = CellKey(file: file.url.path, subfile: subfile.name, index: index)
                    for geometry in geometries(key, cell: cell, image: open.image) {
                        if geometry.isPolygon {
                            guard areaRings < Self.maximumAreaRings,
                                  let rank = open.areaRanks[geometry.type],
                                  let style = MapFeatureReader.areaStyle(for: geometry.type, style: open.style),
                                  geometry.coordinates.count >= 3 else { continue }
                            let key = AreaKey(type: geometry.type, style: style)
                            areaGroups[key, default: (rank, AreaGroup(style: style, rings: []))].group.rings.append(geometry.coordinates)
                            areaRings += 1
                        } else if geometry.coordinates.count >= 2, linePaths < Self.maximumLinePaths {
                            let style = MapFeatureReader.lineStyle(for: geometry.type, style: open.style)
                            let key = LineKey(type: geometry.type, style: style)
                            lineGroups[key, default: LineGroup(style: style, paths: [])].paths.append(geometry.coordinates)
                            linePaths += 1
                        }
                    }
                }
            }
        }

        // Drawing order, bottom first, the same for every load: areas in the map's draw order, lines by type, as
        // QMapShack draws them. Ties (one type styled differently by two maps) go by colour, to stay stable.
        let areas = areaGroups.sorted {
            ($0.value.rank, $0.key.type, $0.key.style.fill.sortKey) < ($1.value.rank, $1.key.type, $1.key.style.fill.sortKey)
        }
        let lines = lineGroups.sorted {
            ($0.key.type, $0.key.style.rgb.sortKey, $0.key.style.width) < ($1.key.type, $1.key.style.rgb.sortKey, $1.key.style.width)
        }
        return MapFeatureSet(lines: lines.map(\.value), areas: areas.map(\.value.group), coverage: coverage)
    }

    /// The maps in the folder. The listing is kept for a few seconds, since every tile asks for it.
    private func files(in folder: URL) -> [MapFile] {
        if let listing, listing.folder == folder, Date().timeIntervalSince(listing.read) < 5 {
            return listing.files
        }
        let files = (try? MapFolder.imgMaps(in: folder)) ?? []
        listing = (folder, Date(), files)
        return files
    }

    /// The decoded geometry of one cell, from the cache when it was decoded recently.
    private func geometries(_ key: CellKey, cell: GarminSubdivision, image: GarminIMG) -> [GarminGeometry] {
        if let cached = cells[key] {
            return cached
        }
        let decoded = (try? image.geometries(of: key.subfile, in: cell)) ?? []
        cells[key] = decoded
        cellOrder.append(key)
        if cellOrder.count > Self.maximumCachedCells {
            let dropped = cellOrder.prefix(cellOrder.count - Self.maximumCachedCells)
            for old in dropped {
                cells[old] = nil
            }
            cellOrder.removeFirst(dropped.count)
        }
        return decoded
    }

    /// The open map for a file, reusing it while the file's size and date do not change.
    private func openMap(_ file: MapFile) -> OpenMap? {
        let key = file.url.path
        if let cached = maps[key], cached.size == file.size, cached.modified == file.modified {
            return cached
        }
        guard let image = try? GarminIMG(url: file.url) else {
            maps[key] = nil
            return nil
        }
        let style = try? image.typStyle()
        let order = GarminTypStyle.polygonDrawOrder(style)
        let ranks = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let open = OpenMap(size: file.size, modified: file.modified, image: image, style: style, areaRanks: ranks)
        maps[key] = open
        cells = cells.filter { $0.key.file != key }
        cellOrder.removeAll { $0.file == key }
        return open
    }

    /// The map levels of one subfile, read once per open map.
    private func levels(for name: String, in key: String, image: GarminIMG) -> [GarminMapLevel]? {
        if let cached = maps[key]?.levels[name] {
            return cached
        }
        guard let levels = try? image.mapLevels(of: name) else { return nil }
        maps[key]?.levels[name] = levels
        return levels
    }

    /// The subdivisions of one subfile, read once per open map, and only when the subfile is drawn.
    private func subdivisions(for name: String, in key: String, image: GarminIMG) -> [GarminSubdivision]? {
        if let cached = maps[key]?.subdivisions[name] {
            return cached
        }
        guard let subdivisions = try? image.subdivisions(of: name) else { return nil }
        maps[key]?.subdivisions[name] = subdivisions
        return subdivisions
    }
}

/// Helpers for reading the Garmin map features: detail levels, the area test, and styles.
enum MapFeatureReader {
    /// The detail in bits for a zoom, from metres per point. Same thresholds as QMapShack's `CMapIMG::scale2bits`.
    static func detailBits(metersPerPoint: Double) -> Int {
        let thresholds: [(metres: Double, bits: Int)] = [
            (70000, 2), (50000, 3), (30000, 4), (20000, 5), (15000, 6), (10000, 7), (7000, 8),
            (5000, 9), (3000, 10), (2000, 11), (1500, 12), (1000, 13), (700, 14), (500, 15),
            (300, 16), (200, 17), (100, 18), (70, 19), (30, 20), (15, 21), (7, 22), (3, 23),
        ]
        return thresholds.first { metersPerPoint >= $0.metres }?.bits ?? 24
    }

    /// The level to draw: the most detailed level with geometry of its own that does not exceed the wanted bits.
    /// Nil when the wanted detail is coarser than every such level, as when zoomed far out: the map shows nothing.
    static func level(_ levels: [GarminMapLevel], forBits bits: Int) -> GarminMapLevel? {
        levels.filter { !$0.inherited && $0.bits <= bits }.max { $0.bits < $1.bits }
    }

    static func intersects(_ a: GeoBounds, _ b: GeoBounds) -> Bool {
        a.south <= b.north && a.north >= b.south && a.west <= b.east && a.east >= b.west
    }

    /// How a line is drawn. The map's style gives it when it has one for the type; otherwise a plain colour by family.
    static func lineStyle(for type: Int, style: GarminTypStyle?) -> LineStyle {
        if let entry = style?.lines[type] {
            return LineStyle(
                rgb: MapRGB(entry.colour),
                width: Double(max(1, entry.width)),
                border: entry.border.map(MapRGB.init),
                borderWidth: Double(entry.borderWidth),
                pattern: entry.pattern,
                background: entry.background.map(MapRGB.init)
            )
        }
        switch color(for: type) {
        case .contour: return LineStyle(rgb: MapRGB(red: 0.72, green: 0.45, blue: 0.25), width: 1)
        case .road: return LineStyle(rgb: MapRGB(red: 0.95, green: 0.70, blue: 0.20), width: 3)
        case .water: return LineStyle(rgb: MapRGB(red: 0.30, green: 0.60, blue: 0.90), width: 2)
        default: return LineStyle(rgb: MapRGB(red: 0.45, green: 0.45, blue: 0.45), width: 1)
        }
    }

    /// How an area is filled. With a style, only the types it styles are drawn. Without one, a rough colour by
    /// family. The definition area (0x4A) and background (0x4B) polygons only mark where the map has data, so they
    /// are never filled, as in QMapShack.
    static func areaStyle(for type: Int, style: GarminTypStyle?) -> AreaStyle? {
        if type == 0x4A || type == 0x4B {
            return nil
        }
        if let style {
            return style.fillStyles[type].map {
                AreaStyle(fill: MapRGB($0.colour), pattern: $0.pattern, background: $0.background.map(MapRGB.init))
            }
        }
        switch baseType(type) {
        case 0x01...0x0b: return AreaStyle(fill: MapRGB(red: 0.80, green: 0.85, blue: 0.70))
        case 0x14...0x1f: return AreaStyle(fill: MapRGB(red: 0.70, green: 0.85, blue: 0.95))
        default: return nil
        }
    }

    /// A rough colour by feature family, for maps without a style.
    static func color(for type: Int) -> MapLineColor {
        switch baseType(type) {
        case 0x20...0x26: return .contour
        case 0x01...0x09: return .road
        case 0x14...0x1F: return .water
        default: return .other
        }
    }

    /// The feature type without the version 2 prefix.
    private static func baseType(_ type: Int) -> Int {
        type >= 0x10000 ? (type >> 8) & 0xFF : type
    }
}

extension MapRGB {
    init(_ rgb: GarminTypStyle.RGB) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }

    /// Orders colours, for a stable drawing order.
    var sortKey: Double {
        (red * 256 + green) * 256 + blue
    }
}
