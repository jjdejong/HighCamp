import Foundation
import Observation

/// Where routes come from: HighCamp's own BRouter server on this Mac, or the public one at brouter.de.
@MainActor
@Observable
final class RoutingSettings {
    enum Engine: String, CaseIterable, Identifiable {
        case local
        case online

        var id: String { rawValue }

        var label: String {
            switch self {
            case .local: "BRouter on this Mac"
            case .online: "brouter.de (online)"
            }
        }
    }

    /// HighCamp's own server. QMapShack's uses 17777; both can run.
    static let defaultLocalServer = "http://127.0.0.1:17778"
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
    /// The folder with the BRouter jar, `segments4`, `profiles2` and `customprofiles`: HighCamp's own by default.
    var brouterFolder: URL {
        didSet { defaults.set(brouterFolder.path, forKey: "routing.brouterFolder") }
    }
    var javaPath: String {
        didSet { defaults.set(javaPath, forKey: "routing.javaPath") }
    }

    init() {
        engine = Engine(rawValue: defaults.string(forKey: "routing.engine") ?? "") ?? .local
        localServer = defaults.string(forKey: "routing.localServer") ?? Self.defaultLocalServer
        onlineServer = defaults.string(forKey: "routing.onlineServer") ?? Self.defaultOnlineServer
        brouterFolder = defaults.string(forKey: "routing.brouterFolder").map { URL(fileURLWithPath: $0) } ?? BRouterInstall.defaultFolder
        javaPath = defaults.string(forKey: "routing.javaPath") ?? Self.installedJava ?? "/usr/bin/java"
    }

    /// The Java that macOS reports as installed (`java_home`), if any. `/usr/bin/java` is only a stub that asks to
    /// install one when there is none.
    nonisolated static let installedJava: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let home = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty else { return nil }
        let java = home + "/bin/java"
        return FileManager.default.isExecutableFile(atPath: java) ? java : nil
    }()

    /// Whether Java can be started from `javaPath`.
    var hasJava: Bool {
        FileManager.default.isExecutableFile(atPath: javaPath) && (javaPath != "/usr/bin/java" || Self.installedJava != nil)
    }

    /// The server requests go to, for the engine chosen.
    var activeServer: URL? {
        URL(string: engine == .local ? localServer : onlineServer)
    }

}
