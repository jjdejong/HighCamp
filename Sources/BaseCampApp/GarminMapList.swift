import BaseCampCore
import BaseCampIMG
import Foundation
import Observation

/// The maps the Garmin base map draws, in order, as QMapShack's map list: which are on, between which zoom levels,
/// and how opaque. Kept between launches, and kept in step with the map folder.
@MainActor
@Observable
final class GarminMapListStore {
    private static let defaultsKey = "map.list"

    private(set) var entries: [MapListEntry]
    private(set) var folder: URL?
    /// Why the folder could not be read, for the list to show. Nil when it was read.
    private(set) var problem: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([MapListEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    /// Reads the folder's maps, finds which are overlays, and updates the list. Opening the maps happens off the
    /// main thread.
    func reload(folder: URL) async {
        let result = await Task.detached { () -> Result<[(fileName: String, isOverlay: Bool)], Error> in
            Result {
                try MapFolder.imgMaps(in: folder).compactMap { file in
                    guard let map = try? GarminIMG(url: file.url) else { return nil }
                    return (file.url.lastPathComponent, map.isTransparent)
                }
            }
        }.value
        self.folder = folder
        switch result {
        case .success(let files):
            problem = nil
            update(MapList.synced(entries, with: files))
        case .failure(let error):
            // Keep the list as it was: the maps are still there, the app just cannot see them now.
            problem = Self.explain(error, folder: folder)
        }
    }

    private static func explain(_ error: Error, folder: URL) -> String {
        let code = (error as NSError).code
        if code == NSFileReadNoPermissionError || code == EPERM || code == EACCES {
            return "macOS does not let BaseCamp Clone read \(folder.path). Allow it in System Settings > Privacy & Security > Files and Folders, then reopen this list."
        }
        if code == NSFileReadNoSuchFileError {
            return "The map folder \(folder.path) does not exist. Choose another one in Settings."
        }
        return "The map folder \(folder.path) could not be read. \(error.localizedDescription)"
    }

    func setEnabled(_ enabled: Bool, for fileName: String) {
        change(fileName) { $0.isEnabled = enabled }
    }

    func setZoomRange(minimum: Int, maximum: Int, for fileName: String) {
        change(fileName) {
            $0.minimumZoom = min(minimum, maximum)
            $0.maximumZoom = max(minimum, maximum)
        }
    }

    func setOpacity(_ opacity: Double, for fileName: String) {
        change(fileName) { $0.opacity = min(1, max(0, opacity)) }
    }

    /// A map's name for menus: the file name without `.img`, marked when it is an overlay.
    static func title(_ entry: MapListEntry) -> String {
        let name = (entry.fileName as NSString).deletingPathExtension
        return entry.isOverlay ? "\(name) (overlay)" : name
    }

    /// The names of the maps that are on, top first, for the label on the map.
    var enabledTitles: [String] {
        topFirst.filter(\.isEnabled).map { ($0.fileName as NSString).deletingPathExtension }
    }

    /// The list as shown, top first: the top map is drawn on top, as in QMapShack.
    var topFirst: [MapListEntry] {
        entries.reversed()
    }

    /// Moves maps in the top-first list.
    func moveTopFirst(fromOffsets source: IndexSet, toOffset destination: Int) {
        var shown = topFirst
        shown.move(fromOffsets: source, toOffset: destination)
        update(shown.reversed())
    }

    /// What the renderer needs: the maps that are on, bottom first, with their files.
    func configuration(detail: GarminDetail, softColors: Bool, relief: Double = 0, hiddenPointTypes: Set<Int> = []) -> GarminMapConfiguration {
        guard let folder else {
            return GarminMapConfiguration(
                layers: [], detailOffset: detail.offset, softColors: softColors, relief: relief, hiddenPointTypes: hiddenPointTypes
            )
        }
        return GarminMapConfiguration(
            layers: entries.filter(\.isEnabled).map { entry in
                GarminMapLayer(
                    url: folder.appendingPathComponent(entry.fileName), isOverlay: entry.isOverlay,
                    minimumZoom: entry.minimumZoom, maximumZoom: entry.maximumZoom, opacity: entry.opacity
                )
            },
            detailOffset: detail.offset,
            softColors: softColors,
            relief: relief,
            hiddenPointTypes: hiddenPointTypes
        )
    }

    private func change(_ fileName: String, _ edit: (inout MapListEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.fileName == fileName }) else { return }
        var changed = entries
        edit(&changed[index])
        update(changed)
    }

    private func update(_ new: [MapListEntry]) {
        guard new != entries else { return }
        entries = new
        if let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// One map the renderer draws.
struct GarminMapLayer: Equatable, Sendable {
    let url: URL
    let isOverlay: Bool
    let minimumZoom: Int
    let maximumZoom: Int
    let opacity: Double

    func isVisible(atZoom zoom: Int) -> Bool {
        opacity > 0 && zoom >= minimumZoom && zoom <= maximumZoom
    }
}

/// Everything the Garmin base map is drawn from: the maps that are on, bottom first, and the detail setting.
struct GarminMapConfiguration: Equatable, Sendable {
    var layers: [GarminMapLayer]
    var detailOffset: Int
    /// Paler colours and plain areas instead of patterns, for a calmer map. Off draws the map's own style.
    var softColors = false
    /// The strength of the relief shading drawn from the maps' own heights, 0 for none.
    var relief = 0.0
    /// Point types the user chose not to see: neither their icons nor their names are drawn.
    var hiddenPointTypes: Set<Int> = []
}
