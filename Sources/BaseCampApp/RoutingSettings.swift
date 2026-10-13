import Foundation
import Observation

/// Where routes come from: a BRouter server on this Mac, or the public one at brouter.de.
@MainActor
@Observable
final class RoutingSettings {
    enum Engine: String, CaseIterable, Identifiable {
        case local
        case online

        var id: String { rawValue }

        var label: String {
            switch self {
            case .local: "Local BRouter"
            case .online: "brouter.de (online)"
            }
        }
    }

    static let defaultLocalServer = "http://127.0.0.1:17777"
    static let defaultOnlineServer = "https://brouter.de"

    private let defaults = UserDefaults.standard

    var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: "routing.engine") }
    }
    var localServer: String {
        didSet { defaults.set(localServer, forKey: "routing.localServer") }
    }
    var onlineServer: String {
        didSet { defaults.set(onlineServer, forKey: "routing.onlineServer") }
    }
    /// The folder with the BRouter jar, `segments4` and `profiles2`.
    var brouterFolder: URL {
        didSet { defaults.set(brouterFolder.path, forKey: "routing.brouterFolder") }
    }
    var javaPath: String {
        didSet { defaults.set(javaPath, forKey: "routing.javaPath") }
    }

    init() {
        let qmapshack = Self.qmapshackSettings()
        engine = Engine(rawValue: defaults.string(forKey: "routing.engine") ?? "") ?? .local
        localServer = defaults.string(forKey: "routing.localServer") ?? Self.defaultLocalServer
        onlineServer = defaults.string(forKey: "routing.onlineServer") ?? Self.defaultOnlineServer
        if let path = defaults.string(forKey: "routing.brouterFolder") {
            brouterFolder = URL(fileURLWithPath: path)
        } else {
            brouterFolder = qmapshack.folder ?? Self.fallbackFolder
        }
        javaPath = defaults.string(forKey: "routing.javaPath") ?? qmapshack.java ?? "/usr/bin/java"
    }

    /// The server requests go to, for the engine chosen.
    var activeServer: URL? {
        URL(string: engine == .local ? localServer : onlineServer)
    }

    /// The BRouter folder and Java that QMapShack is set to use, read from its preferences. Nothing is written.
    nonisolated static func qmapshackSettings() -> (folder: URL?, java: String?) {
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/org.qlandkarte.QMapShack.plist")
        guard let dictionary = NSDictionary(contentsOf: preferences) else {
            return (nil, nil)
        }
        let folder = (dictionary["Route.brouter.localDir"] as? String).map { URL(fileURLWithPath: $0) }
        let java = dictionary["Route.brouter.localJava"] as? String
        return (folder, java)
    }

    nonisolated static var fallbackFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/BaseCampClone/BRouter")
    }
}
