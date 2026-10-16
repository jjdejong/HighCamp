import BaseCampCore
import BaseCampIMG
import Foundation

/// Names route stops that have none from the Garmin maps (`StopNames`): when a stop is added, when it is moved (a
/// name from the map goes with the old place), and for routes made before. A name the user typed is kept.
@MainActor
final class StopNamer {
    static let shared = StopNamer()

    /// Stops, at their place, where the maps had no name: not read again until they move.
    private var unnamed: Set<String> = []

    /// Reads names for the library's unnamed stops and gives them to the store.
    func nameStops(in store: LibraryStore, maps: [URL]) async {
        guard !maps.isEmpty else { return }
        let waiting = store.library.routes.flatMap { route in
            route.stops.filter { $0.needsName && !unnamed.contains(Self.key($0)) }.map { (route: route.id, stop: $0) }
        }
        guard !waiting.isEmpty else { return }
        // Edits come in bursts (dragging, clicking stops in): wait for them to settle.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        var found: [LibraryStore.MapStopName] = []
        for item in waiting {
            guard !Task.isCancelled else { break }
            if let name = await Self.name(at: item.stop.coordinate, maps: maps) {
                found.append(.init(route: item.route, stop: item.stop.id, coordinate: item.stop.coordinate, name: name))
            } else {
                unnamed.insert(Self.key(item.stop))
            }
        }
        // Names found before a newer edit stopped the reading still fit their stops if those did not move.
        store.applyMapStopNames(found)
    }

    private static func key(_ stop: RouteStop) -> String {
        "\(stop.id)|\(stop.coordinate.latitude)|\(stop.coordinate.longitude)"
    }

    /// What the maps show at a place, read at their finest level: points of interest, streets and paths, and areas
    /// within about 100 m, places within a few kilometres.
    static func name(at coordinate: Coordinate, maps: [URL]) async -> String? {
        func box(_ metres: Double) -> GeoBounds {
            let lat = metres / 111_320
            let lon = lat / max(cos(coordinate.latitude * .pi / 180), 0.1)
            return GeoBounds(north: coordinate.latitude + lat, east: coordinate.longitude + lon,
                             south: coordinate.latitude - lat, west: coordinate.longitude - lon)
        }
        let near = box(120)
        let wide = box(StopNames.farPlaceReach)
        let cache = MapFeatureCache.shared
        var points: [MapPOI] = []
        var lines: [NamedLine] = []
        var places: [MapPlace] = []
        var areas: [NamedArea] = []
        for map in maps {
            points += await cache.pointNames(in: near, metersPerPoint: 1, map: map, detailOffset: 0).map(\.poi)
            lines += await cache.namedLines(in: near, metersPerPoint: 1, map: map, detailOffset: 0)
            areas += await cache.namedAreas(in: near, metersPerPoint: 1, map: map, detailOffset: 0)
            places += await cache.places(in: wide, metersPerPoint: 1, map: map, detailOffset: 0)
        }
        return StopNames.name(at: coordinate, points: points, lines: lines, places: places, areas: areas)
    }
}
