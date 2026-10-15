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

    /// Passes, summits, glaciers and national parks: their names are written above street names.
    public var isLandmark: Bool {
        [0x6401, 0x6616, 0x650A, 0x640E].contains(type)
    }

    /// A point whose style writes its name and that has one comes first (a pass, a summit, a café), then other named
    /// points (a shop, a bus stop), then the unnamed ones (a bench, a bollard).
    public static func priority(named: Bool, labelled: Bool) -> Int {
        (named && labelled ? 2 : 0) + (named ? 1 : 0)
    }

    /// Below this zoom only landmarks are shown: a town's shops and benches would hide its streets.
    public static let minimumZoom = 15

    /// The points to show at a zoom: in each square of `cellSize` points of the Web Mercator world at that zoom
    /// (256 points per tile), only the one with the highest priority; ties go to the smaller type, then to the
    /// point further north and west. Below `minimumZoom`, landmarks only. A point's square depends only on where it
    /// is, so every tile, and the labels, choose the same points; and a square holds exactly four of the next
    /// zoom's, so a point shown at one zoom is shown at the next.
    public static func shown(_ points: [MapPOI], zoom: Int, cellSize: Double = 32) -> [MapPOI] {
        let worldSize = 256 * pow(2, Double(zoom))
        var best: [Cell: MapPOI] = [:]
        for point in points where zoom >= minimumZoom || point.isLandmark {
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

/// The families of Garmin point types, for choosing which points the map shows. Garmin groups its point types by
/// their first byte; maps such as OFM follow that grouping for most of their types.
public enum POICategory: Int, CaseIterable, Identifiable, Sendable {
    case food, lodging, attractions, entertainment, shopping, services, transport, emergency
    case amenities, barriers, manMade, water, land, other

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .food: "Food and Drink"
        case .lodging: "Lodging"
        case .attractions: "Attractions and Culture"
        case .entertainment: "Entertainment and Sport"
        case .shopping: "Shopping"
        case .services: "Services"
        case .transport: "Transport and Parking"
        case .emergency: "Health, Emergency and Government"
        case .amenities: "Amenities and Facilities"
        case .barriers: "Barriers and Road Hazards"
        case .manMade: "Buildings and Structures"
        case .water: "Water"
        case .land: "Landmarks and Nature"
        case .other: "Other"
        }
    }

    /// The family of a point type (type byte then subtype byte; version 2 types go to `other`).
    public static func of(_ type: Int) -> POICategory {
        guard type < 0x10000 else { return .other }
        let family = type >> 8
        switch family {
        case 0x2A: return .food
        case 0x2B: return .lodging
        case 0x2C: return .attractions
        case 0x2D: return .entertainment
        case 0x2E: return .shopping
        case 0x2F:
            // Fuel, ferries, bus stops and parking are transport; banks, post offices and the like are services.
            return [0x2F01, 0x2F08, 0x2F09, 0x2F0A, 0x2F0B, 0x2F11, 0x2F12, 0x2F16, 0x2F17].contains(type) ? .transport : .services
        case 0x11: return type == 0x1108 ? .barriers : .transport
        case 0x30: return .emergency
        case 0x32: return .barriers
        case 0x43...0x5F: return .amenities
        case 0x64: return .manMade
        case 0x65: return .water
        case 0x66: return .land
        default: return .other
        }
    }
}
