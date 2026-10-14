import XCTest
import BaseCampCore
@testable import BaseCampIMG

final class GarminLabelsTests: XCTestCase {
    /// An LBL part of `coding` holding `strings` back to back, each ended by a zero byte.
    private func part(coding: UInt8, codepage: Int, strings: [[UInt8]]) -> (bytes: [UInt8], offsets: [Int]) {
        var bytes = [UInt8](repeating: 0, count: 0xAC)
        bytes[0] = 0xAC                 // header length, so the codepage is read
        bytes[0x1E] = coding
        bytes[0xAA] = UInt8(codepage & 0xFF)
        bytes[0xAB] = UInt8(codepage >> 8)
        let start = bytes.count
        var offsets: [Int] = []
        for string in strings {
            offsets.append(bytes.count - start)
            bytes += string + [0]
        }
        let length = bytes.count - start
        for index in 0..<4 {
            bytes[0x15 + index] = UInt8((start >> (8 * index)) & 0xFF)
            bytes[0x19 + index] = UInt8((length >> (8 * index)) & 0xFF)
        }
        return (bytes, offsets)
    }

    func testEightBitNamesUseTheCodepage() throws {
        // "SAINT-ÉGRÈVE" in Windows-1252, then a name in two parts with a shield code before it.
        let (bytes, offsets) = part(coding: 0x09, codepage: 1252, strings: [
            Array("SAINT-".utf8) + [0xC9] + Array("GR".utf8) + [0xC8] + Array("VE".utf8),
            [0x02] + Array("D 512".utf8) + [0x1D] + Array("Route".utf8),
        ])
        let labels = try XCTUnwrap(GarminLabels(bytes: bytes))
        XCTAssertEqual(labels.name(at: offsets[0]), "SAINT-ÉGRÈVE")
        XCTAssertEqual(labels.name(at: offsets[1]), "D 512 Route")
        XCTAssertNil(labels.name(at: 10_000))
    }

    func testSixBitNames() throws {
        // "AB 1" in 6-bit codes: A=1, B=2, space=0, 1=0x21, then the terminator 0x3F.
        let codes = [1, 2, 0, 0x21, 0x3F, 0x3F]
        var bits: [UInt8] = []
        var register = 0, count = 0
        for code in codes {
            register = register << 6 | code
            count += 6
            while count >= 8 {
                bits.append(UInt8((register >> (count - 8)) & 0xFF))
                count -= 8
            }
        }
        if count > 0 { bits.append(UInt8((register << (8 - count)) & 0xFF)) }
        // A 6-bit string may contain zero bytes, so it is placed directly rather than with a terminator.
        var (bytes, _) = part(coding: 0x06, codepage: 0, strings: [])
        let start = bytes.count
        bytes += bits + [0xFF, 0xFF]
        for index in 0..<4 {
            bytes[0x15 + index] = UInt8((start >> (8 * index)) & 0xFF)
            bytes[0x19 + index] = UInt8(((bits.count + 2) >> (8 * index)) & 0xFF)
        }
        let labels = try XCTUnwrap(GarminLabels(bytes: bytes))
        XCTAssertEqual(labels.name(at: 0), "AB 1")
    }

    func testUnknownCodingIsRefused() {
        let (bytes, _) = part(coding: 0x07, codepage: 0, strings: [Array("X".utf8)])
        XCTAssertNil(GarminLabels(bytes: bytes))
    }

    /// The OFM map near Grenoble: Grenoble is a place on the coarsest level, with its name; the RGN v2 lines are
    /// found (their section offsets were once misread, which hid every extended line).
    func testPlacesAndExtendedLinesOfARealMap() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"], !path.isEmpty,
              path.hasSuffix("OFM-EU2026_SW_GPS.img") else {
            throw XCTSkip("Set IMG_TEST_PATH to OFM-EU2026_SW_GPS.img")
        }
        let image = try GarminIMG(url: URL(fileURLWithPath: path))
        let subfile = try XCTUnwrap(image.subfiles.first { subfile in
            guard let b = subfile.bounds else { return false }
            return 45.19 <= b.north && 45.19 >= b.south && 5.72 >= b.west && 5.72 <= b.east
        })
        let labels = try XCTUnwrap(try image.labels(of: subfile.name))
        let levels = try image.mapLevels(of: subfile.name)
        let coarsest = try XCTUnwrap(levels.filter { !$0.inherited }.max { $0.level < $1.level })
        let cells = try image.subdivisions(of: subfile.name)
        var names: [String: Coordinate] = [:]
        for cell in cells where cell.level == coarsest.level {
            for point in try image.points(of: subfile.name, in: cell) where point.isPlace {
                if let name = labels.name(at: point.labelOffset, poi: point.labelIsPOI) {
                    names[name] = point.coordinate
                }
            }
        }
        let grenoble = try XCTUnwrap(names["GRENOBLE"])
        XCTAssertEqual(grenoble.latitude, 45.188, accuracy: 0.01)
        XCTAssertEqual(grenoble.longitude, 5.736, accuracy: 0.01)
        XCTAssertNotNil(names["SAINT-ÉGRÈVE"])

        let finest = try XCTUnwrap(levels.map(\.level).min())
        // Streets are named through the NET part.
        var streets = Set<String>()
        for cell in cells where cell.level == finest && cell.bounds.north > 45.185 && cell.bounds.south < 45.195 && cell.bounds.west < 5.74 && cell.bounds.east > 5.72 {
            for line in try image.geometries(of: subfile.name, in: cell) where !line.isPolygon && line.labelInNET {
                if let name = labels.name(at: line.labelOffset, inNET: true) {
                    streets.insert(name)
                }
            }
        }
        XCTAssertTrue(streets.contains("COURS JEAN JAURÈS"))
        let extended = try cells.filter { $0.level == finest }.prefix(40).flatMap { try image.geometries(of: subfile.name, in: $0) }.filter { $0.type >= 0x10000 }
        XCTAssertFalse(extended.isEmpty)
    }
}
