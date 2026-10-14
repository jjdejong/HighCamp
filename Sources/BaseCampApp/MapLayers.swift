import AppKit
import MapKit
import Observation

/// Base maps. The Garmin maps are drawn from the map folder, as BaseCamp draws them; Apple's maps are built in;
/// the others are tile servers.
enum BaseMapLayer: String, CaseIterable, Identifiable {
    case garmin
    case appleStandard
    case appleHybrid
    case ignPlan
    case openTopoMap
    case openStreetMap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .garmin: "Garmin maps (ticked above)"
        case .appleStandard: "Apple Maps"
        case .appleHybrid: "Apple Maps, satellite"
        case .ignPlan: "IGN Plan (France, trails and spot heights)"
        case .openTopoMap: "OpenTopoMap (contours built in)"
        case .openStreetMap: "OpenStreetMap"
        }
    }

    var attribution: String {
        switch self {
        case .garmin: "Garmin maps from the map folder; elsewhere © OpenStreetMap contributors"
        case .appleStandard, .appleHybrid: "Apple Maps"
        case .ignPlan: "IGN Plan V2, Etalab licence"
        case .openTopoMap: "© OpenStreetMap, © OpenTopoMap (CC-BY-SA)"
        case .openStreetMap: "© OpenStreetMap contributors"
        }
    }

    /// Apple's own maps, drawn by MapKit rather than from tiles.
    var isApple: Bool {
        self == .appleStandard || self == .appleHybrid
    }

    /// The address of one tile of this layer, or nil for the maps that are not downloaded tiles.
    func tileURL(z: Int, x: Int, y: Int) -> URL? {
        switch self {
        case .garmin, .appleStandard, .appleHybrid:
            nil
        case .ignPlan:
            MapTileURLs.ignWMTS(layer: "GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2", z: z, x: x, y: y)
        case .openTopoMap:
            URL(string: "https://a.tile.opentopomap.org/\(z)/\(x)/\(y).png")
        case .openStreetMap:
            URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png")
        }
    }

    /// The highest zoom level the tile server has for this layer.
    var maximumTileZoom: Int {
        switch self {
        case .garmin, .appleStandard, .appleHybrid: 19
        case .ignPlan: 18
        case .openTopoMap: 17
        case .openStreetMap: 19
        }
    }

    /// The tile overlay for this layer, or nil for Apple's maps. The Garmin maps are drawn from `garmin`.
    @MainActor
    func tileOverlay(garmin: GarminMapConfiguration) -> MKTileOverlay? {
        switch self {
        case .garmin:
            GarminTileOverlay(configuration: garmin)
        case .appleStandard, .appleHybrid:
            nil
        case .ignPlan:
            TileSourceOverlay(maximumZoom: 18) { z, x, y in
                MapTileURLs.ignWMTS(layer: "GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2", z: z, x: x, y: y)
            }
        case .openTopoMap:
            TileSourceOverlay(maximumZoom: 17) { z, x, y in
                URL(string: "https://a.tile.opentopomap.org/\(z)/\(x)/\(y).png")!
            }
        case .openStreetMap:
            TileSourceOverlay(maximumZoom: 19) { z, x, y in
                URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png")!
            }
        }
    }
}

enum MapTileURLs {
    /// IGN's contour lines: a transparent layer that can sit over any base map. France only.
    static let contourAttribution = "Contour lines: IGN, Etalab licence"

    static func ignWMTS(layer: String, z: Int, x: Int, y: Int) -> URL {
        URL(string: "https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=\(layer)&STYLE=normal&TILEMATRIXSET=PM&TILEMATRIX=\(z)&TILEROW=\(y)&TILECOL=\(x)&FORMAT=image/png")!
    }

    static func contourOverlay() -> MKTileOverlay {
        TileSourceOverlay(maximumZoom: 16) { z, x, y in
            ignWMTS(layer: "ELEVATION.CONTOUR.LINE", z: z, x: x, y: y)
        }
    }
}

/// A tile overlay whose tile addresses come from a closure.
final class TileSourceOverlay: MKTileOverlay {
    private let makeURL: (Int, Int, Int) -> URL

