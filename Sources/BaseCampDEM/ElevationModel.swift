import BaseCampCore
import CGDAL
import Foundation

public enum ElevationModelError: Error, LocalizedError {
    case noRasters(String)
    case cannotOpen(String)

    public var errorDescription: String? {
        switch self {
        case .noRasters(let folder): "No elevation model (DEM) files were found in \(folder)."
        case .cannotOpen(let file): "The elevation model \(file) could not be opened."
        }
    }
}

/// Heights from elevation models (DEM) in a folder, read through GDAL. Each raster can be in any
/// projection; points are transformed to the raster's own coordinates. The first raster that covers a
/// point, and has a height there, gives the value. Put the best-resolution files first, such as `Current_DEM.vrt`.
///
/// GDAL handles are not thread-safe, so use one model per thread.
public final class ElevationModel: @unchecked Sendable {
    private struct Raster {
        let name: String
        let dataset: UnsafeMutableRawPointer
        let geotransform: [Double]
        let width: Int
        let height: Int
        let noData: Double?
        let toRaster: UnsafeMutableRawPointer
    }

    private var rasters: [Raster] = []

    /// Opens the rasters in `folder` (not its subfolders), in name order with `Current_DEM` first.
    public init(folder: URL) throws {
        GDALAllRegister()
        let extensions: Set<String> = ["vrt", "tif", "tiff", "asc"]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let leftPriority = lhs.lastPathComponent.hasPrefix("Current_DEM") ? 0 : 1
                let rightPriority = rhs.lastPathComponent.hasPrefix("Current_DEM") ? 0 : 1
                return leftPriority != rightPriority ? leftPriority < rightPriority : lhs.lastPathComponent < rhs.lastPathComponent
            }
        guard !files.isEmpty else { throw ElevationModelError.noRasters(folder.path) }

