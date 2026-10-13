import BaseCampCore
import BaseCampDEM
import CGDAL
import XCTest

/// Writes a small GeoTIFF with GDAL, so the tests need no data files.
private func writeRaster(
    to url: URL,
    epsg: Int32,
    origin: (x: Double, y: Double),
    pixelSize: Double,
    width: Int,
    height: Int,
    value: (Int, Int) -> Float
) throws {
    GDALAllRegister()
    guard let driver = GDALGetDriverByName("GTiff"),
          let dataset = GDALCreate(driver, url.path, Int32(width), Int32(height), 1, GDT_Float32, nil) else {
        throw XCTSkip("GTiff driver unavailable")
    }
    defer { GDALClose(dataset) }
    var geotransform: [Double] = [origin.x, pixelSize, 0, origin.y, 0, -pixelSize]
    GDALSetGeoTransform(dataset, &geotransform)

    let srs = try XCTUnwrap(OSRNewSpatialReference(nil))
    defer { OSRDestroySpatialReference(srs) }
    OSRImportFromEPSG(srs, epsg)
    var wkt: UnsafeMutablePointer<CChar>?
    OSRExportToWkt(srs, &wkt)
    GDALSetProjection(dataset, wkt)
    VSIFree(wkt)

    var pixels = [Float](repeating: 0, count: width * height)
    for row in 0..<height {
        for column in 0..<width {
            pixels[row * width + column] = value(column, row)
        }
    }
    let band = GDALGetRasterBand(dataset, 1)
    GDALRasterIO(band, GF_Write, 0, 0, Int32(width), Int32(height), &pixels, Int32(width), Int32(height), GDT_Float32, 0, 0)
}

final class ElevationModelTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testHeightsInterpolateAcrossAWGS84Raster() throws {
        // 10 x 10 pixels of 0.01 degree, from 5.00 E, 45.10 N. The height rises 1 m per column.
        try writeRaster(to: folder.appendingPathComponent("flat.tif"), epsg: 4326,
                        origin: (5.0, 45.1), pixelSize: 0.01, width: 10, height: 10) { column, _ in
            Float(100 + column)
        }
        let model = try ElevationModel(folder: folder)
        XCTAssertEqual(model.rasterCount, 1)

        // The centre of column 4 is 5.045 E. A point half a pixel east of it lies between columns 4 and 5.
        let centre = try XCTUnwrap(model.elevation(at: Coordinate(latitude: 45.05, longitude: 5.045)))
        XCTAssertEqual(centre, 104, accuracy: 0.05)
        let between = try XCTUnwrap(model.elevation(at: Coordinate(latitude: 45.05, longitude: 5.05)))
        XCTAssertEqual(between, 104.5, accuracy: 0.05)
    }

    func testPointsOutsideTheRasterHaveNoHeight() throws {
        try writeRaster(to: folder.appendingPathComponent("flat.tif"), epsg: 4326,
                        origin: (5.0, 45.1), pixelSize: 0.01, width: 10, height: 10) { _, _ in 250 }
        let model = try ElevationModel(folder: folder)
        XCTAssertNil(model.elevation(at: Coordinate(latitude: 46, longitude: 6)))
    }

    func testProjectedRasterIsReachedFromWGS84() throws {
        // A Lambert-93 raster (EPSG:2154, the French national grid) around a point near Grenoble,
        // with a constant height. The point is transformed to the grid before sampling.
        let grenoble = Coordinate(latitude: 45.19, longitude: 5.72)
        let (x, y) = try lambert93(of: grenoble)
        try writeRaster(to: folder.appendingPathComponent("lambert.tif"), epsg: 2154,
                        origin: (x - 500, y + 500), pixelSize: 5, width: 200, height: 200) { _, _ in 212 }
        let model = try ElevationModel(folder: folder)
        let height = try XCTUnwrap(model.elevation(at: grenoble))
        XCTAssertEqual(height, 212, accuracy: 0.01)
    }

    func testTheFirstRasterWithAValueWins() throws {
        // Current_DEM sorts first. A second raster covers the same area with other values.
        try writeRaster(to: folder.appendingPathComponent("Current_DEM.tif"), epsg: 4326,
                        origin: (5.0, 45.1), pixelSize: 0.01, width: 10, height: 10) { _, _ in 300 }
        try writeRaster(to: folder.appendingPathComponent("Other.tif"), epsg: 4326,
                        origin: (5.0, 45.1), pixelSize: 0.01, width: 10, height: 10) { _, _ in 999 }
        let model = try ElevationModel(folder: folder)
        XCTAssertEqual(try XCTUnwrap(model.elevation(at: Coordinate(latitude: 45.05, longitude: 5.05))), 300, accuracy: 0.01)
    }

    func testTrackFillLeavesExistingHeightsUnlessAsked() throws {
        try writeRaster(to: folder.appendingPathComponent("flat.tif"), epsg: 4326,
                        origin: (5.0, 45.1), pixelSize: 0.01, width: 10, height: 10) { _, _ in 400 }
        let model = try ElevationModel(folder: folder)
        let track = Track(name: "Ride", segments: [[
            TrackPoint(coordinate: Coordinate(latitude: 45.05, longitude: 5.05), elevation: 10),
            TrackPoint(coordinate: Coordinate(latitude: 45.06, longitude: 5.06)),
            TrackPoint(coordinate: Coordinate(latitude: 50, longitude: 5)),
        ]])
        let kept = track.withElevations(from: model, replaceExisting: false)
        XCTAssertEqual(kept.0.segments[0][0].elevation, 10)
        XCTAssertEqual(kept.0.segments[0][1].elevation ?? -1, 400, accuracy: 0.01)
        XCTAssertNil(kept.0.segments[0][2].elevation)
        XCTAssertEqual(kept.filled, 1)
        XCTAssertEqual(kept.missing, 1)

        let replaced = track.withElevations(from: model, replaceExisting: true)
        XCTAssertEqual(replaced.0.segments[0][0].elevation ?? -1, 400, accuracy: 0.01)
    }

    func testFolderWithoutRastersIsAnError() {
        XCTAssertThrowsError(try ElevationModel(folder: folder))
    }

    /// Lambert-93 coordinates of a WGS 84 point, with GDAL's own transform.
    private func lambert93(of coordinate: Coordinate) throws -> (Double, Double) {
        GDALAllRegister()
        let wgs84 = try XCTUnwrap(OSRNewSpatialReference(nil))
        let target = try XCTUnwrap(OSRNewSpatialReference(nil))
        defer {
            OSRDestroySpatialReference(wgs84)
            OSRDestroySpatialReference(target)
        }
        OSRImportFromEPSG(wgs84, 4326)
        OSRImportFromEPSG(target, 2154)
        OSRSetAxisMappingStrategy(wgs84, OAMS_TRADITIONAL_GIS_ORDER)
        OSRSetAxisMappingStrategy(target, OAMS_TRADITIONAL_GIS_ORDER)
        guard let transform = OCTNewCoordinateTransformation(wgs84, target) else {
            throw XCTSkip("no transform")
        }
        defer { OCTDestroyCoordinateTransformation(transform) }
        var x = coordinate.longitude
        var y = coordinate.latitude
        var z = 0.0
        XCTAssertNotEqual(OCTTransform(transform, 1, &x, &y, &z), 0)
        return (x, y)
    }
}
