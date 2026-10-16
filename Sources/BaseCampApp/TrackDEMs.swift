import BaseCampCore
import BaseCampDEM
import Foundation
import Observation

/// High-resolution elevation models made for single tracks and routes from a folder of DEM tiles, as the user's
/// QMapShack scripts made them by hand: the tiles along the line, gathered into a small DEM of its own. Kept next
/// to the library, in "Track DEMs", one folder per item, so the library file does not change. Its profile is
/// sampled every few metres along the line, so climbs between the line's points show too.
@MainActor
@Observable
final class TrackDEMStore {
    /// What is being done, for the profile pane to show; nil when idle.
    private(set) var status: String?
    /// Bumped when a track DEM is built or removed, so views look again.
    private(set) var revision = 0
    @ObservationIgnored private var profiles: [ProfileKey: [ElevationProfilePoint]] = [:]
    @ObservationIgnored private var index: (folder: URL, tiles: [DEMTileInfo])?

    private struct ProfileKey: Hashable {
        let item: LibraryItem
        let libraryRevision: Int
        let demRevision: Int
    }

    /// What is written beside a track DEM's rasters.
    struct Info: Codable {
        var name: String
        var built: Date
        var tiles: Int
        /// The finest pixel size, in metres.
        var resolution: Double
        var corridor: Double
    }

    nonisolated static let infoFile = "track DEM.json"

    func folder(for item: LibraryItem, store: LibraryStore) -> URL {
        store.dataFolder.appendingPathComponent("Track DEMs").appendingPathComponent(Self.id(of: item).uuidString)
    }

    /// The item's track DEM, if it has one.
    func info(for item: LibraryItem, store: LibraryStore) -> Info? {
        _ = revision
        let file = folder(for: item, store: store).appendingPathComponent(Self.infoFile)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(Info.self, from: data)
    }

    /// The folder to read heights from for `item`: its track DEM when it has one.
    func modelFolder(for item: LibraryItem?, store: LibraryStore) -> URL? {
        guard let item, info(for: item, store: store) != nil else { return nil }
        return folder(for: item, store: store)
    }

    /// Gathers the tiles along the item from `tileFolder` into its track DEM, replacing an earlier one.
    func build(_ item: LibraryItem, store: LibraryStore, tileFolder: URL, corridor: Double) async {
        guard status == nil, let lines = Self.lines(of: item, store: store) else { return }
        let name = Self.name(of: item, store: store)
        let destination = folder(for: item, store: store)
        let indexFile = store.dataFolder.appendingPathComponent("DEM tile index.json")
        status = "Reading the tiles in \(tileFolder.lastPathComponent)…"
        defer { status = nil }

        let previous = index?.folder == tileFolder ? index!.tiles : Self.readIndex(indexFile, folder: tileFolder)
        let tiles = await Task.detached(priority: .userInitiated) { [weak self] in
            DEMTileIndex.scan(folder: tileFolder, previous: previous) { count in
                Task { @MainActor in
                    self?.status = "Reading the tiles in \(tileFolder.lastPathComponent): \(count)…"
                }
            }
        }.value
        index = (tileFolder, tiles)
        Self.writeIndex(tiles, folder: tileFolder, to: indexFile)

        status = "Building the track DEM…"
        do {
            let info = try await Task.detached(priority: .userInitiated) {
                let chosen = TrackDEM.tiles(along: lines, corridor: corridor, from: tiles)
                try TrackDEMBuilder.build(tiles: chosen, into: destination)
                let info = Info(name: name, built: Date(), tiles: chosen.count, resolution: chosen.map(\.resolution).min() ?? 0, corridor: corridor)
                try Self.encoder.encode(info).write(to: destination.appendingPathComponent(Self.infoFile))
                return info
            }.value
            _ = info
            revision += 1
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    func remove(_ item: LibraryItem, store: LibraryStore) {
        try? FileManager.default.removeItem(at: folder(for: item, store: store))
        revision += 1
    }

    /// Heights every few metres along the item from its track DEM, at the same distances as its profile. Nil
    /// when it has no track DEM.
    func profile(for item: LibraryItem, store: LibraryStore) async -> [ElevationProfilePoint]? {
        guard let info = info(for: item, store: store), let lines = Self.lines(of: item, store: store) else { return nil }
        let key = ProfileKey(item: item, libraryRevision: store.revision, demRevision: revision)
        if let cached = profiles[key] {
            return cached
        }
        let folder = folder(for: item, store: store)
        let step = max(2, info.resolution)
        let points = await Task.detached(priority: .userInitiated) { () -> [ElevationProfilePoint] in
            guard let model = try? ElevationModel(folder: folder) else { return [] }
            let measure = LineMeasure(segments: lines)
            var points: [ElevationProfilePoint] = []
            for distance in TrackDEM.sampleDistances(length: measure.length, step: step) {
                guard let place = measure.coordinate(at: distance), let height = model.elevation(at: place) else { continue }
                points.append(ElevationProfilePoint(id: points.count, distanceMeters: distance, value: height, coordinate: place))
            }
            return points
        }.value
        profiles = [key: points]
        return points
    }

    // MARK: Helpers

    private static func id(of item: LibraryItem) -> UUID {
        switch item {
        case .track(let id), .route(let id), .waypoint(let id): id
        }
    }

    private static func lines(of item: LibraryItem, store: LibraryStore) -> [[Coordinate]]? {
        switch item {
        case .track(let id): store.track(id).map { $0.segments.map { $0.map(\.coordinate) } }
        case .route(let id): store.route(id).map { [$0.points.map(\.coordinate)] }
        case .waypoint: nil
        }
    }

    private static func name(of item: LibraryItem, store: LibraryStore) -> String {
        switch item {
        case .track(let id): store.track(id)?.name ?? ""
        case .route(let id): store.route(id)?.name ?? ""
        case .waypoint: ""
        }
    }

    private struct StoredIndex: Codable {
        var folder: String
        var tiles: [DEMTileInfo]
    }

    nonisolated private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Dates as plain numbers, to the sub-second, so unchanged files compare equal after a reload.
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()

    private static func readIndex(_ file: URL, folder: URL) -> [DEMTileInfo] {
        guard let data = try? Data(contentsOf: file), let stored = try? decoder.decode(StoredIndex.self, from: data),
              stored.folder == folder.path else { return [] }
        return stored.tiles
    }

    private static func writeIndex(_ tiles: [DEMTileInfo], folder: URL, to file: URL) {
        try? encoder.encode(StoredIndex(folder: folder.path, tiles: tiles)).write(to: file)
    }
}

/// What a view's track DEM profile depends on: the item, and changes to the library and to the track DEMs.
struct TrackDEMRequest: Equatable {
    let item: LibraryItem?
    let library: Int
    let dem: Int
}
