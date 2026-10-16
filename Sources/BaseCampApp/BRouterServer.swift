import Foundation
import Observation

/// Starts and stops HighCamp's own BRouter server, from the BRouter folder (see `BRouterInstall`).
@MainActor
@Observable
final class BRouterServer {
    private(set) var process: Process?
    var lastError: String?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func start(_ settings: RoutingSettings) {
        stop()
        lastError = nil

        guard let server = URL(string: settings.localServer), let port = server.port else {
            lastError = "The local BRouter address is not valid: \(settings.localServer)"
            return
        }
        let folder = settings.brouterFolder
        let fileManager = FileManager.default
        guard let jar = BRouterInstall.jar(in: folder) else {
            lastError = "BRouter is not installed. Install it in Settings › Routing."
            return
        }
        guard settings.hasJava else {
            lastError = "BRouter needs Java, which is not installed. Install a Java runtime (such as Temurin from adoptium.net), or plan with brouter.de."
            return
        }
        for name in ["segments4", "customprofiles"] {
            try? fileManager.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let logURL = Self.logURL
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.javaPath)
        process.currentDirectoryURL = folder
        process.arguments = [
            "-Xmx256M", "-Xms128M",
            "-cp", folder.appendingPathComponent(jar).path,
            "btools.server.RouteServer",
            folder.appendingPathComponent("segments4").path,
            folder.appendingPathComponent("profiles2").path,
            // BRouter takes this folder relative to the profiles folder; it keeps the profiles HighCamp uploads.
            "../customprofiles",
            String(port), "2", "127.0.0.1",
        ]
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
            self.process = process
        } catch {
            lastError = "Could not start Java at \(settings.javaPath). \(error.localizedDescription)"
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    static var logURL: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("BaseCampClone/brouter.log")
    }
}
