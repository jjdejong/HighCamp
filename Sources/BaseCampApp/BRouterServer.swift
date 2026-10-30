import BaseCampCore
import Foundation
import Observation

/// Starts and stops HighCamp's own BRouter server, from the BRouter folder (see `BRouterInstall`).
///
/// The server stops with HighCamp however HighCamp ends, even when it is killed or crashes: Java runs under a small
/// shell that ends it once HighCamp's process is gone. A BRouter already answering at the local address, such as
/// one left running by an earlier HighCamp, is used instead of starting another, which could not take the port.
@MainActor
@Observable
final class BRouterServer {
    private(set) var process: Process?
    /// A BRouter HighCamp did not start answers at the local address, and is used.
    private(set) var isUsingOther = false
    var lastError: String?
    private var startTask: Task<Void, Never>?

    var isRunning: Bool {
        isUsingOther || (process?.isRunning ?? false)
    }

    func start(_ settings: RoutingSettings) {
        let old = process
        stop()
        lastError = nil
        startTask = Task {
            // The old server must be gone before the port is looked at, or it would be taken for another one.
            if let old {
                await Self.waitForExit(old)
            }
            guard !Task.isCancelled else { return }
            if let server = URL(string: settings.localServer),
               await BRouterClient(baseURL: server, profile: "trekking").isReachable() {
                guard !Task.isCancelled else { return }
                isUsingOther = true
                return
            }
            guard !Task.isCancelled else { return }
            launch(settings)
        }
    }

    private static func waitForExit(_ process: Process) async {
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func launch(_ settings: RoutingSettings) {
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
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["HIGHCAMP_PID": String(ProcessInfo.processInfo.processIdentifier)]
        ) { $1 }
        process.arguments = [
            "-c", Self.watchdog, "brouter",
            settings.javaPath,
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

    /// Stops HighCamp's own server. One HighCamp did not start is left running.
    func stop() {
        startTask?.cancel()
        startTask = nil
        process?.terminate()
        process = nil
        isUsingOther = false
    }

    /// Runs the command given after it, and ends it when HighCamp's process (`HIGHCAMP_PID`) is gone or the shell is
    /// told to stop. Checked every two seconds.
    static let watchdog = """
        "$@" &
        child=$!
        trap 'kill $child 2>/dev/null; exit 0' TERM INT HUP
        while kill -0 "$HIGHCAMP_PID" 2>/dev/null && kill -0 $child 2>/dev/null; do
            sleep 2
        done
        kill $child 2>/dev/null
        wait $child
        """

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
