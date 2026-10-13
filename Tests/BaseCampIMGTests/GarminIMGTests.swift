import XCTest
@testable import BaseCampIMG

/// Builds a minimal IMG file: header, one directory entry for a TRE part and one for an RGN part,
/// and a TRE header with the given bounds in degrees. Optionally XORs the file with `mask`,
/// as Garmin does with some files.
private func makeIMG(
    mask: UInt8 = 0,
    north: Double = 50,
    east: Double = 10,
    south: Double = 40,
    west: Double = -5,
    treFlag: UInt8 = 0
) -> Data {
    var image = [UInt8](repeating: 0, count: 4096)

    func put(_ text: String, at offset: Int) {
        for (index, byte) in text.utf8.enumerated() {
            image[offset + index] = byte
        }
    }
    func putLittleEndian(_ value: Int, at offset: Int, count: Int) {
        for index in 0..<count {
            image[offset + index] = UInt8((value >> (8 * index)) & 0xFF)
        }
    }
    func putDegrees(_ degrees: Double, at offset: Int) {
        var value = Int((degrees * 16_777_216 / 360).rounded())
        if value < 0 {
            value += 0x1000000
        }
        putLittleEndian(value, at: offset, count: 3)
    }

    // Header: signature, identifier, block size 2^(9+0), description.
    put("DSKIMG", at: 0x10)
    put("GARMIN", at: 0x41)
    image[0x61] = 9
    image[0x62] = 0
    put("SYNTHETIC MAP", at: 0x49)

    // Directory: entry 1 is MYMAP.TRE at block 4, entry 2 is MYMAP.RGN at block 5, then end of list.
    let entries: [(type: String, block: Int, size: Int)] = [("TRE", 4, 0xB7), ("RGN", 5, 16)]
    for (index, entry) in entries.enumerated() {
        let base = 0x600 + index * 512
        image[base] = 0x01
        put("MYMAP   ", at: base + 1)
        put(entry.type, at: base + 9)
        putLittleEndian(entry.size, at: base + 12, count: 4)
        putLittleEndian(entry.block, at: base + 0x20, count: 2)
    }
    image[0x600 + entries.count * 512] = 0xFF

    // TRE header at block 4 (offset 2048): flag, then the four bounds.
    let tre = 4 * 512
    image[tre + 0x0D] = treFlag
    putDegrees(north, at: tre + 0x15)
    putDegrees(east, at: tre + 0x18)
    putDegrees(south, at: tre + 0x1B)
    putDegrees(west, at: tre + 0x1E)

    if mask != 0 {
        for index in image.indices {
            image[index] ^= mask
        }
    }
    return Data(image)
}

private func writeTemporary(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).img")
    try data.write(to: url)
    return url
}

final class GarminIMGTests: XCTestCase {
    private var created: [URL] = []

    override func tearDownWithError() throws {
        for url in created {
            try? FileManager.default.removeItem(at: url)
        }
        created = []
    }

    private func open(_ data: Data) throws -> GarminIMG {
        let url = try writeTemporary(data)
        created.append(url)
        return try GarminIMG(url: url)
    }

    func testReadsSubfilesAndCoverageFromTheTREHeader() throws {
        let map = try open(makeIMG())

        XCTAssertEqual(map.blockSize, 512)
        XCTAssertEqual(map.description, "SYNTHETIC MAP")
        XCTAssertEqual(map.subfiles.map(\.name), ["MYMAP"])
        XCTAssertEqual(map.subfiles.first?.parts, ["RGN", "TRE"])

        let coverage = try XCTUnwrap(map.coverage)
        XCTAssertEqual(coverage.north, 50, accuracy: 0.0001)
        XCTAssertEqual(coverage.east, 10, accuracy: 0.0001)
        XCTAssertEqual(coverage.south, 40, accuracy: 0.0001)
        XCTAssertEqual(coverage.west, -5, accuracy: 0.0001)
    }

    func testXORMaskedFileReadsTheSameCoverage() throws {
        let plain = try open(makeIMG())
        let masked = try open(makeIMG(mask: 0x5A))

        XCTAssertEqual(masked.coverage, plain.coverage)
        XCTAssertEqual(masked.subfiles, plain.subfiles)
    }

    func testSouthernAndWesternCoordinatesAreNegative() throws {
        let map = try open(makeIMG(north: -20, east: -30, south: -45, west: -70))

        let coverage = try XCTUnwrap(map.coverage)
        XCTAssertEqual(coverage.north, -20, accuracy: 0.0001)
        XCTAssertEqual(coverage.south, -45, accuracy: 0.0001)
        XCTAssertEqual(coverage.west, -70, accuracy: 0.0001)
    }

    func testRejectsAFileWithoutTheIMGHeader() throws {
        XCTAssertThrowsError(try open(Data(repeating: 0, count: 4096))) { error in
            XCTAssertEqual(error as? GarminIMGError, .notGarminIMG)
        }
    }

    func testRejectsLockedTREHeaders() throws {
        XCTAssertThrowsError(try open(makeIMG(treFlag: 0x80))) { error in
            XCTAssertEqual(error as? GarminIMGError, .locked)
        }
    }

    func testRejectsAFileTooShortToHoldTheHeader() throws {
        XCTAssertThrowsError(try open(Data(repeating: 0, count: 100))) { error in
            XCTAssertEqual(error as? GarminIMGError, .notGarminIMG)
        }
    }

    func testUnionCoversEverySubfile() {
        let first = GeoBounds(north: 50, east: 10, south: 40, west: -5)
        let second = GeoBounds(north: 55, east: 2, south: 42, west: -12)

        XCTAssertEqual(first.union(second), GeoBounds(north: 55, east: 10, south: 40, west: -12))
    }

    /// Reads a real map. Skipped unless IMG_TEST_PATH is set, for example:
    ///   IMG_TEST_PATH="$HOME/Documents/SynologyDrive/QMapShack/maps/OFM-EU2026_SW_GPS.img" swift test --filter GarminIMGTests
    func testReadsARealMapWhenAPathIsGiven() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"] else {
            throw XCTSkip("set IMG_TEST_PATH to read a real IMG map")
        }
        let map = try GarminIMG(url: URL(fileURLWithPath: path))
        print("IMG description: \(map.description)")
        print("IMG subfiles: \(map.subfiles.map { "\($0.name) \($0.parts)" })")
        if let coverage = map.coverage {
            print("IMG coverage: N \(coverage.north) E \(coverage.east) S \(coverage.south) W \(coverage.west)")
        }
        XCTAssertFalse(map.subfiles.isEmpty)
    }
}
