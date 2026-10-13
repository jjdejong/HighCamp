// Garmin style file (TYP): the colours and widths that a map is drawn with.
// Ported from QMapShack's map/garmin/CGarminTyp.cpp (Copyright 2008-2014 Oliver Eichler, GPL-3.0-or-later).
// Only the day colours of lines, their widths, and the fill colours of polygons are read. Bitmap patterns and
// labels are skipped, and types with other encodings get the default style.

import BaseCampCore
import Foundation

public enum GarminTypError: Error {
    case notTyp
}

/// The style of one map: line colours and widths by feature type, and fill colours of polygons.
public struct GarminTypStyle: Sendable {
    public struct RGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
    }

    public struct Line: Equatable, Sendable {
        public let colour: RGB
        public let width: Int
    }

    /// Line style by feature type. Version 2 types are 0x10000 + (type << 8) + subtype.
    public private(set) var lines: [Int: Line] = [:]
    /// Fill colour by feature type, for polygons.
    public private(set) var fills: [Int: RGB] = [:]

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 0x5b, Array(bytes[2..<12]) == Array("GARMIN TYP".utf8) else {
            throw GarminTypError.notTyp
        }
        let polylineData = Int(Self.u32(bytes, 0x1f))
        let polygonData = Int(Self.u32(bytes, 0x27))
        let polylineArray = Array(bytes[0x3d..<0x47])
        let polygonArray = Array(bytes[0x47..<0x51])

        for entry in Self.entries(bytes, array: polylineArray, dataOffset: polylineData) {
            if let line = Self.line(bytes, at: entry.data) {
                lines[entry.type] = line
            }
        }
        for entry in Self.entries(bytes, array: polygonArray, dataOffset: polygonData) {
            if let fill = Self.fill(bytes, at: entry.data) {
                fills[entry.type] = fill
            }
        }
    }

    // MARK: Reading

    /// The type and the position of the style record of each element of a section.
    private static func entries(_ bytes: [UInt8], array: [UInt8], dataOffset: Int) -> [(type: Int, data: Int)] {
        let offset = Int(u32(array, 0))
        let modulo = Int(u16(array, 4))
        let size = Int(u32(array, 6))
        guard (3...5).contains(modulo), size % modulo == 0 else { return [] }
        var result: [(type: Int, data: Int)] = []
        for element in 0..<(size / modulo) {
            let position = offset + modulo * element
            guard position + modulo <= bytes.count else { break }
            let typeWord = Int(u16(bytes, position))
            let recordOffset: Int
            switch modulo {
            case 5: recordOffset = Int(u16(bytes, position + 2)) | (Int(u8(bytes, position + 4)) << 16)
            case 4: recordOffset = Int(u16(bytes, position + 2))
            default: recordOffset = Int(u8(bytes, position + 2))
            }
            let packed = (typeWord >> 5) | ((typeWord & 0x1f) << 11)
            let base = packed & 0x7f
            let subtype = typeWord & 0x1f
            let type = typeWord & 0x2000 != 0 ? 0x10000 | (base << 8) | subtype : base
            result.append((type, dataOffset + recordOffset))
        }
        return result
    }

    /// The day line colour and width of a polyline record. Records with a bitmap pattern are skipped.
    private static func line(_ bytes: [UInt8], at position: Int) -> Line? {
        guard position < bytes.count else { return nil }
        let header = u8(bytes, position)
        let kind = header & 0x07
        let rows = header >> 3
        guard rows == 0 else { return nil }
        let colour = rgb(bytes, position + 2)
        switch kind {
        case 0x00: // line and border colour, line and border width
            return Line(colour: colour, width: Int(u8(bytes, position + 8)))
        case 0x01: // day and night line and border colours
            return Line(colour: colour, width: Int(u8(bytes, position + 14)))
        case 0x03: // day line, night line and night border colours
            return Line(colour: colour, width: Int(u8(bytes, position + 11)))
        case 0x05: // day line, day border, night line colours
            return Line(colour: colour, width: Int(u8(bytes, position + 11)))
        case 0x06: // one line colour
            return Line(colour: colour, width: Int(u8(bytes, position + 5)))
        case 0x07: // day line and night line colours
            return Line(colour: colour, width: Int(u8(bytes, position + 8)))
        default:
            return nil
        }
    }

    /// The day fill colour of a polygon record. Other encodings are skipped.
    private static func fill(_ bytes: [UInt8], at position: Int) -> RGB? {
        guard position < bytes.count else { return nil }
        switch u8(bytes, position) & 0x0f {
        case 0x01, 0x06, 0x07:
            return rgb(bytes, position + 1)
        default:
            return nil
        }
    }

    /// Colours are stored blue, green, red.
    private static func rgb(_ bytes: [UInt8], _ position: Int) -> RGB {
        RGB(red: u8(bytes, position + 2), green: u8(bytes, position + 1), blue: u8(bytes, position))
    }

    private static func u8(_ bytes: [UInt8], _ position: Int) -> UInt8 {
        position >= 0 && position < bytes.count ? bytes[position] : 0
    }

    private static func u16(_ bytes: [UInt8], _ position: Int) -> UInt16 {
        UInt16(u8(bytes, position)) | UInt16(u8(bytes, position + 1)) << 8
    }

    private static func u32(_ bytes: [UInt8], _ position: Int) -> UInt32 {
        UInt32(u16(bytes, position)) | UInt32(u16(bytes, position + 2)) << 16
    }
}

public extension GarminIMG {
    /// The raw bytes of one part of a subfile, such as its "TYP" style part.
    func partBytes(_ subfile: String, part: String) throws -> [UInt8]? {
        guard let entry = directory[subfile]?[part] else { return nil }
        return try reader.read(entry.offset, Int(entry.size))
    }

    /// The style of the first subfile of this map that carries a TYP part, if any.
    func typStyle() throws -> GarminTypStyle? {
        guard let subfile = subfiles.first(where: { $0.parts.contains("TYP") }),
              let bytes = try partBytes(subfile.name, part: "TYP") else { return nil }
        return try GarminTypStyle(bytes: bytes)
    }
}
