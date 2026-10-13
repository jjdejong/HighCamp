import BaseCampCore
import BaseCampIMG
import Foundation
import Observation

/// The Garmin map features (roads, contours, areas) for the part of the map on screen.
@MainActor
@Observable
final class MapFeatureStore {
    /// The features of the current view. Replaced as a whole, so the map compares it by identity.
    private(set) var layer: FeatureLayer?
    private var enabled = false
    private var viewport: GeoBounds?
    private var metersPerPoint = 0.0
    private var folder: URL?
    private var task: Task<Void, Never>?
    /// The finest level the reader may use, in bits. See `GarminDetail`.
    private var maximumBits = GarminDetail.standard.rawValue

    /// Changes how much detail is read, and reads again for the current view.
    func setMaximumBits(_ bits: Int) {
        guard bits != maximumBits else { return }
        maximumBits = bits
        if enabled {
            scheduleLoad()
        }
    }

    /// Remembers the view, and reads its features when they are shown.
    func viewportChanged(_ bounds: GeoBounds, metersPerPoint: Double, folder: URL) {
        viewport = bounds
        self.metersPerPoint = metersPerPoint
        self.folder = folder
        if enabled {
            scheduleLoad()
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            scheduleLoad()
        } else {
            task?.cancel()
            layer = nil
        }
    }

    /// Reads the features after the map has been still for a moment.
    private func scheduleLoad() {
        guard let viewport, let folder else { return }
        task?.cancel()
        let metersPerPoint = metersPerPoint
        let maximumBits = maximumBits
        task = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await MapFeatureCache.shared.features(
                in: viewport,
                metersPerPoint: metersPerPoint,
                folder: folder,
                maximumBits: maximumBits
            )
            guard !Task.isCancelled else { return }
            layer = FeatureLayer(lines: found.lines, areas: found.areas)
        }
    }
}

/// Paths drawn with one colour and width. Each group becomes one map overlay, so many paths stay fast.
struct LineGroup: Sendable {
    let rgb: MapRGB
    let width: Double
    var paths: [[Coordinate]]
}

/// Rings filled with one colour.
struct AreaGroup: Sendable {
    let fill: MapRGB
    var rings: [[Coordinate]]
}

/// The features read for one view. Compared by identity: a new load is a new layer.
final class FeatureLayer: Equatable, @unchecked Sendable {
    let lines: [LineGroup]
    let areas: [AreaGroup]

    init(lines: [LineGroup], areas: [AreaGroup]) {
        self.lines = lines
        self.areas = areas
    }

    static func == (left: FeatureLayer, right: FeatureLayer) -> Bool {
        left === right
    }
}

