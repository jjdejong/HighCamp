// Garmin style file (TYP): the colours and widths that a map is drawn with.
// Ported from QMapShack's map/garmin/CGarminTyp.cpp, and the polygon draw order from map/CMapIMG.cpp
// (Copyright 2008-2014 Oliver Eichler, GPL-3.0-or-later).
// The day styles of lines (colour, border, width, bitmap pattern), of polygons (colour or bitmap pattern) and the
// polygon draw order are read. Labels, points and night colours are skipped.

import BaseCampCore
import Foundation

public enum GarminTypError: Error {
    case notTyp
}

/// The style of one map: how each line and polygon type is drawn, and the order polygons are drawn in.
public struct GarminTypStyle: Sendable {
    public struct RGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
    }

    /// A one-bit picture, 32 pixels wide, repeated along a line or across an area. Set pixels take the foreground
    /// colour; the others take the background colour, or stay transparent when there is none.
    public struct Bitmap: Equatable, Sendable {
        public let width: Int
        public let rows: Int
        /// Row by row, from the top.
        public let bits: [Bool]

        public func isSet(x: Int, y: Int) -> Bool {
            bits[y * width + x]
        }
    }

    public struct Line: Equatable, Sendable {
        /// The line colour, or the foreground colour of the pattern.
        public let colour: RGB
        /// In pixels. For a patterned line, the pattern's height.
        public let width: Int
        /// The border drawn under the line, `borderWidth` wide in all, so it shows `(borderWidth - width) / 2` on
        /// each side. Nil when the line has none.
        public var border: RGB?
        public var borderWidth = 0
        /// A pattern repeated along the line instead of a plain colour.
        public var pattern: Bitmap?
        /// The colour of the pattern's unset pixels, or nil when they are transparent.
        public var background: RGB?

        public init(colour: RGB, width: Int, border: RGB? = nil, borderWidth: Int = 0, pattern: Bitmap? = nil, background: RGB? = nil) {
            self.colour = colour
            self.width = width
            self.border = border
            self.borderWidth = borderWidth
            self.pattern = pattern
            self.background = background
        }
    }

    public struct Fill: Equatable, Sendable {
        /// The fill colour, or the foreground colour of the pattern.
        public let colour: RGB
        /// A 32 by 32 pattern repeated across the area, or nil for a plain fill.
        public var pattern: Bitmap?
        /// The colour of the pattern's unset pixels, or nil when they are transparent.
        public var background: RGB?
    }

    /// Line style by feature type. Version 2 types are 0x10000 + (type << 8) + subtype.
    public private(set) var lines: [Int: Line] = [:]
    /// Polygon style by feature type.
    public private(set) var fillStyles: [Int: Fill] = [:]
    /// One colour per polygon type: the plain fill, or for a pattern its background, or its foreground when the
    /// background is transparent.
    public var fills: [Int: RGB] {
        fillStyles.mapValues { $0.pattern == nil ? $0.colour : $0.background ?? $0.colour }
    }
    /// The entries of the style's draw order section, in file order: a type, and for version 2 types a mask of
    /// subtypes (bit n set for subtype n). See `polygonDrawOrder`.
    public private(set) var orderEntries: [(type: Int, subtypes: UInt32)] = []

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
                fillStyles[entry.type] = fill
            }
        }
        orderEntries = Self.orderEntries(bytes, array: Array(bytes[0x51..<0x5b]))
    }

    /// The polygon types in the order they are drawn, bottom first, as QMapShack's `CMapIMG` draws them: types 0x00
    /// to 0x7F in turn, then the types of the style's draw order section on top, later entries above earlier ones.
    /// Version 2 types are drawn only when the section lists them.
    public static func polygonDrawOrder(_ style: GarminTypStyle?) -> [Int] {
        polygonDrawOrder(entries: style?.orderEntries ?? [])
    }

    /// The polygon draw order for these draw order entries. See `polygonDrawOrder(_:)`.
    public static func polygonDrawOrder(entries: [(type: Int, subtypes: UInt32)]) -> [Int] {
        // QMapShack's list runs from the top type to the bottom one; it is reversed at the end.
        var list = Array((0..<0x80).reversed())
        for entry in entries where entry.type != 0 {
            if entry.subtypes == 0 {
                if let index = list.firstIndex(of: entry.type) {
                    list.insert(list.remove(at: index), at: 0)
                }
            } else {
                for subtype in 0..<32 where entry.subtypes & (1 << subtype) != 0 {
                    list.insert(0x10000 | (entry.type << 8) | subtype, at: 0)
                }
            }
        }
        return list.reversed()
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

    /// The draw order section: five bytes per entry, a type and a mask of subtypes. Same checks as QMapShack's
    /// `CGarminTyp::parseDrawOrder`.
    private static func orderEntries(_ bytes: [UInt8], array: [UInt8]) -> [(type: Int, subtypes: UInt32)] {
        let offset = Int(u32(array, 0))
        let modulo = Int(u16(array, 4))
        let size = Int(u32(array, 6))
        guard size > 0, modulo == 5, size % modulo == 0 else { return [] }
        return (0..<(size / modulo)).map { element in
            let position = offset + modulo * element
            return (Int(u8(bytes, position)), u32(bytes, position + 1))
        }
    }

    /// The day style of a polyline record, following QMapShack's `CGarminTyp::parsePolyline`. The low three bits of
    /// the first byte give the colour layout; the high five bits give the rows of a bitmap pattern, or 0 for none.
    private static func line(_ bytes: [UInt8], at position: Int) -> Line? {
        guard position < bytes.count else { return nil }
        let header = u8(bytes, position)
        let kind = header & 0x07
        let rows = Int(header >> 3)
        let first = rgb(bytes, position + 2)
        let second = rgb(bytes, position + 5)
        // Colours each take three bytes after the two header bytes.
        func after(colours: Int) -> Int { position + 2 + 3 * colours }

        if rows > 0 {
            let background: RGB?
            let colours: Int
            switch kind {
            case 0x00: (background, colours) = (second, 2)
            case 0x01: (background, colours) = (second, 4)
            case 0x03: (background, colours) = (nil, 3)
            case 0x05: (background, colours) = (second, 3)
            case 0x06: (background, colours) = (nil, 1)
            case 0x07: (background, colours) = (nil, 2)
            default: return nil
            }
            let pattern = bitmap(bytes, at: after(colours: colours), rows: rows)
            return Line(colour: first, width: rows, pattern: pattern, background: background)
        }

        switch kind {
        case 0x00: // line and border colour, line and border width
            return plain(first, border: second, widths: after(colours: 2))
        case 0x01: // day line and border, night line and border
            return plain(first, border: second, widths: after(colours: 4))
        case 0x03: // day line; night line and border
            return Line(colour: first, width: Int(u8(bytes, after(colours: 3))))
        case 0x05: // day line and border, night line; one width, no border drawn
            return Line(colour: first, width: Int(u8(bytes, after(colours: 3))))
        case 0x06: // one line colour
            return Line(colour: first, width: Int(u8(bytes, after(colours: 1))))
        case 0x07: // day line and night line colours
            return Line(colour: first, width: Int(u8(bytes, after(colours: 2))))
        default:
            return nil
        }

        func plain(_ colour: RGB, border: RGB, widths: Int) -> Line {
            let width = Int(u8(bytes, widths))
            let borderWidth = Int(u8(bytes, widths + 1))
            // As in QMapShack, the border shows only when it is wider than the line.
            return borderWidth > width
                ? Line(colour: colour, width: width, border: border, borderWidth: borderWidth)
                : Line(colour: colour, width: width)
        }
    }

    /// The day style of a polygon record, following QMapShack's `CGarminTyp::parsePolygon`.
    private static func fill(_ bytes: [UInt8], at position: Int) -> Fill? {
        guard position < bytes.count else { return nil }
        let first = rgb(bytes, position + 1)
        let second = rgb(bytes, position + 4)
        func pattern(afterColours colours: Int) -> Bitmap {
            bitmap(bytes, at: position + 1 + 3 * colours, rows: 32)
        }
        switch u8(bytes, position) & 0x0f {
        case 0x01, 0x06, 0x07:
            return Fill(colour: first)
        case 0x08: // day foreground and background
            return Fill(colour: first, pattern: pattern(afterColours: 2), background: second)
        case 0x09: // day and night, each with a background
            return Fill(colour: first, pattern: pattern(afterColours: 4), background: second)
        case 0x0B: // day foreground on transparent; night foreground and background
            return Fill(colour: first, pattern: pattern(afterColours: 3))
        case 0x0D: // day foreground and background; night foreground on transparent
            return Fill(colour: first, pattern: pattern(afterColours: 3), background: second)
        case 0x0E: // foreground on transparent
            return Fill(colour: first, pattern: pattern(afterColours: 1))
        case 0x0F: // day and night foregrounds on transparent
            return Fill(colour: first, pattern: pattern(afterColours: 2))
        default:
            return nil
        }
    }

    /// A one-bit bitmap 32 pixels wide: four bytes per row, lowest bit first, as `CGarminTyp::decodeBitmap` reads it.
    private static func bitmap(_ bytes: [UInt8], at position: Int, rows: Int) -> Bitmap {
        var bits: [Bool] = []
        bits.reserveCapacity(32 * rows)
        for row in 0..<rows {
            for byte in 0..<4 {
                let value = u8(bytes, position + row * 4 + byte)
                for bit in 0..<8 {
                    bits.append(value & (1 << bit) != 0)
                }
            }
        }
        return Bitmap(width: 32, rows: rows, bits: bits)
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
