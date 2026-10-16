import BaseCampCore
import Foundation
import Observation

/// HighCamp's own BRouter: the jar and profiles of a BRouter release, and the map data tiles the user's routes need,
/// in a folder of its own beside the library ("BRouter"), so nothing else need be installed but Java. The release
/// comes from BRouter's GitHub page and the tiles from brouter.de, only when the user asks.
@MainActor
@Observable
final class BRouterInstall {
    /// The BRouter release installed. Its map data format is the one brouter.de serves.
    nonisolated static let version = "1.7.9"
    nonisolated static let releaseURL = URL(string: "https://github.com/abrensch/brouter/releases/download/v\(version)/brouter-\(version).zip")!
    nonisolated static let segmentsURL = URL(string: "https://brouter.de/brouter/segments4/")!

    /// What is being downloaded, and how far it has got (0...1); nil when idle.
    private(set) var activity: (text: String, fraction: Double?)?
    /// The last download that failed, and why.
    private(set) var problem: String?
    /// Bumped when files change, so views look again.
    private(set) var revision = 0

    /// The folder HighCamp keeps BRouter in, beside the library. Settings may point elsewhere (an existing install).
    nonisolated static var defaultFolder: URL {
        LibraryStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("BRouter")
    }

    /// The jar and profiles are there.
    func isInstalled(in folder: URL) -> Bool {
        _ = revision
        return Self.jar(in: folder) != nil
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("profiles2/lookups.dat").path)
    }

    nonisolated static func jar(in folder: URL) -> String? {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .first { $0.hasPrefix("brouter") && $0.hasSuffix("-all.jar") }
    }

    /// The map data tiles in the folder, by name, with their size in bytes.
    func tiles(in folder: URL) -> [(name: String, bytes: Int64)] {
        _ = revision
        let segments = folder.appendingPathComponent("segments4")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: segments.path)) ?? []
        return names.filter { $0.hasSuffix(".rd5") }.sorted().map { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: segments.appendingPathComponent(name).path)[.size] as? Int64) ?? 0
            return (String(name.dropLast(4)), size)
        }
    }

    /// The tiles that routes through each list of places need and the folder lacks.
    func missingTiles(for lines: [[Coordinate]], in folder: URL) -> [String] {
        let present = Set(tiles(in: folder).map(\.name))
        return Set(lines.flatMap(BRouterSegments.names(covering:))).subtracting(present).sorted()
    }

    /// Downloads the BRouter release and puts its jar and profiles in the folder, with empty `segments4` and
    /// `customprofiles` folders. Files of an earlier install are replaced; map data is kept.
    func install(into folder: URL) async {
        guard activity == nil else { return }
        problem = nil
        activity = ("Downloading BRouter \(Self.version)…", nil)
        defer {
            activity = nil
            revision += 1
        }
        do {
            let zip = try await download(Self.releaseURL, text: "Downloading BRouter \(Self.version)")
            defer { try? FileManager.default.removeItem(at: zip) }
            activity = ("Installing BRouter \(Self.version)…", nil)
            try await Task.detached {
                try Self.unpack(zip, into: folder)
            }.value
        } catch {
            problem = "BRouter could not be installed. \(error.localizedDescription)"
        }
    }

    /// Downloads map data tiles from brouter.de into the folder's `segments4`, one after the other.
    func downloadTiles(_ names: [String], into folder: URL) async {
        guard activity == nil, !names.isEmpty else { return }
        problem = nil
        defer {
            activity = nil
            revision += 1
        }
        let segments = folder.appendingPathComponent("segments4")
        for (index, name) in names.enumerated() {
            let label = names.count > 1 ? "Downloading map data \(name) (\(index + 1) of \(names.count))" : "Downloading map data \(name)"
            activity = ("\(label)…", nil)
            do {
                let file = try await download(Self.segmentsURL.appendingPathComponent("\(name).rd5"), text: label)
                try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
                let destination = segments.appendingPathComponent("\(name).rd5")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
            } catch {
                problem = "Map data \(name) could not be downloaded. \(error.localizedDescription)"
                return
            }
        }
    }

    func deleteTile(_ name: String, in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("segments4/\(name).rd5"))
        revision += 1
    }

    // MARK: Helpers

    /// Downloads to a temporary file, showing progress.
    private func download(_ url: URL, text: String) async throws -> URL {
        let delegate = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                self?.activity = ("\(text)… \(Int(fraction * 100))%", fraction)
            }
        }
        let (file, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The server answered \(http.statusCode)."])
        }
        // The system removes its temporary file when this returns; keep a copy.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    /// Takes the jar and `profiles2` out of a release zip.
    nonisolated private static func unpack(_ zip: URL, into folder: URL) throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("brouter-" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: scratch) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, scratch.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        // The zip holds one folder, "brouter-<version>".
        guard let release = try fileManager.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first(where: { $0.hasDirectoryPath }),
              let jar = jar(in: release) else { throw CocoaError(.fileReadCorruptFile) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix("brouter") && old.hasSuffix("-all.jar") {
            try? fileManager.removeItem(at: folder.appendingPathComponent(old))
        }
        try fileManager.copyItem(at: release.appendingPathComponent(jar), to: folder.appendingPathComponent(jar))
        let profiles = folder.appendingPathComponent("profiles2")
        try? fileManager.removeItem(at: profiles)
        try fileManager.copyItem(at: release.appendingPathComponent("profiles2"), to: profiles)
        for name in ["segments4", "customprofiles"] {
            try fileManager.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }
}

/// Reports a download's progress.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}
