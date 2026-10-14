import XCTest
@testable import BaseCampIMG

final class GarminDEMTests: XCTestCase {
    /// A DEM part with one level of one tile, 4 by 3 pixels, 0.001° apart, its north-west corner at 45° N 5° E,
    /// coded as a constant tile (no height difference), so no JPEG-LS data is needed.
    private func constantPart(base: Int, flags: Int, inFeet: Bool = false) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x15)
        func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
        func u16(_ v: Int) { u8(v); u8(v >> 8) }
        func u32(_ v: Int) { u16(v); u16(v >> 16) }
        func units(_ degrees: Double) -> Int { Int((degrees / 180 * Double(1 << 31)).rounded()) }
        u32(inFeet ? 1 : 0)          // flags
        u16(1)                       // levels
        u32(0)
        u16(60)                      // record size
        u32(0x30)                    // records
        while bytes.count < 0x30 { u8(0) }
        let table = 0x30 + 60
        u8(0); u8(0)                 // layer, level
        u32(3); u32(4)               // tile height, tile width
        u32(2); u32(3)               // last tile height - 1, last tile width - 1
        u16(0)                       // factor
        u32(0); u32(0)               // columns - 1, rows - 1
        u16(0x10)                    // encoding: 1-byte offset, 1-byte base, 1-byte difference, flags byte
        u16(0)
        u32(table); u32(table + 4)   // tile table, data
        u32(units(5)); u32(units(45))
        u32(units(0.001)); u32(units(0.001))
        u16(0); u16(9000)
        while bytes.count < table { u8(0) }
        u8(0); u8(base); u8(0); u8(flags)
        return bytes
    }

    func testConstantTileGivesItsBaseEverywhere() throws {
        let dem = try GarminDEM(bytes: constantPart(base: 100, flags: 0))
        XCTAssertEqual(dem.levels.count, 1)
        let level = dem.levels[0]
        XCTAssertEqual(level.width, 4)
        XCTAssertEqual(level.height, 3)
        XCTAssertEqual(level.north, 45, accuracy: 1e-6)
        XCTAssertEqual(level.west, 5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(dem.elevation(latitude: 44.9985, longitude: 5.0015, level: 0)), 100, accuracy: 1e-9)
        XCTAssertNil(dem.elevation(latitude: 45.01, longitude: 5.001, level: 0))
        XCTAssertNil(dem.elevation(latitude: 44.999, longitude: 5.004, level: 0))
    }

    func testFlaggedConstantTileHasNoHeights() throws {
        let dem = try GarminDEM(bytes: constantPart(base: 100, flags: 1))
        XCTAssertNil(dem.elevation(latitude: 44.999, longitude: 5.001, level: 0))
    }

    func testFeetAreConvertedToMetres() throws {
        let dem = try GarminDEM(bytes: constantPart(base: 100, flags: 0, inFeet: true))
        XCTAssertEqual(try XCTUnwrap(dem.elevation(latitude: 44.999, longitude: 5.001, level: 0)), 30, accuracy: 1e-9)
    }

    func testLevelChoiceTakesTheCoarsestFineEnough() throws {
        let dem = try GarminDEM(bytes: constantPart(base: 1, flags: 0))
        XCTAssertEqual(dem.level(forDegreesPerPixel: 0.01), 0)
        XCTAssertEqual(dem.level(forDegreesPerPixel: 0.0001), 0)
    }

    /// Heights from the OFM map's DEM, against the user's DEM folder (EU-DEM, read with gdallocationinfo) at the
    /// same places: within a few metres where the ground is not steep.
    func testHeightsFromARealMapMatchTheDEMFolder() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"], !path.isEmpty,
              path.hasSuffix("OFM-EU2026_SW_GPS.img") else {
            throw XCTSkip("Set IMG_TEST_PATH to OFM-EU2026_SW_GPS.img")
        }
        let image = try GarminIMG(url: URL(fileURLWithPath: path))
        let places: [(latitude: Double, longitude: Double, height: Double)] = [
            (45.188, 5.724, 211.9),   // Grenoble
            (45.3, 5.65, 555.5),      // Voreppe
            (45.11, 5.88, 1794.2),    // Chamrousse
            (45.0, 6.0, 2407.0),      // Belledonne
        ]
        for place in places {
            let subfile = try XCTUnwrap(image.subfiles.first { subfile in
                guard let b = subfile.bounds else { return false }
                return place.latitude <= b.north && place.latitude >= b.south && place.longitude >= b.west && place.longitude <= b.east
            })
            let dem = try XCTUnwrap(try image.dem(of: subfile.name))
            XCTAssertEqual(dem.levels.count, 4)
            let height = try XCTUnwrap(dem.elevation(latitude: place.latitude, longitude: place.longitude, level: 0))
            XCTAssertEqual(height, place.height, accuracy: 12, "at \(place.latitude), \(place.longitude)")
            // Coarser levels stay close.
            let coarse = try XCTUnwrap(dem.elevation(latitude: place.latitude, longitude: place.longitude, level: 3))
            XCTAssertEqual(coarse, height, accuracy: 30)
        }
    }
}

extension GarminDEMTests {
    func testGridFillMatchesSingleLookups() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"], !path.isEmpty,
              path.hasSuffix("OFM-EU2026_SW_GPS.img") else {
            throw XCTSkip("Set IMG_TEST_PATH to OFM-EU2026_SW_GPS.img")
        }
        let image = try GarminIMG(url: URL(fileURLWithPath: path))
        let subfile = try XCTUnwrap(image.subfiles.first { subfile in
            guard let b = subfile.bounds else { return false }
            return 45.11 <= b.north && 45.11 >= b.south && 5.88 >= b.west && 5.88 <= b.east
        })
        let dem = try XCTUnwrap(try image.dem(of: subfile.name))
        let latitudes = (0..<134).map { 45.15 - Double($0) * 0.0006 }
        let longitudes = (0..<134).map { 5.82 + Double($0) * 0.0008 }
        var grid = [Double](repeating: .nan, count: 134 * 134)
        let start = Date()
        dem.fill(&grid, latitudes: latitudes, longitudes: longitudes, level: 0)
        let elapsed = Date().timeIntervalSince(start)
        print("fill 134x134:", elapsed)
        for (row, column) in [(0, 0), (40, 77), (133, 133), (90, 12)] {
            let single = dem.elevation(latitude: latitudes[row], longitude: longitudes[column], level: 0)
            XCTAssertEqual(grid[row * 134 + column], try XCTUnwrap(single), accuracy: 1e-9)
        }
    }
}