    init(maximumZoom: Int, makeURL: @escaping (Int, Int, Int) -> URL) {
        self.makeURL = makeURL
        super.init(urlTemplate: nil)
        self.maximumZ = maximumZoom
        self.canReplaceMapContent = true
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        makeURL(path.z, path.x, path.y)
    }
}

/// How much detail the Garmin maps show at a given zoom, like BaseCamp's map detail setting. Each step moves the
/// map level used by one, so "More" shows at one zoom what "Normal" shows one level closer in.
enum GarminDetail: String, CaseIterable, Identifiable {
    case lowest, low, normal, high, highest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
    }

    /// Bits added to the level the zoom calls for.
    var offset: Int {
        switch self {
        case .lowest: -2
        case .low: -1
        case .normal: 0
        case .high: 1
        case .highest: 2
        }
    }
}

/// The base map a picture is drawn on: the layer, the IGN contours, and the Garmin maps to draw.
struct PictureBase: Sendable {
    let layer: BaseMapLayer
    let contours: Bool
    let garmin: GarminMapConfiguration
}

/// Which base map and contour overlay to show, and how strong the contours are. Kept between launches.
@MainActor
@Observable
final class MapLayerSettings {
    var base: BaseMapLayer {
        didSet { UserDefaults.standard.set(base.rawValue, forKey: "map.base") }
    }
    var showContours: Bool {
        didSet { UserDefaults.standard.set(showContours, forKey: "map.showContours") }
    }
    var contourOpacity: Double {
        didSet { UserDefaults.standard.set(contourOpacity, forKey: "map.contourOpacity") }
    }
    /// How much detail the Garmin maps show. See `GarminDetail`.
    var garminDetail: GarminDetail {
        didSet { UserDefaults.standard.set(garminDetail.rawValue, forKey: "map.garminDetailLevel") }
    }
    /// Garmin maps drawn paler and with plain areas, nearer IGN's look than the maps' own strong style.
    var garminSoftColors: Bool {
        didSet { UserDefaults.standard.set(garminSoftColors, forKey: "map.garminSoftColors") }
    }
    /// Relief shading on the Garmin maps, from the heights the maps carry, as BaseCamp draws it. 0 is off.
    var reliefStrength: Double {
        didSet { UserDefaults.standard.set(reliefStrength, forKey: "map.reliefStrength") }
    }
    /// Dashed outlines and names for the area each map in the map folder covers.
    var showCoverage: Bool {
        didSet { UserDefaults.standard.set(showCoverage, forKey: "map.showCoverage") }
    }

    init() {
        let defaults = UserDefaults.standard
        // The Garmin maps first, as in BaseCamp.
        base = BaseMapLayer(rawValue: defaults.string(forKey: "map.base") ?? "") ?? .garmin
        showContours = defaults.bool(forKey: "map.showContours")
        let opacity = defaults.double(forKey: "map.contourOpacity")
        contourOpacity = opacity > 0 ? opacity : 0.7
        showCoverage = defaults.bool(forKey: "map.showCoverage")
        garminDetail = GarminDetail(rawValue: defaults.string(forKey: "map.garminDetailLevel") ?? "") ?? .normal
        garminSoftColors = defaults.object(forKey: "map.garminSoftColors") as? Bool ?? true
        reliefStrength = defaults.object(forKey: "map.reliefStrength") as? Double ?? Self.mediumRelief
    }

    static let lightRelief = 0.3
    static let mediumRelief = 0.45
    static let strongRelief = 0.65

    /// The Garmin maps as the map pane draws them.
    func garminConfiguration(_ maps: GarminMapListStore) -> GarminMapConfiguration {
        maps.configuration(detail: garminDetail, softColors: garminSoftColors, relief: reliefStrength)
    }

    /// The base map for a picture of what the screen shows.
    func pictureBase(garmin: GarminMapListStore) -> PictureBase {
        PictureBase(layer: base, contours: showContours, garmin: garminConfiguration(garmin))
    }

    /// Attribution for the layers on screen.
    var attribution: String {
        var parts = [base.attribution]
        if showContours {
            parts.append(MapTileURLs.contourAttribution)
        }
        return parts.joined(separator: " · ")
    }
}
