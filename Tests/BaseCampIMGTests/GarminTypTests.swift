import XCTest
@testable import BaseCampIMG

final class GarminTypTests: XCTestCase {
    /// A TYP file with one line type (1) and one polygon type (5), laid out as QMapShack reads them.
    private func makeTyp() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes.replaceSubrange(2..<12, with: Array("GARMIN TYP".utf8))
        func put32(_ value: Int, at position: Int) {
            for index in 0..<4 { bytes[position + index] = UInt8((value >> (8 * index)) & 0xff) }
        }
        func put16(_ value: Int, at position: Int) {
            bytes[position] = UInt8(value & 0xff)
            bytes[position + 1] = UInt8((value >> 8) & 0xff)
        }
        // Section data offsets: polylines at 0x100, polygons at 0x140.
        put32(0x100, at: 0x1f)
        put32(0x40, at: 0x23)
        put32(0x140, at: 0x27)
        put32(0x40, at: 0x2b)
        // Polyline array at 0x3d: offset, modulo 4, size 4 (one element).
        put32(0x80, at: 0x3d)
        put16(4, at: 0x41)
        put32(4, at: 0x43)
        // Polygon array at 0x47: offset, modulo 3, size 3 (one element).
        put32(0x90, at: 0x47)
        put16(3, at: 0x4b)
        put32(3, at: 0x4d)
        // Polyline element: type word (type 1 shifted left 5), record offset 0.
        put16(1 << 5, at: 0x80)
        put16(0, at: 0x82)
        // Polyline record at 0x100: kind 0x06 (one colour and width), colour blue, green, red, width 4.
        bytes[0x100] = 0x06
        bytes[0x102] = 0x10
        bytes[0x103] = 0x20
        bytes[0x104] = 0xff
        bytes[0x105] = 0x04
        // Polygon element: type word (type 5 shifted left 5), record offset 0x10.
        put16(5 << 5, at: 0x90)
        bytes[0x92] = 0x10
        // Polygon record at 0x150: kind 0x07, day fill blue 0, green 0x80, red 0x40.
        bytes[0x150] = 0x07
        bytes[0x151] = 0x00
        bytes[0x152] = 0x80
        bytes[0x153] = 0x40
        return bytes
    }

    func testSyntheticStyleReadsLineColourAndWidth() throws {
        let style = try GarminTypStyle(bytes: makeTyp())
        let line = try XCTUnwrap(style.lines[1])
        XCTAssertEqual(line.colour, GarminTypStyle.RGB(red: 255, green: 32, blue: 16))
        XCTAssertEqual(line.width, 4)
    }

    func testSyntheticStyleReadsFillColour() throws {
        let style = try GarminTypStyle(bytes: makeTyp())
        XCTAssertEqual(style.fills[5], GarminTypStyle.RGB(red: 64, green: 128, blue: 0))
        XCTAssertNil(style.lines[5])
    }

    func testNotATypFileIsRejected() {
        XCTAssertThrowsError(try GarminTypStyle(bytes: [UInt8](repeating: 0, count: 0x80)))
    }

    func testRealMapHasStyledRoads() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"], !path.isEmpty else {
            throw XCTSkip("set IMG_TEST_PATH to a Garmin .img file")
        }
        let img = try GarminIMG(url: URL(fileURLWithPath: path))
        let style = try XCTUnwrap(try img.typStyle())
        XCTAssertGreaterThan(style.lines.count, 10)
    }
}
