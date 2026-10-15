import BaseCampCore
import BaseCampIMG
import CoreGraphics
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

/// A point's icon from the map's style, ready to draw. Nil icons are drawn as a plain dot.
final class POIIcon: @unchecked Sendable {
    /// Immutable once made.
    let image: CGImage
    let width: Int
    let height: Int

    init?(_ point: GarminTypStyle.Point) {
        // A fully transparent icon draws nothing; the point is left out.
        guard point.rgba.enumerated().contains(where: { $0.offset % 4 == 3 && $0.element > 0 }) else { return nil }
        // CoreGraphics wants premultiplied colours.
        var pixels = point.rgba
        for index in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let alpha = UInt16(pixels[index + 3])
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(UInt16(pixels[index + channel]) * alpha / 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: point.width, height: point.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: point.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        self.image = image
        width = point.width
        height = point.height
    }
}

/// A point type a map's style defines, as listed in the Points of Interest window.
struct POIType: Sendable, Identifiable {
    let type: Int
    /// The style's name for it, such as "bench" or "Restaurant".
    let name: String?
    let icon: POIIcon

    var id: Int { type }
}

/// A point to draw, with its icon.
struct DrawnPOI: Sendable {
    let poi: MapPOI
    let icon: POIIcon?
}

/// A point of interest whose name may be written, with how the map's style writes it.
struct POIName: Sendable {
    let poi: MapPOI
    /// The style writes the name of this type (QMapShack's label types other than none).
    let labelled: Bool
    /// The icon's width in points, so the name starts beside it. 5 for the plain dot.
    let iconWidth: Int
    let size: GarminTypStyle.LabelSize
    let colour: MapRGB?
}

/// The Garmin features read for one area, in drawing order, and where the maps have data.
struct MapFeatureSet: Sendable {
    var lines: [LineGroup] = []
    var areas: [AreaGroup] = []
    /// The points of interest on the level drawn, not yet thinned (see `MapPOI.shown`). Places are left out: their
    /// names are drawn instead.
    var points: [DrawnPOI] = []
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
        /// The style's point icons by type. A type the style has with a transparent icon is not drawn at all.
        let icons: [Int: POIIcon]
        var levels: [String: [GarminMapLevel]] = [:]
        var subdivisions: [String: [GarminSubdivision]] = [:]
        /// Each subfile's string table, read when its names are first needed. Nil inside: the subfile has none.
        var labels: [String: GarminLabels?] = [:]
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
    /// The named places of decoded cells, kept like `cells`.
    private var placeCells: [CellKey: [(name: String, coordinate: Coordinate, size: Int)]] = [:]
    private var placeCellOrder: [CellKey] = []

    /// The points of interest of decoded cells, kept like `cells`.
    private var poiCells: [CellKey: [MapPOI]] = [:]
    private var poiCellOrder: [CellKey] = []

    /// Points read, at most, for one area.
    static let maximumPoints = 20_000

    /// The named lines of decoded cells, kept like `cells`.
    private var lineNameCells: [CellKey: [NamedLine]] = [:]
    private var lineNameOrder: [CellKey] = []

