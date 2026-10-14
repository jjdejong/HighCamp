import Foundation
import Observation

/// The folder of elevation models (DEM) used to fill in heights. Kept between launches.
@MainActor
@Observable
final class ElevationSettings {
    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "dem.folder") }
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
        let modelFolder = defaults.string(forKey: "dem.folder").map { URL(fileURLWithPath: $0) }
            ?? Self.qmapshackFolder
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/BaseCampClone/DEM")
        folder = modelFolder
        tileFolder = defaults.string(forKey: "dem.tileFolder").map { URL(fileURLWithPath: $0) } ?? modelFolder
        let corridor = defaults.double(forKey: "dem.corridor")
        self.corridor = corridor > 0 ? corridor : 100
    }

    /// QMapShack's DEM folder, shared with this app.
    static var qmapshackFolder: URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SynologyDrive/QMapShack/DEM")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }
}
