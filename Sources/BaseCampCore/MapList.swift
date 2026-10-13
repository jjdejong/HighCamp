import Foundation

/// One map of the map folder in the map list: whether it is drawn, between which zoom levels, and how opaque.
/// The list's order is the drawing order, bottom first, as in QMapShack's map list.
public struct MapListEntry: Codable, Equatable, Sendable, Identifiable {
    /// The map's file name in the map folder.
    public var fileName: String
    public var isEnabled: Bool
    /// An overlay, such as a contour map: drawn without a background, over the maps below it.
    public var isOverlay: Bool
    /// Web Mercator zoom levels, as on the map: 0 is the whole world, 21 is very close in.
    public var minimumZoom: Int
    public var maximumZoom: Int
    /// From 0 (invisible) to 1 (opaque).
    public var opacity: Double

    public var id: String { fileName }

    public init(fileName: String, isEnabled: Bool, isOverlay: Bool, minimumZoom: Int, maximumZoom: Int, opacity: Double = 1) {
        self.fileName = fileName
        self.isEnabled = isEnabled
        self.isOverlay = isOverlay
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.opacity = opacity
    }

    /// Whether the map is drawn at a zoom level.
    public func isVisible(atZoom zoom: Int) -> Bool {
        isEnabled && opacity > 0 && zoom >= minimumZoom && zoom <= maximumZoom
    }
}

public enum MapList {
    public static let closestZoom = 21
    /// Overlays start at this zoom by default: their coarse levels are roughly simplified, so they are best close in.
    public static let overlayMinimumZoom = 13

    /// The list for the maps now in the folder. Known maps keep their settings and order; maps no longer in the
    /// folder are dropped. New maps are added: a full map at the bottom, on only when no full map is on yet, so
    /// overlapping maps are not drawn twice; an overlay at the top, off, from `overlayMinimumZoom` in.
    public static func synced(_ entries: [MapListEntry], with files: [(fileName: String, isOverlay: Bool)]) -> [MapListEntry] {
        let present = Set(files.map(\.fileName))
        var result = entries.filter { present.contains($0.fileName) }
        let known = Set(result.map(\.fileName))
        for file in files where !known.contains(file.fileName) {
            if file.isOverlay {
                result.append(MapListEntry(
                    fileName: file.fileName, isEnabled: false, isOverlay: true,
                    minimumZoom: overlayMinimumZoom, maximumZoom: closestZoom
                ))
            } else {
                let anyFullMapOn = result.contains { !$0.isOverlay && $0.isEnabled }
                let entry = MapListEntry(
                    fileName: file.fileName, isEnabled: !anyFullMapOn, isOverlay: false,
                    minimumZoom: 0, maximumZoom: closestZoom
                )
                // Below the first overlay, so overlays stay on top.
                let firstOverlay = result.firstIndex(where: \.isOverlay) ?? result.endIndex
                result.insert(entry, at: firstOverlay)
            }
        }
        return result
    }
}
