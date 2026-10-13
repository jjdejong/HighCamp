import BaseCampIMG
import BaseCampCore
import Foundation
import Observation

/// The area each map in the map folder covers, read from the map headers.
@MainActor
@Observable
final class MapCoverageStore {
    private(set) var footprints: [MapFootprint] = []

    /// Reads every IMG map in `folder`. Runs off the main thread, so the map stays responsive.
    func reload(folder: URL) async {
        let found = await Task.detached { () -> [MapFootprint] in
            guard let maps = try? MapFolder.imgMaps(in: folder) else { return [] }
            var result: [MapFootprint] = []
            for map in maps {
                if let img = try? GarminIMG(url: map.url), let bounds = img.coverage {
                    result.append(MapFootprint(name: map.name, bounds: bounds))
                }
            }
            return result
        }.value
        footprints = found
    }
}

/// One map's coverage, for drawing on the map.
struct MapFootprint: Equatable, Sendable {
    let name: String
    let bounds: GeoBounds

    var center: Coordinate {
        Coordinate(latitude: (bounds.north + bounds.south) / 2, longitude: (bounds.east + bounds.west) / 2)
    }

    /// The rectangle's corners, clockwise from north-west.
    var corners: [Coordinate] {
        [
            Coordinate(latitude: bounds.north, longitude: bounds.west),
            Coordinate(latitude: bounds.north, longitude: bounds.east),
            Coordinate(latitude: bounds.south, longitude: bounds.east),
            Coordinate(latitude: bounds.south, longitude: bounds.west),
        ]
    }
}
