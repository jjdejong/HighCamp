import AppKit
import MapKit
import Observation

/// Base maps. Apple's maps are built in; the others are tile servers.
enum BaseMapLayer: String, CaseIterable, Identifiable {
    case appleStandard
    case appleHybrid
    case ignPlan
    case openTopoMap
    case openStreetMap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleStandard: "Apple Maps"
        case .appleHybrid: "Apple Maps, satellite"
        case .ignPlan: "IGN Plan (France, trails and spot heights)"
        case .openTopoMap: "OpenTopoMap (contours built in)"
        case .openStreetMap: "OpenStreetMap"
        }
    }

    var attribution: String {
        switch self {
        case .appleStandard, .appleHybrid: "Apple Maps"
        case .ignPlan: "IGN Plan V2, Etalab licence"
        case .openTopoMap: "© OpenStreetMap, © OpenTopoMap (CC-BY-SA)"
        case .openStreetMap: "© OpenStreetMap contributors"
        }
    }

    /// The address of one tile of this layer, or nil for Apple's maps, which are not tiles.
    func tileURL(z: Int, x: Int, y: Int) -> URL? {
        switch self {
        case .appleStandard, .appleHybrid:
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
        case .appleStandard, .appleHybrid: 19
        case .ignPlan: 18
        case .openTopoMap: 17
        case .openStreetMap: 19
        }
    }

    /// The tile overlay for this layer, or nil for Apple's maps.
    @MainActor
    func tileOverlay() -> MKTileOverlay? {
        switch self {
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

/// How much map detail the IMG overlay draws at most, as the finest Garmin level it may use.
/// The raw value is the level's detail in bits, the same numbers QMapShack uses.
enum GarminDetail: Int, CaseIterable, Identifiable {
    case overview = 18
    case standard = 22
    case full = 24

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .standard: "Standard"
        case .full: "Full (slow)"
        }
    }
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
    /// Roads, contours and rivers read from the IMG maps, drawn for the part of the map on screen.
    var showGarminDetail: Bool {
        didSet { UserDefaults.standard.set(showGarminDetail, forKey: "map.showGarminDetail") }
    }
    /// The finest map level the IMG overlay may draw. The finest level is the heaviest, so the default stops short of it.
    var garminDetail: GarminDetail {
        didSet { UserDefaults.standard.set(garminDetail.rawValue, forKey: "map.garminDetail") }
    }
    /// Dashed outlines and names for the area each map in the map folder covers.
    var showCoverage: Bool {
        didSet { UserDefaults.standard.set(showCoverage, forKey: "map.showCoverage") }
    }

    init() {
        let defaults = UserDefaults.standard
        base = BaseMapLayer(rawValue: defaults.string(forKey: "map.base") ?? "") ?? .appleStandard
        showContours = defaults.bool(forKey: "map.showContours")
        let opacity = defaults.double(forKey: "map.contourOpacity")
        contourOpacity = opacity > 0 ? opacity : 0.7
        showCoverage = defaults.object(forKey: "map.showCoverage") == nil ? true : defaults.bool(forKey: "map.showCoverage")
        showGarminDetail = defaults.object(forKey: "map.showGarminDetail") == nil ? true : defaults.bool(forKey: "map.showGarminDetail")
        garminDetail = GarminDetail(rawValue: defaults.integer(forKey: "map.garminDetail")) ?? .standard
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
