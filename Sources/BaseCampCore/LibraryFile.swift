import Foundation

public enum LibraryFileError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Reads and writes the planning library as JSON, with a format version so later versions can migrate it.
public enum LibraryFile {
    public static let currentVersion = 1

    private struct Stored: Codable {
        var version: Int
        var library: Library
    }

    public static func load(from url: URL) throws -> Library {
        let stored = try decoder().decode(Stored.self, from: Data(contentsOf: url))
        guard stored.version == currentVersion else {
            throw LibraryFileError.unsupportedVersion(stored.version)
        }
        return stored.library
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
