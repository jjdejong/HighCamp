import BaseCampCore
import XCTest
@testable import BaseCampIMG

final class GarminRGNTests: XCTestCase {
    func testDegreesUseTheTwosComplementRange() {
        XCTAssertEqual(GarminRGNDecoder.degrees(0), 0, accuracy: 1e-9)
        XCTAssertEqual(GarminRGNDecoder.degrees(0x400000), 90, accuracy: 1e-9)
        XCTAssertEqual(GarminRGNDecoder.degrees(0x800000), -180, accuracy: 1e-9)
        XCTAssertEqual(GarminRGNDecoder.degrees(0xC00000), -90, accuracy: 1e-9)
    }

    func testBitsPerCoordinateFollowsTheGarminRule() {
        XCTAssertEqual(GarminRGNDecoder.bitsPerCoordinate(0, signed: false), 2)
        XCTAssertEqual(GarminRGNDecoder.bitsPerCoordinate(9, signed: false), 11)
        XCTAssertEqual(GarminRGNDecoder.bitsPerCoordinate(10, signed: false), 13)
        XCTAssertEqual(GarminRGNDecoder.bitsPerCoordinate(4, signed: true), 7)
    }

    /// A detailed map tile's coarsest level is inherited: it holds no geometry and only leads to finer levels.
    func testTheCoarsestLevelOfARealMapTileIsInherited() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"], !path.isEmpty else {
            throw XCTSkip("set IMG_TEST_PATH to a Garmin .img file")
        }
        let map = try GarminIMG(url: URL(fileURLWithPath: path))
        let subfile = try XCTUnwrap(map.subfiles.first { $0.bounds != nil && $0.parts.contains("RGN") })
        let levels = try map.mapLevels(of: subfile.name)
        let coarsest = try XCTUnwrap(levels.min { $0.bits < $1.bits })
        XCTAssertTrue(coarsest.inherited)
        XCTAssertTrue(levels.contains { !$0.inherited })
    }

    /// Decodes the geometry of a real map. Skipped unless IMG_TEST_PATH is set, for example:
    ///   IMG_TEST_PATH="$HOME/Documents/SynologyDrive/QMapShack/maps/OFM-EU2026_SW_GPS.img" swift test --filter GarminRGNTests
    func testDecodesRealGeometryWhenAPathIsGiven() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"] else {
            throw XCTSkip("set IMG_TEST_PATH to decode a real IMG map")
        }
        let map = try GarminIMG(url: URL(fileURLWithPath: path))
        let subfile = try XCTUnwrap(map.subfiles.first { $0.bounds != nil && $0.parts.contains("RGN") })
        let levels = try map.mapLevels(of: subfile.name)
        print("RGN subfile \(subfile.name): levels \(levels.map { "\($0.level)/\($0.bits)" })")

        let subdivisions = try map.subdivisions(of: subfile.name)
        print("RGN subdivisions: \(subdivisions.count)")
        let finest = subdivisions.filter { $0.elements & 0xC0 != 0 }.max { $0.shift > $1.shift }
        XCTAssertNotNil(finest, "expected a subdivision with polylines or polygons")

        var total = 0
        var polygons = 0
        var inside = 0
        var points = 0
        var types: [Int: Int] = [:]
        for subdivision in subdivisions where subdivision.shift == finest?.shift {
            let geometries = try map.geometries(of: subfile.name, in: subdivision)
            for geometry in geometries where geometry.coordinates.count >= 2 {
                total += 1
                if geometry.isPolygon { polygons += 1 }
                let base = geometry.type >= 0x10000 ? (geometry.type >> 8) & 0xFF : geometry.type
                types[base, default: 0] += 1
                for coordinate in geometry.coordinates {
                    points += 1
                    let b = subdivision.bounds
                    if coordinate.latitude <= b.north + 0.001, coordinate.latitude >= b.south - 0.001,
                       coordinate.longitude <= b.east + 0.001, coordinate.longitude >= b.west - 0.001 {
                        inside += 1
                    }
                }
            }
        }
        let topTypes = types.sorted { $0.value > $1.value }.prefix(8).map { String(format: "0x%02X:%d", $0.key, $0.value) }
        print("RGN finest shift \(finest?.shift ?? -1): \(total) geometries (\(polygons) polygons), \(points) points")
        print("RGN types: \(topTypes.joined(separator: " "))")
        print("RGN points inside their subdivision: \(inside) of \(points)")
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(Double(inside) / Double(max(points, 1)), 0.9)
    }
}
