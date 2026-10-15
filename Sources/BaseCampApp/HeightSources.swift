import BaseCampCore
import BaseCampDEM
import BaseCampIMG
import Foundation

/// Where heights for tracks, routes, waypoints and the route planner come from: the elevation models (DEM) in a
/// folder, and the heights the Garmin maps carry, as BaseCamp uses them. One fills in where the other has none.
struct HeightSources: Equatable, Sendable {
    /// The folder of elevation models.
    var folder: URL
    /// The full Garmin maps that are on, top first.
    var maps: [URL]
    /// The maps' heights before the folder's. The folder's models are usually finer.
    var mapsFirst = false

    /// One height per coordinate, nil where neither source has one. A line takes all its heights from one source
    /// when one covers it (see `HeightChoice`); without `mixing`, it never mixes them.
    func heights(for coordinates: [Coordinate], mixing: Bool = true) async -> [Double?] {
        guard !coordinates.isEmpty else { return [] }
        let first = mapsFirst ? await fromMaps(coordinates) : await fromFolder(coordinates)
        guard !HeightChoice.covers(first) else { return first }
        let second = mapsFirst ? await fromFolder(coordinates) : await fromMaps(coordinates)
        return HeightChoice.combine(first, second, mixing: mixing)
    }

    /// The folder's heights, read on a background thread with a model of its own (GDAL handles are not shared).
    private func fromFolder(_ coordinates: [Coordinate]) async -> [Double?] {
        let folder = folder
        return await Task.detached(priority: .userInitiated) {
            (try? ElevationModel(folder: folder))?.elevations(for: coordinates) ?? Array(repeating: nil, count: coordinates.count)
        }.value
    }

    /// The maps' heights, from the finest grid of the first map tile that has a height at each place.
    private func fromMaps(_ coordinates: [Coordinate]) async -> [Double?] {
        let none = [Double?](repeating: nil, count: coordinates.count)
        guard !maps.isEmpty else { return none }
        let latitudes = coordinates.map(\.latitude), longitudes = coordinates.map(\.longitude)
        guard let north = latitudes.max(), let south = latitudes.min(), let east = longitudes.max(), let west = longitudes.min() else {
            return none
        }
        let parts = await MapReliefCache.shared.parts(in: GeoBounds(north: north, east: east, south: south, west: west), maps: maps)
        guard !parts.isEmpty else { return none }
        return await Task.detached(priority: .userInitiated) {
            coordinates.map { place -> Double? in
                for part in parts
                where place.latitude <= part.bounds.north && place.latitude >= part.bounds.south
                    && place.longitude <= part.bounds.east && place.longitude >= part.bounds.west {
                    if let height = part.dem.elevation(latitude: place.latitude, longitude: place.longitude, level: part.finestLevel) {
                        return height
                    }
                }
                return nil
            }
        }.value
    }
}
