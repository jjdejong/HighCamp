import Foundation

public enum LibraryFileError: Error, Equatable {
    case unsupportedVersion(Int)
    /// A file of track points or route lines that the library file names is missing or damaged.
    case damagedLines(String)
}

/// Reads and writes the planning library as JSON, with a format version so later versions can migrate it.
///
/// Version 3 keeps the tracks' points and the routes' leg shapes apart, a file per item in a folder next to the
/// library file (`linesFolder(for:)`, see `LibraryLines`); the library file names each item's file. Version 2 kept
/// them inline, and version 1 kept routes as points only, read by turning each route's points into stops and legs
/// (`Route.init(name:points:)`).
public enum LibraryFile {
    public static let currentVersion = 3
    /// The oldest version this version can read.
    public static let oldestReadableVersion = 1

    private struct Stored: Codable {
        var version: Int
        var library: Library
        /// Item identifiers to the names of their line files, in `linesFolder(for:)`. Items without lines have none.
        var trackLines: [String: String]?
        var routeLines: [String: String]?
    }

    /// The lines last written, by item, so that a save writes only the lines that changed. Used by one writer at a
    /// time (`LibrarySaver` keeps one on its queue).
    struct LinesWritten {
        fileprivate var files: [UUID: (lines: LibraryLines, name: String)] = [:]
    }

    /// The folder of a library file's lines: "Library Lines" for `Library.json`.
    public static func linesFolder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " Lines")
    }

    public static func load(from url: URL) throws -> Library {
        try read(from: url).library
    }

    /// The library in a file, and the version the file was written in.
    public static func read(from url: URL) throws -> (library: Library, version: Int) {
        let stored = try decoder().decode(Stored.self, from: Data(contentsOf: url))
        guard (oldestReadableVersion...currentVersion).contains(stored.version) else {
            throw LibraryFileError.unsupportedVersion(stored.version)
        }
        var library = stored.library
        let folder = linesFolder(for: url)
        let trackLines = stored.trackLines ?? [:]
        for index in library.tracks.indices {
            guard let name = trackLines[library.tracks[index].id.uuidString] else { continue }
            guard case .track(let segments) = try lines(name, in: folder) else { throw LibraryFileError.damagedLines(name) }
            library.tracks[index].segments = segments
        }
        let routeLines = stored.routeLines ?? [:]
        for index in library.routes.indices {
            guard let name = routeLines[library.routes[index].id.uuidString] else { continue }
            guard case .route(let shapes) = try lines(name, in: folder),
                  shapes.count == library.routes[index].legs.count else { throw LibraryFileError.damagedLines(name) }
            library.routes[index].legShapes = shapes
        }
        return (library, stored.version)
    }

    private static func lines(_ name: String, in folder: URL) throws -> LibraryLines {
        do {
            return try LibraryLines(Data(contentsOf: folder.appendingPathComponent(name)))
        } catch {
            throw LibraryFileError.damagedLines(name)
        }
    }

    /// Writes the library: first the line files that are not there yet, then the library file, atomically (written
    /// and synced under a temporary name next to `url`, then renamed over it), then the line files it no longer
    /// names are removed. A failure removes the temporary file and leaves `url` as it was, with its lines.
    public static func save(_ library: Library, to url: URL) throws {
        var written = LinesWritten()
        try save(library, to: url, written: &written)
    }

    static func save(_ library: Library, to url: URL, written: inout LinesWritten) throws {
        let folder = linesFolder(for: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var stored = Stored(version: currentVersion, library: library, trackLines: [:], routeLines: [:])
        var kept: [UUID: (lines: LibraryLines, name: String)] = [:]
        func file(for id: UUID, _ lines: LibraryLines) throws -> String? {
            guard !lines.isEmpty else { return nil }
            if let previous = written.files[id], previous.lines == lines {
                kept[id] = previous
                return previous.name
            }
            let data = lines.encoded()
            let name = LibraryLines.fileName(for: id, data: data)
            let target = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try writeAtomically(data, to: target)
            }
            kept[id] = (lines, name)
            return name
        }
        for index in library.tracks.indices {
            let track = library.tracks[index]
            stored.trackLines?[track.id.uuidString] = try file(for: track.id, .track(track.segments))
            stored.library.tracks[index].segments = []
        }
        for index in library.routes.indices {
            let route = library.routes[index]
            stored.routeLines?[route.id.uuidString] = try file(for: route.id, .route(route.legShapes))
            stored.library.routes[index].legShapes = route.legs.map { _ in [] }
        }
        written.files = kept

        try writeAtomically(try encoder().encode(stored), to: url)

        let named = Set(kept.values.map(\.name))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !named.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Moves a library file and its lines, keeping them together: `Library.json` to `Old.json` takes "Library Lines"
    /// to "Old Lines".
    public static func move(_ url: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: url, to: destination)
        let lines = linesFolder(for: url)
        if FileManager.default.fileExists(atPath: lines.path) {
            try FileManager.default.moveItem(at: lines, to: linesFolder(for: destination))
        }
    }

    /// Copies a library file and its lines into `folder` (created if needed), under their own names. On APFS the
    /// copies are clones, which take no space until one side changes.
    public static func copy(_ url: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        let lines = linesFolder(for: url)
        if FileManager.default.fileExists(atPath: lines.path) {
            try FileManager.default.copyItem(at: lines, to: folder.appendingPathComponent(lines.lastPathComponent))
        }
    }

    /// The temporary name a save is written under, for `url`: `Library.json` gives `Library.json.saving`.
    static func savingURL(for url: URL) -> URL {
        url.appendingPathExtension("saving")
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = savingURL(for: url)
        do {
            try writeSynced(data, to: temporary)
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func writeSynced(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Compact JSON: no pretty printing, which costs time and space on a large library.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
