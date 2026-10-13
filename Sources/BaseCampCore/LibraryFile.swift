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

    public static func save(_ library: Library, to url: URL) throws {
        let data = try encoder().encode(Stored(version: currentVersion, library: library))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