    /// The streets, roads and rivers of one map in `area` with their names, from the level drawn at this scale.
    /// Railways, routes, boundaries and contour heights are left out.
    func namedLines(in area: GeoBounds, metersPerPoint: Double, map url: URL, detailOffset: Int) -> [NamedLine] {
        let bits = MapFeatureReader.detailBits(metersPerPoint: metersPerPoint)
        var result: [NamedLine] = []
        for file in files(in: url.deletingLastPathComponent()) where file.url.lastPathComponent == url.lastPathComponent {
            guard !Task.isCancelled, let open = openMap(file) else { continue }
            for subfile in open.image.subfiles {
                guard !Task.isCancelled else { return [] }
                guard let bounds = subfile.bounds, subfile.parts.contains("RGN"), MapFeatureReader.intersects(bounds, area),
                      let levels = levels(for: subfile.name, in: file.url.path, image: open.image),
                      let level = levels.drawnLevel(forBits: bits, steps: detailOffset),
                      let subdivisions = subdivisions(for: subfile.name, in: file.url.path, image: open.image),
                      let labels = labels(for: subfile.name, in: file.url.path, image: open.image) else { continue }
                for (index, cell) in subdivisions.enumerated()
                where cell.level == level.level && MapFeatureReader.intersects(cell.bounds, area) {
                    let key = CellKey(file: file.url.path, subfile: subfile.name, index: index)
                    if let cached = lineNameCells[key] {
                        result += cached
                        continue
                    }
                    let named = geometries(key, cell: cell, image: open.image).compactMap { line -> NamedLine? in
                        guard !line.isPolygon, line.labelOffset != 0, let kind = MapFeatureReader.nameKind(line.type),
                              let name = labels.name(at: line.labelOffset, inNET: line.labelInNET),
                              name.contains(where: \.isLetter) else { return nil }
                        return NamedLine(
                            name: MapPlace.displayName(name), coordinates: line.coordinates,
                            importance: kind.importance, isWater: kind.isWater
                        )
                    }
                    lineNameCells[key] = named
                    lineNameOrder.append(key)
                    if lineNameOrder.count > Self.maximumCachedCells {
                        lineNameCells[lineNameOrder.removeFirst()] = nil
                    }
                    result += named
                }
            }
        }
        return result
    }

    /// Places read, at most, for one view, most important first.
    static let maximumPlaces = 1500

    /// The places of one map to name in `area` at a scale of `metersPerPoint`: those on the level drawn and the two
    /// finer levels, each ranked by the coarsest level it is on. Nothing where the map draws nothing at this scale.
    func places(in area: GeoBounds, metersPerPoint: Double, map url: URL, detailOffset: Int) -> [MapPlace] {
        let bits = MapFeatureReader.detailBits(metersPerPoint: metersPerPoint)
        var found: [String: MapPlace] = [:]
        for file in files(in: url.deletingLastPathComponent()) where file.url.lastPathComponent == url.lastPathComponent {
            guard !Task.isCancelled, let open = openMap(file) else { continue }
            for subfile in open.image.subfiles {
                guard !Task.isCancelled else { return [] }
                guard let bounds = subfile.bounds, subfile.parts.contains("RGN"), MapFeatureReader.intersects(bounds, area),
                      let levels = levels(for: subfile.name, in: file.url.path, image: open.image),
                      let drawn = levels.drawnLevel(forBits: bits, steps: detailOffset),
                      let subdivisions = subdivisions(for: subfile.name, in: file.url.path, image: open.image),
                      let labels = labels(for: subfile.name, in: file.url.path, image: open.image) else { continue }
                // Every coarser level, which says how important each place is, the level drawn, and up to two finer
                // ones, so villages are named before their streets are drawn.
                let finer = levels.filter { !$0.inherited && $0.bits >= drawn.bits }.sorted { $0.bits < $1.bits }.prefix(3)
                let deepest = finer.last?.bits ?? drawn.bits
                let named = levels.filter { !$0.inherited && $0.bits <= deepest }
                for level in named {
                    for (index, cell) in subdivisions.enumerated()
                    where cell.level == level.level && MapFeatureReader.intersects(cell.bounds, area) {
                        let key = CellKey(file: file.url.path, subfile: subfile.name, index: index)
                        for place in places(key, cell: cell, image: open.image, labels: labels) {
                            let c = place.coordinate
                            guard c.latitude <= area.north, c.latitude >= area.south, c.longitude >= area.west, c.longitude <= area.east else { continue }
                            // The same town is on several levels: the key keeps one per level and place.
                            let nameKey = "\(place.name)|\(level.level)|\(Int((c.latitude * 100).rounded()))|\(Int((c.longitude * 100).rounded()))"
                            found[nameKey] = MapPlace(name: place.name, coordinate: c, rank: level.level, size: place.size)
                        }
                    }
                }
            }
        }
        return Array(MapPlace.merged(Array(found.values)).prefix(Self.maximumPlaces))
    }

