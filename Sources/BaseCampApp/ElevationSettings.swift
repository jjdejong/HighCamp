import Foundation
import Observation

/// The folder of elevation models (DEM) used to fill in heights. Kept between launches.
@MainActor
@Observable
final class ElevationSettings {
    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "dem.folder") }
    }

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "dem.folder") {
            folder = URL(fileURLWithPath: saved)
        } else {
            folder = Self.qmapshackFolder ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Developer/BaseCampClone/DEM")
        }
    }

    /// QMapShack's DEM folder, shared with this app.
    static var qmapshackFolder: URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SynologyDrive/QMapShack/DEM")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }
}
