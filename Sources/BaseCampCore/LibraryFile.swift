import Foundation

public enum LibraryFileError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Reads and writes the planning library as JSON, with a format version so later versions can migrate it.
///
/// Version 2 keeps routes as stops and legs (`Route`); version 1 kept them as points only, and is read by
/// turning each route's points into stops and legs (`Route.init(name:points:)`).
public enum LibraryFile {
    public static let currentVersion = 2
    /// The oldest version this version can read.
    public static let oldestReadableVersion = 1

    private struct Stored: Codable {
        var version: Int
        var library: Library
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
        return (stored.library, stored.version)
    }

    /// Writes the library atomically: the new file is written and synced under a temporary name next to `url`, then
    /// renamed over it. A failure removes the temporary file and leaves `url` as it was.
    public static func save(_ library: Library, to url: URL) throws {
        let data = try encoder().encode(Stored(version: currentVersion, library: library))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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

    /// The temporary name a save is written under, for `url`: `Library.json` gives `Library.json.saving`.
    static func savingURL(for url: URL) -> URL {
        url.appendingPathExtension("saving")
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
