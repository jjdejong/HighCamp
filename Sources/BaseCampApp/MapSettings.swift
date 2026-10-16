import Foundation
import Observation

/// Where the Garmin map files (`.img`) are.
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
        } else if let qmapshack = Self.qmapshackFolder {
            // On first launch, the maps QMapShack shows, if it is installed; kept from then on, whatever QMapShack does.
            folder = qmapshack
            UserDefaults.standard.set(qmapshack.path, forKey: Self.defaultsKey)
        } else {
            folder = Self.defaultFolder
        }
    }

    /// The map folder of QMapShack, if it is installed, read from its preferences. Nothing is written there.
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

    nonisolated static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/HighCamp/Maps")
    }
}
