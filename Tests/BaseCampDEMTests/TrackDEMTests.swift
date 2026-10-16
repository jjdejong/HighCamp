import BaseCampCore
@testable import BaseCampDEM
import XCTest

final class TrackDEMTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TrackDEMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("tiles/fine"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// An IGN-style ESRI ASCII grid with no projection file, named as RGE ALTI names its tiles.
    private func writeASC(_ name: String, in subfolder: String, x: Double, y: Double, cell: Double, size: Int, value: Double) throws {
        var text = "ncols \(size)\nnrows \(size)\nxllcorner \(x)\nyllcorner \(y)\ncellsize \(cell)\nNODATA_value -99999\n"
        for _ in 0..<size {
            text += Array(repeating: String(value), count: size).joined(separator: " ") + "\n"
        }
        try text.write(to: folder.appendingPathComponent(subfolder).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testTilesAlongALineMakeATrackDEMWithTheFinestFirst() throws {
        // A 5 m tile of 1 km at 1000 m high, and a 1 m tile of 100 m inside it at 1001 m, in Lambert-93 near Grenoble.
        try writeASC("RGEALTI_FXX_0913_6460_MNT_LAMB93_IGN69.asc", in: "tiles", x: 913_000, y: 6_459_000, cell: 5, size: 200, value: 1000)
        try writeASC("RGEALTI_FXX_0913_6459_MNT_LAMB93_IGN69.asc", in: "tiles/fine", x: 913_400, y: 6_459_400, cell: 1, size: 100, value: 1001)
        try writeASC("RGEALTI_FXX_0990_6400_MNT_LAMB93_IGN69.asc", in: "tiles", x: 990_000, y: 6_399_000, cell: 5, size: 20, value: 7)

        let tiles = DEMTileIndex.scan(folder: folder.appendingPathComponent("tiles"), previous: [])
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(Set(tiles.map(\.resolution)), [1, 5])
        XCTAssertTrue(tiles.allSatisfy { $0.projection == DEMTileIndex.lambert93 })

        // A line across the middle of the 5 m tile, through the 1 m one.
        let big = try XCTUnwrap(tiles.first { $0.resolution == 5 && $0.path.contains("0913_6460") })
        let middle = (big.north + big.south) / 2
        let line = [Coordinate(latitude: middle, longitude: big.west + 0.001), Coordinate(latitude: middle, longitude: big.east - 0.001)]
        let chosen = TrackDEM.tiles(along: [line], corridor: 50, from: tiles)
        XCTAssertEqual(chosen.map(\.resolution), [1, 5])

        let output = folder.appendingPathComponent("track")
        let files = try TrackDEMBuilder.build(tiles: chosen, into: output)
        XCTAssertEqual(files.map(\.lastPathComponent), ["1 - 1 m.vrt", "2 - 5 m.vrt"])

        let model = try ElevationModel(folder: output)
        let fine = try XCTUnwrap(tiles.first { $0.resolution == 1 })
        let inFine = Coordinate(latitude: (fine.north + fine.south) / 2, longitude: (fine.east + fine.west) / 2)
        XCTAssertEqual(try XCTUnwrap(model.elevation(at: inFine)), 1001, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(model.elevation(at: Coordinate(latitude: middle, longitude: big.west + 0.002))), 1000, accuracy: 0.01)
    }

    func testAnUnchangedFolderIsNotReadAgain() throws {
        try writeASC("RGEALTI_FXX_0913_6460_MNT_LAMB93_IGN69.asc", in: "tiles", x: 913_000, y: 6_459_000, cell: 5, size: 10, value: 1)
        let first = DEMTileIndex.scan(folder: folder.appendingPathComponent("tiles"), previous: [])
        // An entry from the index is kept as it is, even if it says something else, when the file has not changed.
        let edited = first.map {
            DEMTileInfo(path: $0.path, size: $0.size, modified: $0.modified, north: 1, south: 0, east: 1, west: 0, resolution: 99,
                        projection: "x", corners: $0.corners)
        }
        XCTAssertEqual(DEMTileIndex.scan(folder: folder.appendingPathComponent("tiles"), previous: edited).first?.resolution, 99)
        // An entry from before the corners were kept is read again.
        let old = first.map {
            DEMTileInfo(path: $0.path, size: $0.size, modified: $0.modified, north: 1, south: 0, east: 1, west: 0, resolution: 99, projection: "x")
        }
        XCTAssertEqual(DEMTileIndex.scan(folder: folder.appendingPathComponent("tiles"), previous: old).first?.resolution, 5)
    }

    func testALambertTileKeepsItsTurnedCorners() throws {
        try writeASC("RGEALTI_FXX_0913_6460_MNT_LAMB93_IGN69.asc", in: "tiles", x: 913_000, y: 6_455_000, cell: 5, size: 1000, value: 1)
        let tile = try XCTUnwrap(DEMTileIndex.scan(folder: folder.appendingPathComponent("tiles"), previous: []).first)
        let corners = try XCTUnwrap(tile.corners)
        XCTAssertEqual(corners.count, 4)
        // East of Lambert-93's central meridian (3° E) grid north points east of true north: the north-west corner
        // lies east of the south-west one and north of the north-east one, and the box is larger than the tile.
        XCTAssertGreaterThan(corners[0].longitude, corners[3].longitude)
        XCTAssertGreaterThan(corners[0].latitude, corners[1].latitude)
        XCTAssertEqual(corners.map(\.latitude).max(), tile.north)
        XCTAssertEqual(corners.map(\.longitude).min(), tile.west)
    }

    func testNoTilesIsAnError() {
        XCTAssertThrowsError(try TrackDEMBuilder.build(tiles: [], into: folder.appendingPathComponent("none")))
    }
}
