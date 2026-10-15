import BaseCampCore
import CGDAL
import Foundation

/// The DEM tiles of a folder and its subfolders, read through GDAL: where each is and how fine.
public enum DEMTileIndex {
    /// File kinds read as tiles. Mosaics (`.vrt`) are left out: they point at tiles that are indexed themselves.
    static let extensions: Set<String> = ["asc", "tif", "tiff"]

    /// The tiles in `folder`, reusing the entries of `previous` whose file has not changed. `progress` is called
    /// now and then with the number of files looked at.
    public static func scan(folder: URL, previous: [DEMTileInfo], progress: (Int) -> Void = { _ in }) -> [DEMTileInfo] {
        _ = GDALSetup.started
        let known = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [DEMTileInfo] = []
        var seen = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true {
                // Python environments and the like hold no tiles.
                if url.lastPathComponent.hasSuffix("-env") || url.lastPathComponent == "site-packages" {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            seen += 1
            if seen % 200 == 0 {
                progress(seen)
            }
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate
            if let old = known[url.path], old.size == size, old.modified == modified {
                result.append(old)
            } else if let tile = read(url, size: size, modified: modified) {
                result.append(tile)
            }
        }
        progress(seen)
        return result
    }

    /// One tile's area and resolution, or nil when GDAL cannot read it or its projection is unknown.
    static func read(_ url: URL, size: Int64, modified: Date?) -> DEMTileInfo? {
        guard let dataset = GDALOpen(url.path, GA_ReadOnly) else { return nil }
        defer { GDALClose(dataset) }
        var gt = [Double](repeating: 0, count: 6)
        guard GDALGetGeoTransform(dataset, &gt) == CE_None, gt[1] != 0, gt[5] != 0 else { return nil }
        let width = Double(GDALGetRasterXSize(dataset)), height = Double(GDALGetRasterYSize(dataset))
        let corners = [(0.0, 0.0), (width, 0), (0, height), (width, height)].map { (gt[0] + $0.0 * gt[1] + $0.1 * gt[2], gt[3] + $0.0 * gt[4] + $0.1 * gt[5]) }
        guard let projection = projection(of: dataset, url: url, corner: corners[0]),
              let source = spatialReference(projection),
              let wgs84 = spatialReference("EPSG:4326") else { return nil }
        defer {
            OSRDestroySpatialReference(source)
            OSRDestroySpatialReference(wgs84)
        }
        OSRSetAxisMappingStrategy(source, OAMS_TRADITIONAL_GIS_ORDER)
        OSRSetAxisMappingStrategy(wgs84, OAMS_TRADITIONAL_GIS_ORDER)
        guard let transform = OCTNewCoordinateTransformation(source, wgs84) else { return nil }
        defer { OCTDestroyCoordinateTransformation(transform) }
        var longitudes: [Double] = [], latitudes: [Double] = []
        for corner in corners {
            var x = corner.0, y = corner.1, z = 0.0
            guard OCTTransform(transform, 1, &x, &y, &z) != 0 else { return nil }
            longitudes.append(x)
            latitudes.append(y)
        }
        let metres = OSRIsProjected(source) != 0 ? abs(gt[1]) : abs(gt[1]) * 111_320
        return DEMTileInfo(
            path: url.path, size: size, modified: modified,
            north: latitudes.max()!, south: latitudes.min()!, east: longitudes.max()!, west: longitudes.min()!,
            resolution: metres, projection: projection
        )
    }

    /// The tile's projection as text GDAL understands. IGN's RGE ALTI tiles (`.asc`) carry none: they are in
    /// Lambert-93, which their names say ("LAMB93") and their coordinates show.
    static func projection(of dataset: GDALDatasetH, url: URL, corner: (Double, Double)) -> String? {
        if let reference = GDALGetProjectionRef(dataset), reference.pointee != 0 {
            return String(cString: reference)
        }
        let name = url.lastPathComponent.uppercased()
        let lambertRange = (0...1_300_000).contains(corner.0) && (6_000_000...7_200_000).contains(corner.1)
        if name.contains("LAMB93") || name.contains("L93") || lambertRange {
            return lambert93
        }
        return nil
    }

    /// Lambert-93, the projection of IGN's French data.
    public static let lambert93 = "EPSG:2154"

    static func spatialReference(_ text: String) -> OGRSpatialReferenceH? {
        guard let reference = OSRNewSpatialReference(nil) else { return nil }
        guard OSRSetFromUserInput(reference, text) == OGRERR_NONE else {
            OSRDestroySpatialReference(reference)
            return nil
        }
        return reference
    }
}

/// A small DEM for one track: virtual rasters (VRT) over just the tiles along it, finest first, in a folder of
/// its own. The tiles are not copied, only referenced, as hard links would. `ElevationModel(folder:)` reads it, and
/// so can QMapShack.
public enum TrackDEMBuilder {
    public enum Failure: Error, LocalizedError {
        case noTiles
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .noTiles: "No elevation tile in the tile folder comes near this line."
            case .cannotWrite(let file): "The track DEM \(file) could not be written."
            }
        }
    }

    /// Writes the track DEM for `tiles` into `folder`, replacing what was there: one VRT per projection and
    /// resolution, named so the finest comes first ("1 - 1 m.vrt", "2 - 5 m.vrt"). Returns the files written.
    @discardableResult
    public static func build(tiles: [DEMTileInfo], into folder: URL) throws -> [URL] {
        guard !tiles.isEmpty else { throw Failure.noTiles }
        _ = GDALSetup.started
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        struct Group: Hashable {
            let projection: String
            let resolution: Double
        }
        let groups = Dictionary(grouping: tiles) { Group(projection: $0.projection, resolution: ($0.resolution * 100).rounded() / 100) }
        var written: [URL] = []
        for (index, group) in groups.keys.sorted(by: { $0.resolution < $1.resolution }).enumerated() {
            let paths = groups[group]!.map(\.path)
            let resolution = group.resolution < 10 ? String(format: "%g", group.resolution) : String(format: "%.0f", group.resolution)
            let file = folder.appendingPathComponent("\(index + 1) - \(resolution) m.vrt")
            var arguments = ["-resolution", "highest"]
            if group.projection == DEMTileIndex.lambert93 {
                // The tiles carry no projection; the VRT says what it is.
                arguments += ["-a_srs", DEMTileIndex.lambert93]
            }
            try buildVRT(file, sources: paths, arguments: arguments)
            written.append(file)
        }
        return written
    }

    private static func buildVRT(_ file: URL, sources: [String], arguments: [String]) throws {
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        guard let options = GDALBuildVRTOptionsNew(&argv, nil) else { throw Failure.cannotWrite(file.lastPathComponent) }
        defer { GDALBuildVRTOptionsFree(options) }
        var names = sources.map { strdup($0) } + [nil]
        defer { names.forEach { free($0) } }
        var usageError: Int32 = 0
        let names2 = names.map { $0.map { UnsafePointer($0) } }
        let dataset = names2.withUnsafeBufferPointer { buffer in
            GDALBuildVRT(file.path, Int32(sources.count), nil, UnsafeMutablePointer(mutating: buffer.baseAddress), options, &usageError)
        }
        guard let dataset else { throw Failure.cannotWrite(file.lastPathComponent) }
        GDALClose(dataset)
    }
}