    private func places(_ key: CellKey, cell: GarminSubdivision, image: GarminIMG, labels: GarminLabels) -> [(name: String, coordinate: Coordinate, size: Int)] {
        if let cached = placeCells[key] {
            return cached
        }
        let points = (try? image.points(of: key.subfile, in: cell)) ?? []
        let decoded = points.compactMap { point -> (name: String, coordinate: Coordinate, size: Int)? in
            guard point.isPlace, point.labelOffset != 0,
                  let name = labels.name(at: point.labelOffset, poi: point.labelIsPOI) else { return nil }
            return (MapPlace.displayName(name), point.coordinate, point.type >> 8)
        }
        placeCells[key] = decoded
        placeCellOrder.append(key)
        if placeCellOrder.count > Self.maximumCachedCells {
            placeCells[placeCellOrder.removeFirst()] = nil
        }
        return decoded
    }

    private func labels(for name: String, in key: String, image: GarminIMG) -> GarminLabels? {
        if let cached = maps[key]?.labels[name] {
            return cached
        }
        let labels = try? image.labels(of: name)
        maps[key]?.labels[name] = .some(labels)
        return labels
    }
    private var listing: (folder: URL, read: Date, files: [MapFile])?

    /// The features of one map to draw in `area` at a scale of `metersPerPoint`. `detailOffset` moves the level
    /// used by that many map levels: above 0 for more detail than the scale calls for, below 0 for less. With `finestLevel`, the map's finest
    /// level is used whatever the scale, as for overlays whose coarse levels are too rough to show.
    func features(in area: GeoBounds, metersPerPoint: Double, map url: URL, finestLevel: Bool, detailOffset: Int) -> MapFeatureSet {
        let wantedBits = finestLevel ? 32 : MapFeatureReader.detailBits(metersPerPoint: metersPerPoint)
        let steps = finestLevel ? 0 : detailOffset
        var lineGroups: [LineKey: LineGroup] = [:]
        var areaGroups: [AreaKey: (rank: Int, group: AreaGroup)] = [:]
        var coverage: [GeoBounds] = []
        var points: [DrawnPOI] = []
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
                      let level = levels.drawnLevel(forBits: wantedBits, steps: steps),
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
                    guard points.count < Self.maximumPoints else { continue }
                    for poi in pointsOfInterest(key, cell: cell, open: open) where MapFeatureReader.contains(area, poi.coordinate) {
                        let icon = open.icons[poi.type]
                        // The style has the type but draws nothing for it.
                        if icon == nil, open.style?.points[poi.type] != nil { continue }
                        points.append(DrawnPOI(poi: poi, icon: icon))
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
        return MapFeatureSet(lines: lines.map(\.value), areas: areas.map(\.value.group), points: points, coverage: coverage)
    }

    /// The points of interest of one map in `area`, on the level drawn at `metersPerPoint`, as the tiles read them,
    /// with how the style writes their names. Not thinned (see `MapPOI.shown`).
    func pointNames(in area: GeoBounds, metersPerPoint: Double, map url: URL, detailOffset: Int) -> [POIName] {
        let bits = MapFeatureReader.detailBits(metersPerPoint: metersPerPoint)
        var result: [POIName] = []
        for file in files(in: url.deletingLastPathComponent()) where file.url.lastPathComponent == url.lastPathComponent {
            guard !Task.isCancelled, let open = openMap(file) else { continue }
            for subfile in open.image.subfiles {
                guard !Task.isCancelled else { return [] }
                guard let bounds = subfile.bounds, subfile.parts.contains("RGN"), MapFeatureReader.intersects(bounds, area),
                      let levels = levels(for: subfile.name, in: file.url.path, image: open.image),
                      let level = levels.drawnLevel(forBits: bits, steps: detailOffset),
                      let subdivisions = subdivisions(for: subfile.name, in: file.url.path, image: open.image) else { continue }
                for (index, cell) in subdivisions.enumerated()
                where cell.level == level.level && MapFeatureReader.intersects(cell.bounds, area) {
                    let key = CellKey(file: file.url.path, subfile: subfile.name, index: index)
                    for poi in pointsOfInterest(key, cell: cell, open: open) where MapFeatureReader.contains(area, poi.coordinate) {
                        let style = open.style?.points[poi.type]
                        let icon = open.icons[poi.type]
                        if icon == nil, style != nil { continue }
                        result.append(POIName(
                            poi: poi, labelled: style?.labelSize != GarminTypStyle.LabelSize.none, iconWidth: icon?.width ?? 5,
                            size: style?.labelSize ?? .standard, colour: style?.labelColour.map(MapRGB.init)
                        ))
                    }
                }
            }
        }
        return result
    }

    /// The point types the maps' styles define, with each type's name and icon, for choosing which to show. Types
    /// whose icon is transparent are left out, since they are never drawn; so are places.
    func pointTypes(maps urls: [URL]) -> [POIType] {
        var result: [Int: POIType] = [:]
        for url in urls {
            for file in files(in: url.deletingLastPathComponent()) where file.url.lastPathComponent == url.lastPathComponent {
                guard let open = openMap(file), let style = open.style else { continue }
                for (type, point) in style.points where result[type] == nil && !(0x0100...0x1100).contains(type) {
                    guard let icon = open.icons[type] else { continue }
                    result[type] = POIType(type: type, name: point.name, icon: icon)
                }
            }
        }
        return result.values.sorted { $0.type < $1.type }
    }

    /// The points of interest of one cell, with their names and priorities, from the cache when decoded recently.
    private func pointsOfInterest(_ key: CellKey, cell: GarminSubdivision, open: OpenMap) -> [MapPOI] {
        if let cached = poiCells[key] {
            return cached
        }
        let labels = labels(for: key.subfile, in: key.file, image: open.image)
        let points = (try? open.image.points(of: key.subfile, in: cell)) ?? []
        let decoded = points.compactMap { point -> MapPOI? in
            guard !point.isPlace else { return nil }
            let name = point.labelOffset == 0 ? nil : labels?.name(at: point.labelOffset, poi: point.labelIsPOI)
                .flatMap { $0.contains(where: \.isLetter) ? MapPlace.displayName($0) : nil }
            let labelled = open.style?.points[point.type]?.labelSize != GarminTypStyle.LabelSize.none
            return MapPOI(
                type: point.type, coordinate: point.coordinate, name: name,
                priority: MapPOI.priority(named: name != nil, labelled: labelled)
            )
        }
        poiCells[key] = decoded
        poiCellOrder.append(key)
        if poiCellOrder.count > Self.maximumCachedCells {
            poiCells[poiCellOrder.removeFirst()] = nil
        }
        return decoded
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
        let icons = (style?.points ?? [:]).compactMapValues(POIIcon.init)
        let open = OpenMap(size: file.size, modified: file.modified, image: image, style: style, areaRanks: ranks, icons: icons)
        maps[key] = open
        cells = cells.filter { $0.key.file != key }
        cellOrder.removeAll { $0.file == key }
        placeCells = placeCells.filter { $0.key.file != key }
        placeCellOrder.removeAll { $0.file == key }
        lineNameCells = lineNameCells.filter { $0.key.file != key }
        lineNameOrder.removeAll { $0.file == key }
        poiCells = poiCells.filter { $0.key.file != key }
        poiCellOrder.removeAll { $0.file == key }
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


    /// Whether a line of this type has its name written along it, and how important the name is: big roads most,
    /// then streets and tracks, then water. Nil for railways, tram and bus lines, cycle and hiking route networks,
    /// boundaries, contours and other lines whose names would only clutter the map.
    static func nameKind(_ type: Int) -> (importance: Int, isWater: Bool)? {
        let base = baseType(type)
        if type >= 0x10000 {
            switch (type >> 8) & 0xFF {
            case 0x00:
                // OFM's streets and roads, biggest first; its other lines here are outlines and route numbers.
                let sub = type & 0xFF
                return [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x15, 0x16, 0x18].contains(sub) ? (max(0, 30 - sub), false) : nil
            case 0x01:
                // Roads again, drawn another way; 0x02 is a via ferrata.
                let sub = type & 0xFF
                return [0x01, 0x03, 0x04, 0x05, 0x06].contains(sub) ? (max(0, 22 - sub), false) : nil
            case 0x0A:
                return (8, true)
            default:
                return nil
            }
        }
        switch base {
        case 0x01...0x0D, 0x0F, 0x13, 0x16, 0x26: return (max(0, 30 - base), false)
        case 0x18, 0x1F: return (8, true)
        default: return nil
        }
    }

    static func contains(_ area: GeoBounds, _ c: Coordinate) -> Bool {
        c.latitude <= area.north && c.latitude >= area.south && c.longitude >= area.west && c.longitude <= area.east
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
