import Foundation
import Observation

/// Where the map files are. This is the folder QMapShack reads its IMG maps from.
@MainActor
@Observable
final class MapSettings {
    private static let defaultsKey = "mapFolderPath"

    var folder: URL {
        didSet {
            UserDefaults.standard.set(folder.path, forKey: Self.defaultsKey)
        }
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.defaultsKey) {
            folder = URL(fileURLWithPath: path)
        } else {
            folder = Self.qmapshackFolder ?? Self.fallbackFolder
        }
    }

    /// The folder QMapShack is set to use, read from its preferences. Nothing is written there.
    nonisolated static var qmapshackFolder: URL? {
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/org.qlandkarte.QMapShack.plist")
        guard let dictionary = NSDictionary(contentsOf: preferences),
              let paths = dictionary["Canvas.mapPath"] as? [String],
              let first = paths.first else {
            return nil
        }
        return URL(fileURLWithPath: first)
    }

    nonisolated static var fallbackFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/BaseCampClone/Maps")
    }
}