        let wgs84 = try Self.spatialReference(epsg: 4326)
        for file in files {
            guard let dataset = GDALOpen(file.path, GA_ReadOnly) else {
                continue
            }
            guard let wkt = GDALGetProjectionRef(dataset) else {
                GDALClose(dataset)
                continue
            }
            var geotransform = [Double](repeating: 0, count: 6)
            guard GDALGetGeoTransform(dataset, &geotransform) == CE_None else {
                GDALClose(dataset)
                continue
            }
            guard let source = OSRNewSpatialReference(wkt) else {
                GDALClose(dataset)
                continue
            }
            OSRSetAxisMappingStrategy(source, OAMS_TRADITIONAL_GIS_ORDER)
            guard let transform = OCTNewCoordinateTransformation(wgs84, source) else {
                OSRDestroySpatialReference(source)
                GDALClose(dataset)
                continue
            }
            let band = GDALGetRasterBand(dataset, 1)
            var hasNoData: Int32 = 0
            let noData = GDALGetRasterNoDataValue(band, &hasNoData)
            rasters.append(Raster(
                name: file.lastPathComponent,
                dataset: dataset,
                geotransform: geotransform,
                width: Int(GDALGetRasterXSize(dataset)),
                height: Int(GDALGetRasterYSize(dataset)),
                noData: hasNoData != 0 ? noData : nil,
                toRaster: transform
            ))
            OSRDestroySpatialReference(source)
        }
        OSRDestroySpatialReference(wgs84)
        guard !rasters.isEmpty else { throw ElevationModelError.cannotOpen(folder.path) }
    }

    deinit {
        for raster in rasters {
            OCTDestroyCoordinateTransformation(raster.toRaster)
            GDALClose(raster.dataset)
        }
    }

    /// The number of rasters that opened.
    public var rasterCount: Int { rasters.count }

    /// The height in metres at a coordinate, or nil when no raster covers it with a value.
    public func elevation(at coordinate: Coordinate) -> Double? {
        for raster in rasters {
            var x = coordinate.longitude
            var y = coordinate.latitude
            var z = 0.0
            guard OCTTransform(raster.toRaster, 1, &x, &y, &z) != 0 else { continue }
            let gt = raster.geotransform
            guard gt[1] != 0, gt[5] != 0 else { continue }
            // Pixel centres sit half a pixel inside the upper-left corner.
            let column = (x - gt[0]) / gt[1] - 0.5
            let row = (y - gt[3]) / gt[5] - 0.5
            guard column >= 0, row >= 0, column <= Double(raster.width - 1), row <= Double(raster.height - 1) else { continue }
            if let value = Self.bilinear(raster, column: column, row: row) {
                return value
            }
        }
        return nil
    }

    /// Heights for every coordinate, nil where no raster covers the point.
    public func elevations(for coordinates: [Coordinate]) -> [Double?] {
        coordinates.map { elevation(at: $0) }
    }

    private static func bilinear(_ raster: Raster, column: Double, row: Double) -> Double? {
        let c0 = min(Int(column.rounded(.down)), raster.width - 1)
        let r0 = min(Int(row.rounded(.down)), raster.height - 1)
        let c1 = min(c0 + 1, raster.width - 1)
        let r1 = min(r0 + 1, raster.height - 1)
        let fx = column - Double(c0)
        let fy = row - Double(r0)
        let band = GDALGetRasterBand(raster.dataset, 1)

        func read(_ c: Int, _ r: Int) -> Double? {
            var value = 0.0
            guard GDALRasterIO(band, GF_Read, Int32(c), Int32(r), 1, 1, &value, 1, 1, GDT_Float64, 0, 0) == CE_None else {
                return nil
            }
            if let noData = raster.noData, value == noData { return nil }
            if value.isNaN { return nil }
            return value
        }

        guard let v00 = read(c0, r0) else { return nil }
        // Near an edge or a no-data cell, the nearest good value is used rather than mixing in a missing one.
        let v10 = read(c1, r0) ?? v00
        let v01 = read(c0, r1) ?? v00
        let v11 = read(c1, r1) ?? v00
        let top = v00 + (v10 - v00) * fx
        let bottom = v01 + (v11 - v01) * fx
        return top + (bottom - top) * fy
    }

    private static func spatialReference(epsg: Int32) throws -> OGRSpatialReferenceH {
        guard let srs = OSRNewSpatialReference(nil) else {
            throw ElevationModelError.cannotOpen("EPSG:\(epsg)")
        }
        guard OSRImportFromEPSG(srs, epsg) == 0 else {
            OSRDestroySpatialReference(srs)
            throw ElevationModelError.cannotOpen("EPSG:\(epsg)")
        }
        OSRSetAxisMappingStrategy(srs, OAMS_TRADITIONAL_GIS_ORDER)
        return srs
    }
}

public extension Track {
    /// The track with heights from the model. With `replaceExisting` false, only points without a height are filled.
    func withElevations(from model: ElevationModel, replaceExisting: Bool) -> (Track, filled: Int, missing: Int) {
        withElevations(model.elevations(for: allCoordinates), replaceExisting: replaceExisting)
    }
}

public extension Route {
    func withElevations(from model: ElevationModel, replaceExisting: Bool) -> (Route, filled: Int, missing: Int) {
        withElevations(model.elevations(for: points.map(\.coordinate)), replaceExisting: replaceExisting)
    }
}

/// The result of filling in heights for one track or route.
public struct ElevationFill<Item>: Sendable where Item: Sendable {
    public var item: Item
    public var filled: Int
    public var missing: Int
}

public extension ElevationModel {
    func track(_ track: Track, replaceExisting: Bool) -> ElevationFill<Track> {
        let result = track.withElevations(from: self, replaceExisting: replaceExisting)
        return ElevationFill(item: result.0, filled: result.filled, missing: result.missing)
    }

    func route(_ route: Route, replaceExisting: Bool) -> ElevationFill<Route> {
        let result = route.withElevations(from: self, replaceExisting: replaceExisting)
        return ElevationFill(item: result.0, filled: result.filled, missing: result.missing)
    }
}
