import BaseCampCore
import Foundation
import Observation

/// The folder of elevation models (DEM) used to fill in heights, and whether the Garmin maps' own heights come
/// before it. Kept between launches.
@MainActor
@Observable
final class ElevationSettings {
    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "dem.folder") }
    }

    /// The Garmin maps' heights first, the folder's models where the maps have none. Off: the other way round.
    var mapHeightsFirst: Bool {
        didSet { UserDefaults.standard.set(mapHeightsFirst, forKey: "dem.mapHeightsFirst") }
    }

    /// The folder of high-resolution DEM tiles that track DEMs are made from, searched with its subfolders.
    var tileFolder: URL {
        didSet { UserDefaults.standard.set(tileFolder.path, forKey: "dem.tileFolder") }
    }
    /// How far either side of a track the tiles of its track DEM reach, in metres.
    var corridor: Double {
        didSet { UserDefaults.standard.set(corridor, forKey: "dem.corridor") }
    }

    init() {
        let defaults = UserDefaults.standard
        let modelFolder: URL
        if let path = defaults.string(forKey: "dem.folder") {
            modelFolder = URL(fileURLWithPath: path)
        } else if let earlier = Self.earlierDefault {
            // The folder earlier versions used when none was chosen: kept, so updating changes nothing.
            modelFolder = earlier
            defaults.set(earlier.path, forKey: "dem.folder")
        } else {
            modelFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/HighCamp/DEM")
        }
        folder = modelFolder
        mapHeightsFirst = defaults.bool(forKey: "dem.mapHeightsFirst")
        tileFolder = defaults.string(forKey: "dem.tileFolder").map { URL(fileURLWithPath: $0) } ?? modelFolder
        let corridor = defaults.double(forKey: "dem.corridor")
        self.corridor = corridor > 0 ? corridor : 100
    }

    /// Where heights come from: this folder and the full Garmin maps that are on. An item's own track DEM, when it
    /// has one, comes before everything else.
    func sources(maps: GarminMapListStore, trackDEM: URL? = nil) -> HeightSources {
        let configuration = maps.configuration(detail: .normal, softColors: false)
        return HeightSources(
            folder: trackDEM ?? folder,
            maps: configuration.layers.filter { !$0.isOverlay }.reversed().map(\.url),
            mapsFirst: trackDEM == nil && mapHeightsFirst
        )
    }

    /// The DEM folder earlier versions used when none was chosen, if it exists. Read once, to keep it.
    private static var earlierDefault: URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SynologyDrive/QMapShack/DEM")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }
}
