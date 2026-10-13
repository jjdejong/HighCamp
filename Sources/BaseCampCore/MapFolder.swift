import Foundation

/// A Garmin IMG map on disk. QMapShack reads the same files from its map folder.
public struct MapFile: Identifiable, Equatable, Sendable {
    public let url: URL
    public let size: Int64
    public let modified: Date?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, size: Int64, modified: Date?) {
        self.url = url
        self.size = size
        self.modified = modified
    }
}

public enum MapFolder {
    /// The `.img` maps directly inside `folder`, sorted by name. Hidden files and subfolders are skipped.
    public static func imgMaps(in folder: URL) throws -> [MapFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let items = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return try items.compactMap { url -> MapFile? in
            guard url.pathExtension.lowercased() == "img" else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return MapFile(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