/// Opens the IMG maps in a folder once, and keeps them, their style and their tables in memory. A map is
/// opened again only when its file changes. Reads the features for a view. Work happens on this actor, one view at a time.
actor MapFeatureCache {
    static let shared = MapFeatureCache()

    /// Enough for a readable view. Paths are grouped by style, so many of them stay fast to draw.
    static let maximumLinePaths = 60_000
    static let maximumAreaRings = 30_000

    private struct Tables {
        let levels: [GarminMapLevel]
        let subdivisions: [GarminSubdivision]
    }

    private struct OpenMap {
        let size: Int64
        let modified: Date?
        let image: GarminIMG
        /// The map's own style (TYP), or nil when the map has none.
        let style: GarminTypStyle?
        /// The drawing position of each polygon type, bottom first. Types missing here are not drawn.
        let areaRanks: [Int: Int]
        var tables: [String: Tables] = [:]
    }

    /// Identifies a style: colour in 0 to 255, and width in tenths of a point.
    private struct StyleKey: Hashable, Comparable {
        let red: Int
        let green: Int
        let blue: Int
        let width: Int

        init(_ rgb: MapRGB, width: Double) {
            red = Int((rgb.red * 255).rounded())
            green = Int((rgb.green * 255).rounded())
            blue = Int((rgb.blue * 255).rounded())
            self.width = Int((width * 10).rounded())
        }

        static func < (left: StyleKey, right: StyleKey) -> Bool {
            (left.red, left.green, left.blue, left.width) < (right.red, right.green, right.blue, right.width)
        }
    }

    /// One group per feature type and style. Grouping by type keeps each type's place in the drawing order.
    private struct GroupKey: Hashable, Comparable {
        let type: Int
        let style: StyleKey

        static func < (left: GroupKey, right: GroupKey) -> Bool {
            left.type != right.type ? left.type < right.type : left.style < right.style
        }
    }

    private var maps: [String: OpenMap] = [:]

    func features(in viewport: GeoBounds, metersPerPoint: Double, folder: URL, maximumBits: Int) -> MapFeatureSet {
        guard let files = try? MapFolder.imgMaps(in: folder) else { return MapFeatureSet() }
        let wantedBits = min(MapFeatureReader.detailBits(metersPerPoint: metersPerPoint), maximumBits)
        var lineGroups: [GroupKey: LineGroup] = [:]
        var areaGroups: [GroupKey: (rank: Int, group: AreaGroup)] = [:]
        var linePaths = 0
        var areaRings = 0

        for file in files {
            guard !Task.isCancelled, let open = openMap(file) else { continue }
            for subfile in open.image.subfiles {
                guard !Task.isCancelled else { return MapFeatureSet() }
                guard let bounds = subfile.bounds, subfile.parts.contains("RGN"),
                      MapFeatureReader.intersects(bounds, viewport),
                      let tables = tables(for: subfile.name, in: file.url.path, image: open.image) else { continue }

                for level in MapFeatureReader.levelsToTry(tables.levels, forBits: wantedBits) {
                    var found = false
                    let cells = tables.subdivisions.filter {
                        $0.level == level.level && MapFeatureReader.intersects($0.bounds, viewport)
                    }
                    for cell in cells {
                        guard let geometries = try? open.image.geometries(of: subfile.name, in: cell) else { continue }
                        for geometry in geometries {
                            found = true
                            if geometry.isPolygon {
                                guard areaRings < Self.maximumAreaRings,
                                      let rank = open.areaRanks[geometry.type],
                                      let fill = MapFeatureReader.fill(for: geometry.type, style: open.style),
                                      geometry.coordinates.count >= 3 else { continue }
                                let key = GroupKey(type: geometry.type, style: StyleKey(fill, width: 0))
                                areaGroups[key, default: (rank, AreaGroup(fill: fill, rings: []))].group.rings.append(geometry.coordinates)
                                areaRings += 1
                            } else if geometry.coordinates.count >= 2 {
                                guard linePaths < Self.maximumLinePaths else { return Self.set(lineGroups, areaGroups) }
                                let line = MapFeatureReader.lineStyle(for: geometry.type, style: open.style)
                                let key = GroupKey(type: geometry.type, style: StyleKey(line.rgb, width: line.width))
                                lineGroups[key, default: LineGroup(rgb: line.rgb, width: line.width, paths: [])].paths.append(geometry.coordinates)
                                linePaths += 1
                            }
                        }
                    }
                    // Some maps leave their coarsest level empty, so go to the next finer level when this one has nothing here.
                    if found {
                        break
                    }
                }
            }
        }
        return Self.set(lineGroups, areaGroups)
    }

    /// The groups in drawing order, bottom first, the same for every load: areas in the map's draw order, and lines
    /// by type, as QMapShack draws them.
    private static func set(_ lines: [GroupKey: LineGroup], _ areas: [GroupKey: (rank: Int, group: AreaGroup)]) -> MapFeatureSet {
        let orderedAreas = areas.sorted { ($0.value.rank, $0.key) < ($1.value.rank, $1.key) }.map(\.value.group)
        let orderedLines = lines.sorted { $0.key < $1.key }.map(\.value)
        return MapFeatureSet(lines: orderedLines, areas: orderedAreas)
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
        return open
    }

    /// The levels and subdivisions of one subfile, read once per open map.
    private func tables(for name: String, in key: String, image: GarminIMG) -> Tables? {
        if let cached = maps[key]?.tables[name] {
            return cached
        }
        guard let levels = try? image.mapLevels(of: name),
              let subdivisions = try? image.subdivisions(of: name) else { return nil }
        let tables = Tables(levels: levels, subdivisions: subdivisions)
        maps[key]?.tables[name] = tables
        return tables
    }
}

/// The groups read for one view.
struct MapFeatureSet: Sendable {
    var lines: [LineGroup] = []
    var areas: [AreaGroup] = []
}

/// Helpers for reading the Garmin map features: detail levels, the view test, and colours.
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

    /// The levels to try, in order: the most detailed level that does not exceed the wanted bits (or the
    /// coarsest level if none does), then each finer level. This is QMapShack's rule in `CMapIMG::draw`.
    static func levelsToTry(_ levels: [GarminMapLevel], forBits bits: Int) -> [GarminMapLevel] {
        let sorted = levels.sorted { $0.bits < $1.bits }
        let start = sorted.lastIndex { $0.bits <= bits } ?? 0
        return Array(sorted[start...])
    }

    static func intersects(_ a: GeoBounds, _ b: GeoBounds) -> Bool {
        a.south <= b.north && a.north >= b.south && a.west <= b.east && a.east >= b.west
    }

    /// The colour and width of a line. The map's style gives them when it has one for the type.
    static func lineStyle(for type: Int, style: GarminTypStyle?) -> (rgb: MapRGB, width: Double) {
        if let entry = style?.lines[type] {
            return (MapRGB(entry.colour), Double(max(1, entry.width)))
        }
        switch color(for: type) {
        case .contour: return (MapRGB(red: 0.72, green: 0.45, blue: 0.25), 3)
        case .road: return (MapRGB(red: 0.95, green: 0.70, blue: 0.20), 3)
        case .water: return (MapRGB(red: 0.30, green: 0.60, blue: 0.90), 3)
        default: return (MapRGB(red: 0.45, green: 0.45, blue: 0.45), 3)
        }
    }

    /// The fill of a polygon. With a style, only the types it fills are drawn. Without one, a rough colour by family.
    /// The definition area (0x4A) and background (0x4B) polygons only mark where the map has data, so they are
    /// never filled, as in QMapShack.
    static func fill(for type: Int, style: GarminTypStyle?) -> MapRGB? {
        if type == 0x4A || type == 0x4B {
            return nil
        }
        if let style {
            return style.fills[type].map(MapRGB.init)
        }
        switch baseType(type) {
        case 0x01...0x0b: return MapRGB(red: 0.80, green: 0.85, blue: 0.70)
        case 0x14...0x1f: return MapRGB(red: 0.70, green: 0.85, blue: 0.95)
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
}
