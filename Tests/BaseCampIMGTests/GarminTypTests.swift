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
        // Draw order array at 0x51: offset 0x1a0, modulo 5, size 10 (two entries).
        put32(0x1a0, at: 0x51)
        put16(5, at: 0x55)
        put32(10, at: 0x57)
        // Type 5 on its own, then version 2 type 3 with subtypes 0 and 2.
        bytes[0x1a0] = 0x05
        bytes[0x1a5] = 0x03
        put32(0b101, at: 0x1a6)
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

    func testSyntheticStyleReadsTheDrawOrder() throws {
        let style = try GarminTypStyle(bytes: makeTyp())
        XCTAssertEqual(style.orderEntries.map(\.type), [0x05, 0x03])
        XCTAssertEqual(style.orderEntries.map(\.subtypes), [0, 0b101])
    }

    func testWithoutAStyleTypesAreDrawnInTypeOrder() {
        XCTAssertEqual(GarminTypStyle.polygonDrawOrder(nil), Array(0..<0x80))
    }

    /// Listed types go on top, later entries above earlier ones, and version 2 types are added for their subtypes.
    func testTheDrawOrderPutsListedTypesOnTop() throws {
        let order = GarminTypStyle.polygonDrawOrder(try GarminTypStyle(bytes: makeTyp()))
        XCTAssertEqual(order.count, 0x80 + 2)
        XCTAssertEqual(Array(order.suffix(3)), [0x05, 0x10300, 0x10302])
        XCTAssertEqual(Array(order.prefix(6)), [0x00, 0x01, 0x02, 0x03, 0x04, 0x06])
    }

    func testTypeZeroEntriesAreIgnored() {
        let order = GarminTypStyle.polygonDrawOrder(entries: [(type: 0, subtypes: 0), (type: 0x4e, subtypes: 0)])
        XCTAssertEqual(order.last, 0x4e)
        XCTAssertEqual(order.count, 0x80)
    }

    /// A TYP with one polyline record and one polygon record, each written by `record`.
    private func makeTyp(line: [UInt8], polygon: [UInt8]) -> [UInt8] {
        var bytes = makeTyp()
        bytes.replaceSubrange(0x100..<(0x100 + line.count), with: line)
        bytes.replaceSubrange(0x150..<(0x150 + polygon.count), with: polygon)
        return bytes
    }

    func testALineWithAWiderBorderKeepsIt() throws {
        // Kind 0: line colour, border colour, line width 3, border width 5.
        let line: [UInt8] = [0x00, 0x00, 0x10, 0x20, 0x30, 0x01, 0x02, 0x03, 3, 5]
        let style = try GarminTypStyle(bytes: makeTyp(line: line, polygon: [0x06, 0, 0, 0]))
        let parsed = try XCTUnwrap(style.lines[1])
        XCTAssertEqual(parsed.colour, GarminTypStyle.RGB(red: 0x30, green: 0x20, blue: 0x10))
        XCTAssertEqual(parsed.width, 3)
        XCTAssertEqual(parsed.border, GarminTypStyle.RGB(red: 3, green: 2, blue: 1))
        XCTAssertEqual(parsed.borderWidth, 5)
    }

    func testABorderNoWiderThanTheLineIsDropped() throws {
        let line: [UInt8] = [0x00, 0x00, 0x10, 0x20, 0x30, 0x01, 0x02, 0x03, 4, 4]
        let style = try GarminTypStyle(bytes: makeTyp(line: line, polygon: [0x06, 0, 0, 0]))
        XCTAssertNil(try XCTUnwrap(style.lines[1]).border)
    }

    func testAPatternedLineReadsItsBitmap() throws {
        // Kind 0 with 2 rows: foreground, background, then 4 bytes per row, lowest bit first.
        let line: [UInt8] = [0x00 | (2 << 3), 0x00, 0, 0, 0, 0xff, 0xff, 0xff, 0x0f, 0, 0, 0, 0x0f, 0, 0, 0]
        let style = try GarminTypStyle(bytes: makeTyp(line: line, polygon: [0x06, 0, 0, 0]))
        let parsed = try XCTUnwrap(style.lines[1])
        XCTAssertEqual(parsed.width, 2)
        XCTAssertEqual(parsed.background, GarminTypStyle.RGB(red: 255, green: 255, blue: 255))
        let pattern = try XCTUnwrap(parsed.pattern)
        XCTAssertEqual((0..<32).map { pattern.isSet(x: $0, y: 1) }, (0..<32).map { $0 < 4 })
    }

    func testAPatternedFillOnATransparentBackground() throws {
        // Kind 0x0E: one colour, then a 32 by 32 bitmap with only the first pixel set.
        var polygon: [UInt8] = [0x0E, 0x00, 0x80, 0x00, 0x01]
        polygon += [UInt8](repeating: 0, count: 127)
        let style = try GarminTypStyle(bytes: makeTyp(line: [0x06, 0, 0, 0, 0, 1], polygon: polygon))
        let fill = try XCTUnwrap(style.fillStyles[5])
        XCTAssertEqual(fill.colour, GarminTypStyle.RGB(red: 0, green: 0x80, blue: 0))
        XCTAssertNil(fill.background)
        let pattern = try XCTUnwrap(fill.pattern)
        XCTAssertEqual(pattern.rows, 32)
        XCTAssertTrue(pattern.isSet(x: 0, y: 0))
        XCTAssertFalse(pattern.isSet(x: 1, y: 0))
        XCTAssertEqual(style.fills[5], fill.colour)
    }

    /// `makeTyp()` with a point section: a summit (0x6616) with a 2 by 2 one-bit icon and a small label in a set
    /// colour, and a version 2 type (0x10301) with a 1 by 1 icon in a colour with alpha and a name.
    private func makeTypWithPoints() -> [UInt8] {
        var bytes = makeTyp()
        func put32(_ value: Int, at position: Int) {
            for index in 0..<4 { bytes[position + index] = UInt8((value >> (8 * index)) & 0xff) }
        }
        func put(_ values: [UInt8], at position: Int) {
            bytes.replaceSubrange(position..<(position + values.count), with: values)
        }
        put32(0x1c0, at: 0x17) // point data
        put32(0x1b0, at: 0x33) // point array: offset, modulo 3, size 6
        put([3, 0], at: 0x37)
        put32(6, at: 0x39)
        put([0x16 | 0xC0, 0x0C, 0x00], at: 0x1b0) // type word (0x66 << 5) | 0x16, record 0
        put([0x21 | 0x60, 0x20, 0x10], at: 0x1b3) // type word 0x2000 | (0x03 << 5) | 0x01, record 0x10
        // Flags: text colour. 2 by 2, one colour (red), plain: 1 bit per pixel, index 1 transparent.
        put([0x08, 2, 2, 1, 0x00, 0x00, 0x00, 0xff, 0b10, 0b01, 0x0a, 0x11, 0x22, 0x33], at: 0x1c0)
        // Flags: names. 1 by 1, one colour with alpha (transparency 5), then "Summit" in language 0.
        put([0x04, 1, 1, 1, 0x20, 0x30, 0x20, 0x10, 0x05, 0x00], at: 0x1d0)
        put([17, 0x00] + Array("Summit".utf8) + [0], at: 0x1da)
        return bytes
    }

    func testPointIconsAndLabels() throws {
        let style = try GarminTypStyle(bytes: makeTypWithPoints())
        XCTAssertEqual(Set(style.points.keys), [0x6616, 0x10301])

        let summit = try XCTUnwrap(style.points[0x6616])
        XCTAssertEqual(summit.width, 2)
        XCTAssertEqual(summit.height, 2)
        let red: [UInt8] = [255, 0, 0, 255], clear: [UInt8] = [0, 0, 0, 0]
        XCTAssertEqual(summit.rgba, red + clear + clear + red, "low bits first; index 1 has no colour")
        XCTAssertEqual(summit.labelSize, .small)
        XCTAssertEqual(summit.labelColour, GarminTypStyle.RGB(red: 0x33, green: 0x22, blue: 0x11))

        let other = try XCTUnwrap(style.points[0x10301])
        XCTAssertEqual(other.rgba, [0x10, 0x20, 0x30, 170])
        XCTAssertEqual(other.name, "Summit")
        XCTAssertEqual(other.labelSize, .standard)
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
        // The style orders its polygons, so a filled type is drawn in the style's order.
        XCTAssertFalse(style.orderEntries.isEmpty)
        let order = GarminTypStyle.polygonDrawOrder(style)
        XCTAssertEqual(Set(order).count, order.count)
        // Roads have borders and tracks have patterns in this style.
        XCTAssertTrue(style.lines.values.contains { $0.border != nil })
        XCTAssertTrue(style.lines.values.contains { $0.pattern != nil })
    }

    func testRealMapHasPointIcons() throws {
        guard let path = ProcessInfo.processInfo.environment["IMG_TEST_PATH"], !path.isEmpty else {
            throw XCTSkip("set IMG_TEST_PATH to a Garmin .img file")
        }
        let style = try XCTUnwrap(try GarminIMG(url: URL(fileURLWithPath: path)).typStyle())
        XCTAssertGreaterThan(style.points.count, 20)
        for (type, point) in style.points {
            XCTAssertEqual(point.rgba.count, point.width * point.height * 4, String(format: "type %X", type))
            XCTAssertLessThanOrEqual(max(point.width, point.height), 64, String(format: "type %X", type))
        }
        if ProcessInfo.processInfo.environment["TYP_POINTS_DUMP"] != nil {
            for type in style.points.keys.sorted() {
                let point = style.points[type]!
                print(String(format: "TYPPOINT %06X %dx%d %@ %@", type, point.width, point.height, "\(point.labelSize)", point.name ?? "-"))
            }
        }
    }
}
